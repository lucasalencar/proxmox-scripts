#!/usr/bin/env python3
"""Wire Starr integrations inside the starr LXC (stdlib + python3-ruamel.yaml via apt).

Reads Servarr API keys from config.xml, then idempotently creates:
  - Prowlarr applications -> Sonarr / Radarr (indexer sync)
  - Sonarr / Radarr download clients -> qBittorrent (+ root folders)
  - Bazarr links -> Sonarr / Radarr

All traffic goes over http://localhost (same container). Secrets are
never printed; stdout carries only a JSON summary of actions taken.
"""

import argparse
import ipaddress
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from typing import Any, Callable, Dict, List, NoReturn, Optional, Tuple

try:
    from ruamel.yaml import YAML as _YAMLClass
    from ruamel.yaml.error import YAMLError as _YAMLParseError
    HAVE_RUAMEL = True
except ImportError:
    _YAMLClass = None
    _YAMLParseError = None
    HAVE_RUAMEL = False

# Tuple for retry loops: empty when ruamel is absent (matching nothing),
# but _ruamel_yaml() fails first in that case, so the clause is unreachable.
_RETRYABLE_YAML_ERRORS = (_YAMLParseError,) if _YAMLParseError is not None else ()


def _ruamel_yaml():
    if not HAVE_RUAMEL or _YAMLClass is None:
        fail("python3-ruamel.yaml is not installed — run starr/update.sh"
             " or: apt install python3-ruamel.yaml")
    yaml = _YAMLClass(typ="rt")
    yaml.preserve_quotes = True
    return yaml

PROWLARR_BASE = "http://localhost:9696"
SONARR_BASE = "http://localhost:8989"
RADARR_BASE = "http://localhost:7878"
BAZARR_BASE = "http://localhost:6767"
LOCALHOST_IP = "127.0.0.1"
SONARR_PORT = urllib.parse.urlparse(SONARR_BASE).port or 8989
RADARR_PORT = urllib.parse.urlparse(RADARR_BASE).port or 7878

DATA_ROOT = "/var/lib"
BAZARR_CONFIG = "/var/lib/bazarr/config/config.yaml"

SONARR_ROOT = "/data/media/Series"
RADARR_ROOT = "/data/media/Movies"
SONARR_CATEGORY = "series"
RADARR_CATEGORY = "movies"

SONARR_SYNC_CATEGORIES = [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5090]
SONARR_ANIME_CATEGORIES = [5070]
RADARR_SYNC_CATEGORIES = [2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080, 2090]

def log(msg: str) -> None:
    print("[starr-configure] %s" % msg, file=sys.stderr, flush=True)


def fail(msg: str) -> NoReturn:
    log("ERROR: %s" % msg)
    sys.exit(1)


class ApiError(Exception):
    def __init__(self, status: Optional[int], body: str):
        scrubbed = scrub_secrets(body[:300])
        super(ApiError, self).__init__("HTTP %s: %s" % (status, scrubbed))
        self.status = status
        self.body = scrubbed


def scrub_secrets(text: str) -> str:
    redacted = re.sub(r'("(?:apiKey|apikey|password)"\s*:\s*")[^"]*', r'\1***', text)
    return re.sub(r'((?:apiKey|apikey|password)=)[^&\s;"\']*', r'\1***', redacted)


def api_request(method: str, base: str, header_name: str, header_value: str,
                path: str, body: Optional[Dict[str, Any]] = None,
                form: bool = False) -> Any:
    url = base + path
    data = None
    if body is not None:
        data = (urllib.parse.urlencode(body).encode() if form
                else json.dumps(body).encode())
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header(header_name, header_value)
    if data is not None:
        req.add_header("Content-Type", "application/x-www-form-urlencoded" if form
                       else "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            payload = resp.read().decode()
            return json.loads(payload) if payload.strip() else None
    except urllib.error.HTTPError as exc:
        raise ApiError(exc.code, exc.read().decode(errors="replace"))
    except (urllib.error.URLError, OSError, TimeoutError, ValueError) as exc:
        raise ApiError(None, str(exc))


def servarr_request(method: str, base: str, api_key: str, path: str,
                    body: Optional[Dict[str, Any]] = None) -> Any:
    return api_request(method, base, "X-Api-Key", api_key, path, body)


def bazarr_request(api_key: str, method: str, path: str,
                   body: Optional[Dict[str, Any]] = None,
                   form: bool = False) -> Any:
    return api_request(method, BAZARR_BASE, "X-API-KEY", api_key, path, body, form)


def read_api_key(data_root: str, app: str, timeout: int = 60) -> str:
    path = "%s/%s/config.xml" % (data_root, app)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            root = ET.parse(path).getroot()
            key = (root.findtext("ApiKey") or "").strip()
            if key:
                return key
        except (OSError, ET.ParseError):
            pass
        time.sleep(2)
    fail("timed out waiting for API key in %s (is %s running?)" % (path, app))


def wait_healthy(name: str, base: str, api_key: str, status_path: str,
                 timeout: int = 90) -> Dict[str, Any]:
    deadline = time.time() + timeout
    last: Optional[Exception] = None
    while time.time() < deadline:
        try:
            status = servarr_request("GET", base, api_key, status_path)
            log("%s healthy (v%s)" % (name, status.get("version", "?")))
            return status
        except ApiError as exc:
            if exc.status in (401, 403, 404):
                fail("%s health check failed with HTTP %s; check its API key and endpoint"
                     % (name, exc.status))
            last = exc
            time.sleep(3)
        except Exception as exc:  # noqa: BLE001 - retry until timeout
            last = exc
            time.sleep(3)
    fail("%s not healthy after %ds: %s" % (name, timeout, last))


def fields_list(values: Dict[str, Any]) -> List[Dict[str, Any]]:
    return [{"name": name, "value": value} for name, value in values.items()]


def fields_map(item: Dict[str, Any]) -> Dict[str, Any]:
    return {f["name"]: f.get("value") for f in item.get("fields", [])}


def build_prowlarr_app(kind: str, api_key: str) -> Dict[str, Any]:
    if kind == "sonarr":
        base_url = SONARR_BASE
        contract = "SonarrSettings"
        name = "Sonarr"
        extra = {
            "syncCategories": SONARR_SYNC_CATEGORIES,
            "animeSyncCategories": SONARR_ANIME_CATEGORIES,
            "syncAnimeStandardFormatSearch": True,
        }
    elif kind == "radarr":
        base_url = RADARR_BASE
        contract = "RadarrSettings"
        name = "Radarr"
        extra = {"syncCategories": RADARR_SYNC_CATEGORIES}
    else:
        fail("unknown app kind: %s (expected sonarr|radarr)" % kind)
    fields = {
        "prowlarrUrl": PROWLARR_BASE,
        "baseUrl": base_url,
        "apiKey": api_key,
        "authUsername": None,
        "authPassword": None,
        "syncRejectBlocklistedTorrentHashesWhileGrabbing": False,
    }
    fields.update(extra)
    return {
        "enable": True,
        "name": name,
        "implementation": name,
        "implementationName": name,
        "configContract": contract,
        "syncLevel": "fullSync",
        "fields": fields_list(fields),
    }


def build_download_client(kind: str, host: str, port: int,
                          username: str, password: str) -> Dict[str, Any]:
    if kind == "sonarr":
        category = {"tvCategory": SONARR_CATEGORY, "recentTvPriority": 0,
                    "olderTvPriority": 0, "tvImportedCategory": None}
    elif kind == "radarr":
        category = {"movieCategory": RADARR_CATEGORY, "recentMoviePriority": 0,
                    "olderMoviePriority": 0, "movieImportedCategory": None}
    else:
        fail("unknown app kind: %s (expected sonarr|radarr)" % kind)
    fields = {
        "host": host,
        "port": port,
        "useSsl": False,
        "urlBase": None,
        "apiKey": None,
        "username": username,
        "password": password,
        "initialState": 0,
        "sequentialOrder": False,
        "firstAndLast": False,
        "contentLayout": 0,
    }
    fields.update(category)
    return {
        "enable": True,
        "protocol": "torrent",
        "priority": 1,
        "removeCompletedDownloads": True,
        "removeFailedDownloads": True,
        "name": "qBittorrent",
        "implementation": "QBittorrent",
        "implementationName": "qBittorrent",
        "configContract": "QBittorrentSettings",
        "fields": fields_list(fields),
    }


def merge_fields(existing: Dict[str, Any],
                 desired: Dict[str, Any]) -> Dict[str, Any]:
    merged = dict(existing)
    by_name = {f["name"]: f.get("value") for f in merged.get("fields", [])}
    for field in desired.get("fields", []):
        by_name[field["name"]] = field["value"]
    merged["fields"] = [{"name": n, "value": v} for n, v in by_name.items()]
    for key, value in desired.items():
        if key not in ("id", "fields"):
            merged[key] = value
    return merged


# Placeholder Servarr APIs return for privacy-guarded fields instead of real values.
# A masked read can never prove a secret matches, so it counts as equal for
# idempotency; rotating a secret therefore requires removing the resource first
# (delete the client/app, then re-run to recreate it with the new secret).
MASKED_SECRET_PLACEHOLDER = "********"


def _secret_aware_equal(current: Any, desired: Any) -> bool:
    return current == desired or current == MASKED_SECRET_PLACEHOLDER


def plan_action(match: Callable[[Dict[str, Any]], bool],
                collection: List[Dict[str, Any]],
                desired: Dict[str, Any]) -> str:
    item = matching_item(match, collection)
    if item is None:
        return "created"
    merged = merge_fields(item, desired)
    merged_map = fields_map(merged)
    item_map = fields_map(item)
    desired_properties = {key: value for key, value in desired.items()
                          if key not in ("id", "fields")}
    if (merged_map.keys() == item_map.keys()
            and all(_secret_aware_equal(item_map[name], merged_map[name]) for name in merged_map)
            and all(merged.get(key) == item.get(key) for key in desired_properties)):
        return "unchanged"
    return "updated"


def upsert(match: Callable[[Dict[str, Any]], bool],
           collection: List[Dict[str, Any]],
           desired: Dict[str, Any],
           create: Callable[[Dict[str, Any]], Any],
           update: Callable[[int, Dict[str, Any]], Any]) -> Tuple[str, Any]:
    action = plan_action(match, collection, desired)
    if action == "created":
        return action, create(desired)
    target = matching_item(match, collection)
    if action == "unchanged":
        return action, target
    return action, update(target["id"], merge_fields(target, desired))


def matching_item(match: Callable[[Dict[str, Any]], bool],
                  collection: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    matches = [item for item in collection if match(item)]
    if len(matches) > 1:
        fail("multiple matching integration resources found; remove duplicates before retrying")
    return matches[0] if matches else None


def ensure_root_folder(base: str, api_key: str, path: str,
                       dry_run: bool, counters: Dict[str, int]) -> None:
    folders = servarr_request("GET", base, api_key, "/api/v3/rootfolder") or []
    wanted_path = path.rstrip("/") or "/"
    for folder in folders:
        existing_path = (folder.get("path") or "").rstrip("/") or "/"
        if existing_path != wanted_path:
            continue
        if folder.get("accessible") is False:
            fail("root folder %s is not accessible; check the /data mount" % path)
        counters["unchanged"] += 1
        log("root folder %s already present" % path)
        return
    if dry_run:
        counters["created"] += 1
        log("[dry-run] would create root folder %s" % path)
        return
    servarr_request("POST", base, api_key, "/api/v3/rootfolder", {"path": path})
    counters["created"] += 1
    log("created root folder %s" % path)


def match_qbittorrent(item: Dict[str, Any]) -> bool:
    return item.get("implementation") == "QBittorrent"


def ensure_download_client(kind: str, base: str, api_key: str, host: str,
                           port: int, username: str, password: str,
                           dry_run: bool, counters: Dict[str, int]) -> None:
    desired = build_download_client(kind, host, port, username, password)
    clients = servarr_request("GET", base, api_key, "/api/v3/downloadclient") or []
    if dry_run:
        action = plan_action(match_qbittorrent, clients, desired)
        counters[action] += 1
        log("[dry-run] would %s qBittorrent download client (%s)" % (action, kind))
        return
    action, _ = upsert(
        match_qbittorrent, clients, desired,
        lambda body: servarr_request("POST", base, api_key, "/api/v3/downloadclient", body),
        lambda i, body: servarr_request("PUT", base, api_key, "/api/v3/downloadclient/%d" % i, body),
    )
    counters[action] += 1
    log("qBittorrent download client (%s): %s" % (kind, action))


def ensure_prowlarr_app(kind: str, prowlarr_key: str, target_key: str,
                        dry_run: bool, counters: Dict[str, int]) -> None:
    desired = build_prowlarr_app(kind, target_key)
    name = desired["name"]

    def match(item: Dict[str, Any]) -> bool:
        return item.get("implementation") == name

    apps = servarr_request("GET", PROWLARR_BASE, prowlarr_key, "/api/v1/applications") or []
    if dry_run:
        action = plan_action(match, apps, desired)
        counters[action] += 1
        log("[dry-run] would %s Prowlarr application %s" % (action, name))
        return
    action, _ = upsert(
        match, apps, desired,
        lambda body: servarr_request("POST", PROWLARR_BASE, prowlarr_key, "/api/v1/applications", body),
        lambda i, body: servarr_request("PUT", PROWLARR_BASE, prowlarr_key, "/api/v1/applications/%d" % i, body),
    )
    counters[action] += 1
    log("Prowlarr application %s: %s" % (name, action))


def build_qbit_login_request(host: str, port: int, username: str,
                             password: str) -> urllib.request.Request:
    url_host = "[%s]" % host if ":" in host and not host.startswith("[") else host
    base = "http://%s:%d" % (url_host, port)
    data = urllib.parse.urlencode({"username": username, "password": password}).encode()
    req = urllib.request.Request(base + "/api/v2/auth/login", data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    req.add_header("Origin", base)
    req.add_header("Referer", base + "/")
    return req


def qbit_login_succeeded(status: int, body: str) -> bool:
    return status == 204 or (status == 200 and body.strip() in ("", "Ok."))


def check_qbit_login(host: str, port: int, username: str, password: str) -> None:
    deadline = time.time() + 30
    last_error: Optional[Exception] = None
    while time.time() < deadline:
        req = build_qbit_login_request(host, port, username, password)
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                if not qbit_login_succeeded(resp.status, resp.read().decode()):
                    fail("qBittorrent login rejected — check qBittorrent credentials")
                log("qBittorrent login ok")
                return
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                fail("qBittorrent login failed (HTTP %s) — check host/user/password" % exc.code)
            if exc.code == 404:
                fail("qBittorrent login endpoint returned HTTP 404; check host and port")
            last_error = "HTTP %s" % exc.code
        except OSError as exc:
            last_error = exc
        time.sleep(2)
    fail("qBittorrent login did not succeed at %s:%d after 30s: %s"
         % (host, port, last_error))


def parse_bazarr_yaml(path: str) -> Dict[str, Any]:
    yaml = _ruamel_yaml()
    with open(path, encoding="utf-8", errors="replace") as handle:
        doc = yaml.load(handle) or {}
    if not isinstance(doc, dict):
        fail("unsupported Bazarr config format in %s (expected top-level mapping)" % path)
    return doc


def load_bazarr_api_key(config_path: str, timeout: int = 60) -> str:
    deadline = time.time() + timeout
    last_error = "file not found"
    while time.time() < deadline:
        try:
            sections = parse_bazarr_yaml(config_path)
            api_key = (sections.get("auth") or {}).get("apikey", "")
            if api_key:
                return api_key
            last_error = "auth.apikey is empty"
        except OSError as exc:
            last_error = str(exc)
        except _RETRYABLE_YAML_ERRORS as exc:
            last_error = "unparseable YAML: %s" % exc
        time.sleep(2)
    fail("timed out waiting for Bazarr API key in %s: %s" % (config_path, last_error))


def desired_bazarr_settings(sonarr_key: str, radarr_key: str) -> Dict[str, Any]:
    return {
        "sonarr": {"ip": LOCALHOST_IP, "port": SONARR_PORT,
                   "base_url": "", "ssl": False, "apikey": sonarr_key},
        "radarr": {"ip": LOCALHOST_IP, "port": RADARR_PORT,
                   "base_url": "", "ssl": False, "apikey": radarr_key},
        "general": {"use_sonarr": True, "use_radarr": True},
    }


def normalize_bazarr_base_url(value: Any) -> str:
    return "" if value in (None, "", "/") else str(value).rstrip("/")


def bazarr_settings_form(sonarr_key: str, radarr_key: str) -> Dict[str, str]:
    desired = desired_bazarr_settings(sonarr_key, radarr_key)
    return {
        "settings-sonarr-ip": desired["sonarr"]["ip"],
        "settings-sonarr-port": str(desired["sonarr"]["port"]),
        "settings-sonarr-base_url": desired["sonarr"]["base_url"],
        "settings-sonarr-ssl": "false",
        "settings-sonarr-apikey": desired["sonarr"]["apikey"],
        "settings-radarr-ip": desired["radarr"]["ip"],
        "settings-radarr-port": str(desired["radarr"]["port"]),
        "settings-radarr-base_url": desired["radarr"]["base_url"],
        "settings-radarr-ssl": "false",
        "settings-radarr-apikey": desired["radarr"]["apikey"],
        "settings-general-use_sonarr": "true",
        "settings-general-use_radarr": "true",
    }


def rewrite_bazarr_yaml(config_path: str, sonarr_key: str, radarr_key: str) -> None:
    yaml = _ruamel_yaml()
    with open(config_path, encoding="utf-8", errors="replace") as handle:
        doc = yaml.load(handle) or {}
    if not isinstance(doc, dict):
        fail("unsupported Bazarr config format in %s (expected top-level mapping)" % config_path)
    original_stat = os.stat(config_path)
    desired = desired_bazarr_settings(sonarr_key, radarr_key)
    for section, values in desired.items():
        node = doc.setdefault(section, {})
        if not isinstance(node, dict):
            fail("unsupported Bazarr config format in %s: section '%s' is not a mapping"
                 % (config_path, section))
        for key, value in values.items():
            node[key] = value
    fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(config_path) or ".",
                                    prefix=".config.yaml.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            yaml.dump(doc, handle)
        os.chmod(tmp_path, stat.S_IRUSR | stat.S_IWUSR)
        if os.geteuid() == 0:
            os.chown(tmp_path, original_stat.st_uid, original_stat.st_gid)
        os.replace(tmp_path, config_path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def is_bazarr_linked(settings: Dict[str, Any], sonarr_key: str, radarr_key: str) -> bool:
    desired = desired_bazarr_settings(sonarr_key, radarr_key)
    sonarr = settings.get("sonarr", {}) or {}
    radarr = settings.get("radarr", {}) or {}
    general = settings.get("general", {}) or {}
    return (all((normalize_bazarr_base_url(sonarr.get(key, ""))
                 if key == "base_url" else sonarr.get(key, "")) == value
               for key, value in desired["sonarr"].items())
            and all((normalize_bazarr_base_url(radarr.get(key, ""))
                     if key == "base_url" else radarr.get(key, "")) == value
                    for key, value in desired["radarr"].items())
            and all(general.get(key) is value for key, value in desired["general"].items()))


def link_bazarr_via_api(api_key: str, sonarr_key: str, radarr_key: str) -> bool:
    try:
        bazarr_request(api_key, "POST", "/api/system/settings",
                       bazarr_settings_form(sonarr_key, radarr_key), form=True)
    except ApiError as exc:
        if exc.status in (401, 403):
            fail("Bazarr settings update rejected with HTTP %s; check its API key" % exc.status)
        log("Bazarr API update failed (%s) — falling back to config file" % exc)
        return False
    return wait_for_bazarr_link(api_key, sonarr_key, radarr_key)


def link_bazarr_via_file() -> None:
    proc = subprocess.run(["systemctl", "restart", "bazarr"])
    if proc.returncode != 0:
        fail("bazarr restart failed (exit %d) — fix the service before retrying"
             % proc.returncode)
    deadline = time.time() + 30
    while time.time() < deadline:
        status = subprocess.run(["systemctl", "is-active", "--quiet", "bazarr"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if status.returncode == 0:
            return
        time.sleep(1)
    fail("bazarr did not become active within 30s after restart")


def wait_for_bazarr_settings(api_key: str, timeout: int = 30) -> Dict[str, Any]:
    deadline = time.time() + timeout
    last: Optional[Exception] = None
    while time.time() < deadline:
        try:
            return bazarr_request(api_key, "GET", "/api/system/settings") or {}
        except ApiError as exc:
            if exc.status in (401, 403, 404):
                fail("Bazarr settings request failed with HTTP %s; check its API key and endpoint"
                     % exc.status)
            last = exc
            time.sleep(2)
    fail("Bazarr API was not ready after %ds: %s" % (timeout, last))


def wait_for_bazarr_link(api_key: str, sonarr_key: str, radarr_key: str,
                         timeout: int = 30) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            settings = bazarr_request(api_key, "GET", "/api/system/settings") or {}
            if is_bazarr_linked(settings, sonarr_key, radarr_key):
                return True
        except ApiError as exc:
            if exc.status in (401, 403, 404):
                fail("Bazarr verification failed with HTTP %s; check its API key and endpoint"
                     % exc.status)
        time.sleep(2)
    return False


def ensure_bazarr(sonarr_key: str, radarr_key: str,
                  dry_run: bool, config_path: str = BAZARR_CONFIG) -> str:
    api_key = load_bazarr_api_key(config_path)
    settings = wait_for_bazarr_settings(api_key)
    if is_bazarr_linked(settings, sonarr_key, radarr_key):
        log("Bazarr already linked to Sonarr/Radarr")
        return "unchanged"
    if dry_run:
        log("[dry-run] would link Bazarr to Sonarr/Radarr")
        return "would_link"
    if link_bazarr_via_api(api_key, sonarr_key, radarr_key):
        log("Bazarr linked to Sonarr/Radarr via API")
        return "linked"
    rewrite_bazarr_yaml(config_path, sonarr_key, radarr_key)
    link_bazarr_via_file()
    if wait_for_bazarr_link(api_key, sonarr_key, radarr_key):
        log("Bazarr linked to Sonarr/Radarr via config file")
        return "linked"
    fail("Bazarr linking did not persist")


def build_summary(versions: Dict[str, str], apps: Dict[str, int],
                  clients: Dict[str, int], folders: Dict[str, int],
                  bazarr_action: str, dry_run: bool) -> Dict[str, Any]:
    return {
        "dry_run": dry_run,
        "versions": versions,
        "prowlarr_apps": apps,
        "download_clients": clients,
        "root_folders": folders,
        "bazarr": bazarr_action,
    }


def dump_desired(host: str, port: int, username: str) -> Dict[str, Any]:
    return {
        "prowlarr_sonarr": build_prowlarr_app("sonarr", "APIKEY"),
        "prowlarr_radarr": build_prowlarr_app("radarr", "APIKEY"),
        "download_sonarr": build_download_client("sonarr", host, port, username, "QBIT_PASS"),
        "download_radarr": build_download_client("radarr", host, port, username, "QBIT_PASS"),
    }


def self_test() -> int:
    failures = []

    def check(label: str, condition: bool) -> None:
        print(("PASS" if condition else "FAIL") + " " + label)
        if not condition:
            failures.append(label)

    leaked = str(ApiError(400, '{"message":"Invalid host","password":"s3cret",'
                              '"apiKey":"K","detail":"apikey=zzz&host=h"}'))
    check("api errors scrub secrets",
          "s3cret" not in leaked and '"K"' not in leaked and "zzz" not in leaked)
    check("api errors keep diagnostics",
          "400" in leaked and "Invalid host" in leaked and "host=h" in leaked)

    sonarr_app = build_prowlarr_app("sonarr", "KEY1")
    check("prowlarr sonarr contract", sonarr_app["configContract"] == "SonarrSettings")
    check("prowlarr sonarr sync level", sonarr_app["syncLevel"] == "fullSync")
    smap = fields_map(sonarr_app)
    check("prowlarr sonarr base url", smap["baseUrl"] == SONARR_BASE)
    check("prowlarr sonarr url", smap["prowlarrUrl"] == PROWLARR_BASE)
    check("prowlarr sonarr key", smap["apiKey"] == "KEY1")
    check("prowlarr sonarr categories", smap["syncCategories"] == SONARR_SYNC_CATEGORIES)
    check("prowlarr sonarr anime categories", smap["animeSyncCategories"] == SONARR_ANIME_CATEGORIES)

    radarr_app = build_prowlarr_app("radarr", "KEY2")
    rmap = fields_map(radarr_app)
    check("prowlarr radarr contract", radarr_app["configContract"] == "RadarrSettings")
    check("prowlarr radarr base url", rmap["baseUrl"] == RADARR_BASE)
    check("prowlarr radarr categories", rmap["syncCategories"] == RADARR_SYNC_CATEGORIES)

    try:
        build_prowlarr_app("sonar", "KEY3")
        check("prowlarr rejects unknown kind", False)
    except SystemExit:
        check("prowlarr rejects unknown kind", True)
    try:
        build_download_client("radarr2", "h", 1, "u", "p")
        check("client rejects unknown kind", False)
    except SystemExit:
        check("client rejects unknown kind", True)

    sonarr_client = build_download_client("sonarr", "192.168.31.86", 8090, "admin", "pw")
    check("client implementation", sonarr_client["implementation"] == "QBittorrent")
    cmap = fields_map(sonarr_client)
    check("client host override", cmap["host"] == "192.168.31.86")
    check("client port override", cmap["port"] == 8090)
    check("client credentials", cmap["username"] == "admin" and cmap["password"] == "pw")
    check("client SSL disabled", cmap["useSsl"] is False)
    check("client tv category", cmap.get("tvCategory") == SONARR_CATEGORY)

    radarr_client = build_download_client("radarr", "192.168.31.86", 8090, "admin", "pw")
    rcmap = fields_map(radarr_client)
    check("client movie category", rcmap.get("movieCategory") == RADARR_CATEGORY)
    check("client movie category not schema default", rcmap.get("movieCategory") != "radarr")
    login_request = build_qbit_login_request("192.168.31.86", 8090, "admin", "pw")
    check("qbit login uses form content type",
          login_request.get_header("Content-type") == "application/x-www-form-urlencoded")
    check("qbit login sends referer", login_request.get_header("Referer") == "http://192.168.31.86:8090/")
    ipv6_request = build_qbit_login_request("2001:db8::86", 8090, "admin", "pw")
    check("qbit IPv6 URL is bracketed", ipv6_request.full_url == "http://[2001:db8::86]:8090/api/v2/auth/login")
    check("qbit accepts current login responses",
          qbit_login_succeeded(200, "Ok.") and qbit_login_succeeded(204, "")
          and not qbit_login_succeeded(403, "Fails."))

    existing = {"id": 3, "enable": True, "fields": [{"name": "host", "value": "localhost"}]}
    merged = merge_fields(existing, sonarr_client)
    check("merge keeps id", merged["id"] == 3)
    check("merge overrides host", fields_map(merged)["host"] == "192.168.31.86")
    check("merge propagates priority", merged.get("priority") == 1)
    keep = dict(existing)
    keep["fields"] = [{"name": "custom", "value": "x"}]
    check("merge preserves unknown fields", fields_map(merge_fields(keep, sonarr_client)).get("custom") == "x")

    check("plan empty creates", plan_action(match_qbittorrent, [], sonarr_client) == "created")
    same = {"id": 1, "enable": True, "priority": 1, "protocol": "torrent",
            "name": "qBittorrent", "implementation": "QBittorrent",
            "implementationName": "qBittorrent", "configContract": "QBittorrentSettings",
            "removeCompletedDownloads": True, "removeFailedDownloads": True,
            "fields": fields_list(cmap)}
    check("plan identical unchanged", plan_action(match_qbittorrent, [same], sonarr_client) == "unchanged")
    stale = dict(same)
    stale["fields"] = fields_list(dict(cmap, host="10.0.0.1"))
    check("plan stale updated", plan_action(match_qbittorrent, [stale], sonarr_client) == "updated")
    drift = dict(same)
    drift["removeCompletedDownloads"] = False
    check("plan cleanup drift updated", plan_action(match_qbittorrent, [drift], sonarr_client) == "updated")
    masked = dict(same)
    masked["fields"] = fields_list(dict(cmap, host="192.168.31.86", password="********",
                                        username="admin", port=8090))
    check("plan masked secrets unchanged",
          plan_action(match_qbittorrent, [masked], sonarr_client) == "unchanged")
    masked_stale = dict(masked)
    masked_stale["fields"] = fields_list(dict(cmap, host="10.0.0.1", password="********"))
    check("plan masked secrets with stale host updated",
          plan_action(match_qbittorrent, [masked_stale], sonarr_client) == "updated")

    calls: List[Tuple[str, Any]] = []

    def fake_create(body: Dict[str, Any]) -> Any:
        calls.append(("create", body))
        return {"id": 7}

    def fake_update(i: int, body: Dict[str, Any]) -> Any:
        calls.append(("update", (i, body)))
        return body

    action, _ = upsert(match_qbittorrent, [], sonarr_client, fake_create, fake_update)
    check("upsert empty creates", action == "created" and calls[-1][0] == "create")
    action, _ = upsert(match_qbittorrent, [same], sonarr_client, fake_create, fake_update)
    check("upsert identical unchanged", action == "unchanged" and len(calls) == 1)
    action, result = upsert(match_qbittorrent, [stale], sonarr_client, fake_create, fake_update)
    check("upsert stale updates id",
          action == "updated" and calls[-1][0] == "update" and calls[-1][1][0] == 1)
    check("upsert update carries merged host",
          fields_map(calls[-1][1][1])["host"] == "192.168.31.86")
    try:
        matching_item(match_qbittorrent, [same, same])
        check("duplicate matches rejected", False)
    except SystemExit:
        check("duplicate matches rejected", True)

    import tempfile
    if not HAVE_RUAMEL:
        print("SKIP yaml round-trip checks (ruamel.yaml not installed)")
    else:
        sample = ("auth:\n  apikey: 'AUTHKEY' # rotated weekly\n  type: null\n"
                  "sonarr:\n  ip: 10.0.0.2\n  port: 1\n  base_url: '/wrong'\n  ssl: True\n  apikey: ''\n"
                  "radarr:\n  ip: 10.0.0.3\n  port: 2\n  base_url: '/wrong'\n  ssl: True\n  apikey: ''\n"
                  "general:\n  use_sonarr: False\n  use_radarr: False\n"
                  "unrelated:\n  keep_me: yes # operator tuning\n")
        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as tmp:
            tmp.write(sample)
            tmp_path = tmp.name
        parsed = parse_bazarr_yaml(tmp_path)
        check("yaml auth key wins", parsed["auth"]["apikey"] == "AUTHKEY")
        check("yaml empty sonarr key", parsed["sonarr"]["apikey"] == "")
        check("yaml native port type", parsed["sonarr"]["port"] == 1)
        rewrite_bazarr_yaml(tmp_path, "SKEY", "RKEY")
        reparsed = parse_bazarr_yaml(tmp_path)
        check("yaml rewrite persists keys",
              reparsed["sonarr"]["ip"] == LOCALHOST_IP
              and reparsed["sonarr"]["port"] == SONARR_PORT
              and reparsed["sonarr"]["base_url"] == ""
              and reparsed["sonarr"]["ssl"] is False
              and reparsed["sonarr"]["apikey"] == "SKEY"
              and reparsed["radarr"]["apikey"] == "RKEY"
              and reparsed["general"]["use_sonarr"] is True
              and reparsed["general"]["use_radarr"] is True)
        with open(tmp_path, encoding="utf-8") as handle:
            rewritten = handle.read()
        check("yaml comments survive rewrite", "# rotated weekly" in rewritten)
        check("yaml unknown keys survive rewrite", "keep_me" in rewritten)
        minimal = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False)
        minimal.write("auth:\n  apikey: 'AUTHKEY'\n")
        minimal.close()
        rewrite_bazarr_yaml(minimal.name, "SKEY", "RKEY")
        minimal_sections = parse_bazarr_yaml(minimal.name)
        check("yaml rewrite adds missing sections",
              minimal_sections["sonarr"]["apikey"] == "SKEY"
              and minimal_sections["radarr"]["apikey"] == "RKEY"
              and minimal_sections["general"]["use_sonarr"] is True)
        bad = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False)
        bad.write("- just\n- a\n- list\n")
        bad.close()
        try:
            parse_bazarr_yaml(bad.name)
            check("yaml rejects non-mapping top level", False)
        except SystemExit:
            check("yaml rejects non-mapping top level", True)

    linked = {
        "sonarr": {"ip": LOCALHOST_IP, "port": SONARR_PORT, "base_url": "",
                   "ssl": False, "apikey": "SKEY"},
        "radarr": {"ip": LOCALHOST_IP, "port": RADARR_PORT, "base_url": "",
                   "ssl": False, "apikey": "RKEY"},
        "general": {"use_sonarr": True, "use_radarr": True},
    }
    check("linked detected", is_bazarr_linked(linked, "SKEY", "RKEY") is True)
    slash_linked = dict(linked)
    slash_linked["sonarr"] = dict(linked["sonarr"], base_url="/")
    check("bazarr root base URL normalized", is_bazarr_linked(slash_linked, "SKEY", "RKEY") is True)
    check("unlinked detected", is_bazarr_linked({"sonarr": {"apikey": ""}}, "SKEY", "RKEY") is False)
    check("bazarr form uses API field names",
          bazarr_settings_form("SKEY", "RKEY")["settings-general-use_sonarr"] == "true"
          and bazarr_settings_form("SKEY", "RKEY")["settings-sonarr-port"] == str(SONARR_PORT))

    summary = build_summary({"sonarr": "4.x"}, {"created": 1, "updated": 0, "unchanged": 0},
                            {"created": 0, "updated": 0, "unchanged": 0},
                            {"created": 0, "updated": 0, "unchanged": 0},
                            "linked", False)
    check("summary shape locked",
          set(summary.keys()) == {"dry_run", "versions", "prowlarr_apps",
                                  "download_clients", "root_folders", "bazarr"})
    check("fields round-trip", fields_map({"fields": fields_list(cmap)}) == cmap)

    print("%d failures" % len(failures))
    return 1 if failures else 0


def valid_port(value: str) -> int:
    try:
        port = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("port must be numeric") from exc
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("port must be between 1 and 65535")
    return port


def valid_host(value: str) -> str:
    host = value.strip("[]")
    try:
        ipaddress.ip_address(host)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("qBittorrent host must be an IP address") from exc
    return host


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Wire Starr integrations (runs inside starr LXC)")
    parser.add_argument("--qbit-host", type=valid_host, required=False, default=None)
    parser.add_argument("--qbit-user", default="admin")
    parser.add_argument("--qbit-pass-stdin", action="store_true")
    parser.add_argument("--qbit-port", type=valid_port, default=8090)
    parser.add_argument("--data-root", default=DATA_ROOT)
    parser.add_argument("--skip-bazarr", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--dump-desired", action="store_true")
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    if args.self_test:
        return self_test()
    if args.dump_desired:
        print(json.dumps(dump_desired(args.qbit_host or "QBIT_HOST",
                                      args.qbit_port,
                                      args.qbit_user)))
        return 0
    if not args.qbit_host:
        fail("--qbit-host is required")
    if not args.qbit_pass_stdin:
        fail("--qbit-pass-stdin is required")
    args.qbit_pass = sys.stdin.readline().rstrip("\r\n")
    if not args.qbit_pass:
        fail("qBittorrent password was not provided on stdin")

    prowlarr_key = read_api_key(args.data_root, "prowlarr")
    sonarr_key = read_api_key(args.data_root, "sonarr")
    radarr_key = read_api_key(args.data_root, "radarr")

    if not args.dry_run:
        check_qbit_login(args.qbit_host, args.qbit_port, args.qbit_user, args.qbit_pass)

    versions = {}
    versions["prowlarr"] = wait_healthy("prowlarr", PROWLARR_BASE, prowlarr_key, "/api/v1/system/status").get("version", "?")
    versions["sonarr"] = wait_healthy("sonarr", SONARR_BASE, sonarr_key, "/api/v3/system/status").get("version", "?")
    versions["radarr"] = wait_healthy("radarr", RADARR_BASE, radarr_key, "/api/v3/system/status").get("version", "?")

    apps: Dict[str, int] = {"created": 0, "updated": 0, "unchanged": 0}
    clients: Dict[str, int] = {"created": 0, "updated": 0, "unchanged": 0}
    folders: Dict[str, int] = {"created": 0, "updated": 0, "unchanged": 0}

    ensure_root_folder(SONARR_BASE, sonarr_key, SONARR_ROOT, args.dry_run, folders)
    ensure_root_folder(RADARR_BASE, radarr_key, RADARR_ROOT, args.dry_run, folders)
    ensure_download_client("sonarr", SONARR_BASE, sonarr_key, args.qbit_host,
                           args.qbit_port, args.qbit_user, args.qbit_pass,
                           args.dry_run, clients)
    ensure_download_client("radarr", RADARR_BASE, radarr_key, args.qbit_host,
                           args.qbit_port, args.qbit_user, args.qbit_pass,
                           args.dry_run, clients)
    ensure_prowlarr_app("sonarr", prowlarr_key, sonarr_key, args.dry_run, apps)
    ensure_prowlarr_app("radarr", prowlarr_key, radarr_key, args.dry_run, apps)

    bazarr_action = "skipped"
    if not args.skip_bazarr:
        bazarr_config = os.path.join(args.data_root, "bazarr", "config", "config.yaml")
        bazarr_action = ensure_bazarr(sonarr_key, radarr_key, args.dry_run, bazarr_config)

    print(json.dumps(build_summary(versions, apps, clients, folders, bazarr_action, args.dry_run)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ApiError as exc:
        fail("API request failed: %s" % exc)
    except (OSError, ValueError) as exc:
        fail("configuration failed: %s" % exc)
