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
import base64
import hashlib
import ipaddress
import json
import os
import re
import sys
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

PROWLARR_TAG_PATH = "/api/v1/tag"
PROWLARR_INDEXER_PROXY_PATH = "/api/v1/indexerproxy"
# Provider writes are force-saved because Prowlarr's built-in Test calls its own cloud
# endpoint; also IndexerProxyDefinition.Enable derives from Tags, so a tagless proxy
# would otherwise be created disabled. Health is verified directly instead.
PROWLARR_FORCE_SAVE = "?forceSave=true"

FLARESOLVERR_HOST = "http://127.0.0.1:8191"
FLARESOLVERR_HEALTH_URL = FLARESOLVERR_HOST + "/health"
FLARESOLVERR_REQUEST_TIMEOUT = 60
FLARESOLVERR_TAG_LABEL = "flaresolverr"
FLARESOLVERR_IMPLEMENTATION = "FlareSolverr"
# Dry-run stand-in for a tag that does not exist yet
PLANNED_TAG_ID = -1

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


def bazarr_request(method: str, path: str, api_key: str,
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
    if current == desired or current == MASKED_SECRET_PLACEHOLDER:
        return True
    return _md5_matches(current, desired)


def _md5_matches(current: Any, desired: Any) -> bool:
    """True when the stored value is the MD5 hex digest of the secret.

    Bazarr persists auth.password as MD5 hex, never plaintext; matching
    the digest proves knowledge of the secret with no false positives.
    """
    if not isinstance(current, str) or not isinstance(desired, str):
        return False
    if len(current) != 32:
        return False
    try:
        int(current, 16)
    except ValueError:
        return False
    return hashlib.md5(desired.encode()).hexdigest() == current.lower()


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
        if folder.get("accessible") == False:
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


# --- FlareSolverr (Cloudflare solver Prowlarr proxies indexers through) ---

def probe_flaresolverr(timeout: int = 5) -> bool:
    req = urllib.request.Request(FLARESOLVERR_HEALTH_URL, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status == 200
    except (urllib.error.HTTPError, urllib.error.URLError, OSError, TimeoutError, ValueError):
        return False


def build_flaresolverr_proxy(tag_ids: List[int]) -> Dict[str, Any]:
    fields = {"host": FLARESOLVERR_HOST,
              "requestTimeout": FLARESOLVERR_REQUEST_TIMEOUT}
    return {
        "name": FLARESOLVERR_IMPLEMENTATION,
        "implementation": FLARESOLVERR_IMPLEMENTATION,
        "implementationName": FLARESOLVERR_IMPLEMENTATION,
        "configContract": "FlareSolverrSettings",
        "fields": fields_list(fields),
        "tags": list(tag_ids),
    }


def match_flaresolverr_proxy(item: Dict[str, Any]) -> bool:
    return item.get("implementation") == FLARESOLVERR_IMPLEMENTATION


def find_tag_id(tags: List[Dict[str, Any]], label: str) -> Optional[int]:
    for tag in tags:
        if str(tag.get("label", "")).lower() == label.lower():
            return tag.get("id")
    return None


def ensure_flaresolverr_tag(api_key: str,
                            dry_run: bool) -> Tuple[Optional[int], str]:
    tag_id = find_tag_id(servarr_request("GET", PROWLARR_BASE, api_key,
                                         PROWLARR_TAG_PATH) or [],
                         FLARESOLVERR_TAG_LABEL)
    if tag_id is not None:
        return tag_id, "unchanged"
    if dry_run:
        return None, "created"
    servarr_request("POST", PROWLARR_BASE, api_key, PROWLARR_TAG_PATH,
                    {"label": FLARESOLVERR_TAG_LABEL})
    tag_id = find_tag_id(servarr_request("GET", PROWLARR_BASE, api_key,
                                         PROWLARR_TAG_PATH) or [],
                         FLARESOLVERR_TAG_LABEL)
    if tag_id is None:
        fail("Prowlarr tag '%s' was not created" % FLARESOLVERR_TAG_LABEL)
    return tag_id, "created"


def ensure_flaresolverr_proxy(api_key: str, tag_ids: List[int],
                              dry_run: bool) -> str:
    desired = build_flaresolverr_proxy(tag_ids)
    proxies = servarr_request("GET", PROWLARR_BASE, api_key,
                              PROWLARR_INDEXER_PROXY_PATH) or []
    if dry_run:
        return plan_action(match_flaresolverr_proxy, proxies, desired)
    action, _ = upsert(
        match_flaresolverr_proxy, proxies, desired,
        lambda body: servarr_request("POST", PROWLARR_BASE, api_key,
                                     PROWLARR_INDEXER_PROXY_PATH + PROWLARR_FORCE_SAVE, body),
        lambda i, body: servarr_request("PUT", PROWLARR_BASE, api_key,
                                        "%s/%d%s" % (PROWLARR_INDEXER_PROXY_PATH, i,
                                                     PROWLARR_FORCE_SAVE), body),
    )
    return action


def ensure_flaresolverr(api_key: str, dry_run: bool) -> str:
    if not probe_flaresolverr():
        log("FlareSolverr is not answering on %s — skipping its Prowlarr setup"
            % FLARESOLVERR_HEALTH_URL)
        return "unavailable"

    tag_id, tag_action = ensure_flaresolverr_tag(api_key, dry_run)
    effective_tag = tag_id if tag_id is not None else PLANNED_TAG_ID
    proxy_action = ensure_flaresolverr_proxy(api_key, [effective_tag], dry_run)

    if dry_run:
        log("[dry-run] would %s tag '%s', %s proxy (indexers tagged manually)"
            % ("create" if tag_action == "created" else "keep",
               FLARESOLVERR_TAG_LABEL, proxy_action))
        if tag_action == "unchanged" and proxy_action == "unchanged":
            return "unchanged"
        return "would_configure"
    log("Prowlarr FlareSolverr: tag %s, proxy %s (indexers tagged manually)"
        % (tag_action, proxy_action))
    if tag_action == "unchanged" and proxy_action == "unchanged":
        return "unchanged"
    return "configured"


# --- Seerr (Jellyfin request manager, same CT, port 5055) ---

SEERR_BASE = "http://localhost:5055"
SEERR_PUBLIC_PATH = "/api/v1/settings/public"
SEERR_SONARR_PATH = "/api/v1/settings/sonarr"
SEERR_RADARR_PATH = "/api/v1/settings/radarr"
SEERR_JELLYFIN_PATH = "/api/v1/settings/jellyfin"
SEERR_SETTINGS_FILE = "/opt/seerr/config/settings.json"
SEERR_SONARR_NAME = "Sonarr"
SEERR_RADARR_NAME = "Radarr"
JELLYFIN_DEFAULT_PORT = 8096


def seerr_request(method: str, path: str, api_key: str,
                  body: Optional[Dict[str, Any]] = None) -> Any:
    return api_request(method, SEERR_BASE, "X-Api-Key", api_key, path, body)


def read_seerr_api_key(settings_path: str = SEERR_SETTINGS_FILE,
                       timeout: int = 60) -> str:
    """Poll the Seerr settings file for main.apiKey; "" when it never appears.

    Empty means Seerr has not finished its first boot — the caller reports
    needs_setup instead of failing, so the rest of the run still applies.
    """
    deadline = time.time() + timeout
    last_error = "file not found"
    while time.time() < deadline:
        try:
            with open(settings_path, encoding="utf-8") as handle:
                doc = json.load(handle)
            api_key = ((doc.get("main") or {}).get("apiKey") or "").strip()
            if api_key:
                return api_key
            last_error = "main.apiKey is empty"
        except OSError as exc:
            last_error = str(exc)
        except ValueError as exc:
            last_error = "unparseable JSON: %s" % exc
        time.sleep(2)
    log("WARNING: timed out waiting for Seerr API key in %s: %s"
        % (settings_path, last_error))
    return ""


def _seerr_servarr_base(name: str, port: int, api_key: str) -> Dict[str, Any]:
    return {
        "name": name,
        "hostname": "localhost",
        "port": port,
        "apiKey": api_key,
        "useSsl": False,
        "baseUrl": "",
        "is4k": False,
        "isDefault": True,
        "syncEnabled": True,
        "preventSearch": False,
    }


def build_seerr_sonarr(sonarr_api_key: str, profile_id: int,
                       profile_name: str, root_folder: str) -> Dict[str, Any]:
    payload = _seerr_servarr_base(SEERR_SONARR_NAME, SONARR_PORT,
                                  sonarr_api_key)
    payload.update({
        "activeProfileId": profile_id,
        "activeProfileName": profile_name,
        "activeDirectory": root_folder,
        "enableSeasonFolders": True,
    })
    return payload


def build_seerr_radarr(radarr_api_key: str, profile_id: int,
                       profile_name: str, root_folder: str) -> Dict[str, Any]:
    payload = _seerr_servarr_base(SEERR_RADARR_NAME, RADARR_PORT,
                                  radarr_api_key)
    payload.update({
        "activeProfileId": profile_id,
        "activeProfileName": profile_name,
        "activeDirectory": root_folder,
        "minimumAvailability": "released",
    })
    return payload


def build_seerr_jellyfin(host: str, port: int,
                         jellyfin_api_key: str) -> Dict[str, Any]:
    return {
        "ip": host,
        "port": port,
        "useSsl": False,
        "urlBase": "",
        "apiKey": jellyfin_api_key,
    }


def seerr_service_named(name: str) -> Callable[[Dict[str, Any]], bool]:
    def match(item: Dict[str, Any]) -> bool:
        return item.get("name") == name
    return match


def plan_seerr_service(existing: List[Dict[str, Any]],
                       desired: Dict[str, Any]) -> str:
    item = matching_item(seerr_service_named(desired["name"]), existing)
    if item is None:
        return "created"
    for key, value in desired.items():
        if key == "id":
            continue
        if not _secret_aware_equal(item.get(key), value):
            return "updated"
    return "unchanged"


def upsert_seerr_service(list_path: str, api_key: str,
                         desired: Dict[str, Any],
                         dry_run: bool) -> str:
    existing = seerr_request("GET", list_path, api_key) or []
    action = plan_seerr_service(existing, desired)
    if dry_run:
        return "would_configure" if action != "unchanged" else "unchanged"
    if action == "created":
        seerr_request("POST", list_path, api_key, desired)
        log("Seerr %s: created" % desired["name"])
        return "created"
    if action == "unchanged":
        log("Seerr %s already wired" % desired["name"])
        return "unchanged"
    target = matching_item(seerr_service_named(desired["name"]), existing)
    if "id" not in target:
        fail("Seerr %s entry has no id; remove the duplicate in Seerr"
             " Settings -> Services and re-run" % desired["name"])
    body = dict(target)
    body.update(desired)
    body["id"] = target["id"]
    seerr_request("PUT", "%s/%d" % (list_path, target["id"]), api_key, body)
    log("Seerr %s: updated" % desired["name"])
    return "updated"


def ensure_seerr_sonarr(seerr_api_key: str, sonarr_api_key: str,
                        profile_id: int, profile_name: str,
                        root_folder: str, dry_run: bool) -> str:
    return upsert_seerr_service(
        SEERR_SONARR_PATH, seerr_api_key,
        build_seerr_sonarr(sonarr_api_key, profile_id, profile_name,
                           root_folder), dry_run)


def ensure_seerr_radarr(seerr_api_key: str, radarr_api_key: str,
                        profile_id: int, profile_name: str,
                        root_folder: str, dry_run: bool) -> str:
    return upsert_seerr_service(
        SEERR_RADARR_PATH, seerr_api_key,
        build_seerr_radarr(radarr_api_key, profile_id, profile_name,
                           root_folder), dry_run)


def plan_seerr_jellyfin(current: Dict[str, Any], host: str, port: int,
                        jellyfin_api_key: str) -> str:
    desired = build_seerr_jellyfin(host, port, jellyfin_api_key)
    for key, value in desired.items():
        if not _secret_aware_equal(current.get(key), value):
            return "updated"
    return "unchanged"


def ensure_seerr_jellyfin(seerr_api_key: str, host: str, port: int,
                          jellyfin_api_key: str, dry_run: bool) -> str:
    if not jellyfin_api_key:
        log("Seerr Jellyfin: no API key provided — Sonarr/Radarr are still"
            " wired; create a Jellyfin API key (Dashboard -> API Keys) and"
            " re-run with --jellyfin-api-key to link the media server")
        return "skipped_no_key"
    current = seerr_request("GET", SEERR_JELLYFIN_PATH, seerr_api_key) or {}
    action = plan_seerr_jellyfin(current, host, port, jellyfin_api_key)
    if action == "unchanged":
        log("Seerr Jellyfin already linked at %s:%d" % (host, port))
        return "unchanged"
    if dry_run:
        log("[dry-run] would link Seerr to Jellyfin at %s:%d" % (host, port))
        return "would_configure"
    seerr_request("POST", SEERR_JELLYFIN_PATH, seerr_api_key,
                  build_seerr_jellyfin(host, port, jellyfin_api_key))
    log("Seerr linked to Jellyfin at %s:%d" % (host, port))
    return "configured"


def pick_servarr_profile(base: str, api_key: str, kind: str) -> Tuple[int, str]:
    profiles = servarr_request("GET", base, api_key,
                               "/api/v3/qualityprofile") or []
    if not profiles:
        fail("no quality profiles found in %s; create one before wiring Seerr"
             % kind)
    first = profiles[0]
    return first.get("id", 1), first.get("name", "")


def pick_servarr_root(base: str, api_key: str, fallback: str,
                      kind: str) -> str:
    folders = servarr_request("GET", base, api_key, "/api/v3/rootfolder") or []
    for folder in folders:
        if folder.get("accessible", True):
            return folder.get("path") or fallback
    log("no accessible root folder in %s — using %s" % (kind, fallback))
    return fallback


def ensure_seerr(sonarr_key: str, radarr_key: str, jellyfin_host: str,
                 jellyfin_port: int, jellyfin_api_key: str,
                 dry_run: bool,
                 settings_path: str = SEERR_SETTINGS_FILE,
                 key_timeout: int = 60) -> str:
    if not os.path.exists(settings_path):
        log("Seerr is not installed in this container yet — run install.sh"
            " (or update.sh) first, or pass --skip-seerr")
        return "unavailable"
    seerr_api_key = read_seerr_api_key(settings_path, key_timeout)
    if not seerr_api_key:
        log("Seerr has no API key yet — finish the setup wizard at %s,"
            " then re-run to wire Sonarr/Radarr/Jellyfin" % SEERR_BASE)
        return "needs_setup"
    try:
        public = seerr_request("GET", SEERR_PUBLIC_PATH, seerr_api_key) or {}
    except ApiError:
        log("Seerr is not answering on %s — skipping its setup"
            % SEERR_BASE)
        return "unavailable"
    if not public.get("initialized", False):
        log("Seerr setup wizard is not finished — open %s, sign in with"
            " Jellyfin, then re-run to wire Sonarr/Radarr/Jellyfin"
            % SEERR_BASE)
        return "needs_setup"

    sonarr_profile_id, sonarr_profile_name = pick_servarr_profile(
        SONARR_BASE, sonarr_key, "Sonarr")
    sonarr_root = pick_servarr_root(SONARR_BASE, sonarr_key, SONARR_ROOT,
                                    "Sonarr")
    log("Seerr Sonarr: profile '%s' (%d), root '%s'"
        % (sonarr_profile_name, sonarr_profile_id, sonarr_root))
    radarr_profile_id, radarr_profile_name = pick_servarr_profile(
        RADARR_BASE, radarr_key, "Radarr")
    radarr_root = pick_servarr_root(RADARR_BASE, radarr_key, RADARR_ROOT,
                                    "Radarr")
    log("Seerr Radarr: profile '%s' (%d), root '%s'"
        % (radarr_profile_name, radarr_profile_id, radarr_root))

    actions = [
        ensure_seerr_sonarr(seerr_api_key, sonarr_key, sonarr_profile_id,
                            sonarr_profile_name, sonarr_root, dry_run),
        ensure_seerr_radarr(seerr_api_key, radarr_key, radarr_profile_id,
                            radarr_profile_name, radarr_root, dry_run),
        ensure_seerr_jellyfin(seerr_api_key, jellyfin_host, jellyfin_port,
                              jellyfin_api_key, dry_run),
    ]
    if any(action in ("created", "updated", "configured") for action in actions):
        return "configured"
    if any(action == "would_configure" for action in actions):
        return "would_configure"
    if "skipped_no_key" in actions:
        return "no_jellyfin_key"
    return "unchanged"


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


# --- Per-app login (Forms auth, always required, even on LAN) ---

SONARR_HOST_PATH = "/api/v3/config/host"
RADARR_HOST_PATH = "/api/v3/config/host"
PROWLARR_HOST_PATH = "/api/v1/config/host"

SERVARR_AUTH_REQUIRED = "enabled"


def parse_auth_file(path: str) -> Dict[str, str]:
    creds: Dict[str, str] = {}
    with open(path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.rstrip("\r\n")
            flag = line.strip()
            if not flag or flag.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            creds[key.strip()] = value
    return creds


def build_servarr_host_config(current: Dict[str, Any], method: str,
                              username: str, password: str) -> Dict[str, Any]:
    body = dict(current)
    body["authenticationMethod"] = method
    body["authenticationRequired"] = SERVARR_AUTH_REQUIRED
    body["username"] = username
    body["password"] = password
    if "passwordConfirmation" in body:
        body["passwordConfirmation"] = password
    return body


def plan_servarr_auth(current: Dict[str, Any], method: str,
                      username: str, password: str) -> str:
    desired = build_servarr_host_config(current, method, username, password)
    for key in ("authenticationMethod", "authenticationRequired", "username"):
        if current.get(key) != desired[key]:
            return "updated"
    if not _secret_aware_equal(current.get("password"), password):
        return "updated"
    if ("passwordConfirmation" in current
            and not _secret_aware_equal(current.get("passwordConfirmation"), password)):
        return "updated"
    return "unchanged"


def build_servarr_login_request(base: str, username: str,
                                password: str) -> urllib.request.Request:
    data = urllib.parse.urlencode(
        {"username": username, "password": password}).encode()
    req = urllib.request.Request(base + "/login", data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    req.add_header("Origin", base)
    req.add_header("Referer", base + "/login")
    return req


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _set_cookie_names(headers: Any) -> List[str]:
    try:
        raw = headers.get_all("Set-Cookie") or []
    except AttributeError:
        single = headers.get("Set-Cookie")
        raw = [single] if single else []
    names = []
    for entry in raw:
        name, _, _ = entry.partition("=")
        name = name.strip()
        if name:
            names.append(name)
    return names


def probe_servarr_login(base: str, status_path: str, username: str,
                        password: str, method: str = "forms") -> Optional[bool]:
    """Tri-state login probe: True works, False rejected, None transient.

    Forms logins are judged by the login POST itself: good credentials
    answer 302 to "/" and set the session cookie (*Auth), bad ones bounce
    back to /login (loginFailed) with no cookie. The JSON API is deliberately
    not used: Servarr API routes only accept the API key, never the session
    cookie, so a cookie round-trip there can never succeed.
    """
    if method == "basic":
        token = base64.b64encode(
            ("%s:%s" % (username, password)).encode()).decode()
        req = urllib.request.Request(base + status_path, method="GET")
        req.add_header("Authorization", "Basic " + token)
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return True if resp.status == 200 else None
        except urllib.error.HTTPError as exc:
            return False if exc.code in (401, 403) else None
        except (OSError, TimeoutError, ValueError):
            return None
    opener = urllib.request.build_opener(_NoRedirect())
    try:
        with opener.open(build_servarr_login_request(base, username, password),
                         timeout=15) as resp:
            resp.read()
            return None
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            return False
        if exc.code not in (301, 302, 303, 307, 308):
            return None
        try:
            headers = exc.headers or {}
            location = headers.get("Location", "") or ""
            names = _set_cookie_names(headers)
        except (AttributeError, ValueError):
            return None
        if "login" in location:
            return False
        if any(name.endswith("Auth") for name in names):
            return True
        return None
    except (OSError, TimeoutError, ValueError):
        return None


def check_servarr_login(base: str, status_path: str, username: str,
                        password: str, method: str = "forms",
                        timeout: int = 30) -> None:
    """Verify the app login, failing fast on rejection.

    The probe judges the login POST deterministically (redirect target +
    session cookie), so False means wrong credentials and aborts
    immediately; only transient results (service unreachable, timeouts)
    are retried until the timeout expires.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = probe_servarr_login(base, status_path, username, password, method)
        if result is True:
            log("login check ok for %s" % base)
            return
        if result is False:
            fail("login rejected for %s — check username/password" % base)
        time.sleep(2)
    fail("login check failed for %s after %ds" % (base, timeout))


def ensure_servarr_auth(app: str, base: str, api_key: str, host_path: str,
                        method: str, username: str, password: str,
                        dry_run: bool) -> str:
    current = servarr_request("GET", base, api_key, host_path) or {}
    if "id" not in current:
        fail("%s host config has no id; check its API endpoint" % app)
    status_path = host_path.replace("config/host", "system/status")
    action = plan_servarr_auth(current, method, username, password)
    if action == "unchanged" and not dry_run:
        if probe_servarr_login(base, status_path, username, password, method):
            log("%s login already configured" % app)
            return "unchanged"
        log("%s login probe failed — updating credentials" % app)
        action = "updated"
    if dry_run:
        log("[dry-run] would %s %s login (user %s)" % (
            "update" if action == "updated" else "keep", app, username))
        return "would_update" if action == "updated" else "unchanged"
    if action == "updated":
        body = build_servarr_host_config(current, method, username, password)
        servarr_request("PUT", base, api_key,
                        "%s/%d" % (host_path, current["id"]), body)
        log("%s login updated (user %s)" % (app, username))
    check_servarr_login(base, status_path, username, password, method)
    return action


def bazarr_auth_form(auth_type: str, username: str,
                     password: str) -> Dict[str, str]:
    return {"settings-auth-type": auth_type,
            "settings-auth-username": username,
            "settings-auth-password": password}


def plan_bazarr_auth(settings: Dict[str, Any], auth_type: str,
                     username: str, password: str) -> str:
    auth = settings.get("auth", {}) or {}
    if auth.get("type") != auth_type or auth.get("username") != username:
        return "updated"
    if not _secret_aware_equal(auth.get("password"), password):
        return "updated"
    return "unchanged"


def probe_bazarr_login(api_key: str, username: str,
                       password: str) -> Optional[bool]:
    """Tri-state Bazarr credential probe: True works, False rejected, None transient."""
    try:
        bazarr_request("POST", "/api/system/account", api_key,
                       {"action": "login", "username": username,
                        "password": password}, form=True)
    except ApiError as exc:
        return False if exc.status == 403 else None
    return True


def wait_for_bazarr_state(api_key: str, ready: Callable[[Dict[str, Any]], bool],
                          what: str, timeout: int = 30) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            settings = bazarr_request("GET", "/api/system/settings", api_key) or {}
            if ready(settings):
                return True
        except ApiError as exc:
            if exc.status in (401, 403, 404):
                fail("Bazarr %s verification failed with HTTP %s; check its API key and endpoint"
                     % (what, exc.status))
        time.sleep(2)
    return False


def ensure_bazarr_auth(api_key: str, username: str, password: str,
                       auth_type: str, dry_run: bool) -> str:
    settings = bazarr_request("GET", "/api/system/settings", api_key) or {}
    action = plan_bazarr_auth(settings, auth_type, username, password)
    if action == "unchanged":
        if probe_bazarr_login(api_key, username, password) is not False:
            log("Bazarr login already configured")
            return "unchanged"
        log("Bazarr login probe failed — updating credentials")
        action = "updated"
    if dry_run:
        log("[dry-run] would update Bazarr login (user %s)" % username)
        return "would_update"
    try:
        bazarr_request("POST", "/api/system/settings", api_key,
                       bazarr_auth_form(auth_type, username, password), form=True)
    except ApiError as exc:
        if exc.status in (401, 403):
            fail("Bazarr auth update rejected with HTTP %s; check its API key" % exc.status)
        fail("Bazarr auth update failed (%s); re-run once the Bazarr API is reachable" % exc)
    if wait_for_bazarr_state(
            api_key,
            lambda state: plan_bazarr_auth(state, auth_type, username, password) == "unchanged",
            "auth"):
        if probe_bazarr_login(api_key, username, password) is not True:
            fail("Bazarr login verification failed for user %s — check username/password" % username)
        log("Bazarr login updated via API (user %s)" % username)
        return "updated"
    fail("Bazarr auth update did not persist; re-run once the Bazarr API is reachable")


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


def _bazarr_form_value(value: Any) -> str:
    if value is True:
        return "true"
    if value is False:
        return "false"
    return str(value)


def bazarr_settings_form(sonarr_key: str, radarr_key: str) -> Dict[str, str]:
    desired = desired_bazarr_settings(sonarr_key, radarr_key)
    return {"settings-%s-%s" % (section, key): _bazarr_form_value(value)
            for section, values in desired.items()
            for key, value in values.items()}


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
            and all(general.get(key) == value for key, value in desired["general"].items()))


def link_bazarr_via_api(api_key: str, sonarr_key: str, radarr_key: str) -> bool:
    try:
        bazarr_request("POST", "/api/system/settings", api_key,
                       bazarr_settings_form(sonarr_key, radarr_key), form=True)
    except ApiError as exc:
        if exc.status in (401, 403):
            fail("Bazarr settings update rejected with HTTP %s; check its API key" % exc.status)
        fail("Bazarr settings update failed (%s); re-run once the Bazarr API is reachable" % exc)
    return wait_for_bazarr_state(
        api_key,
        lambda settings: is_bazarr_linked(settings, sonarr_key, radarr_key),
        "link")


def wait_for_bazarr_settings(api_key: str, timeout: int = 30) -> Dict[str, Any]:
    deadline = time.time() + timeout
    last: Optional[Exception] = None
    while time.time() < deadline:
        try:
            return bazarr_request("GET", "/api/system/settings", api_key) or {}
        except ApiError as exc:
            if exc.status in (401, 403, 404):
                fail("Bazarr settings request failed with HTTP %s; check its API key and endpoint"
                     % exc.status)
            last = exc
            time.sleep(2)
    fail("Bazarr API was not ready after %ds: %s" % (timeout, last))


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
    fail("Bazarr linking did not persist; re-run once the Bazarr API is reachable")


def build_summary(versions: Dict[str, str], apps: Dict[str, int],
                  clients: Dict[str, int], folders: Dict[str, int],
                  bazarr_action: str, dry_run: bool,
                  auth: Optional[Dict[str, str]] = None,
                  flaresolverr_action: str = "skipped",
                  qbit_action: str = "skipped",
                  seerr_action: str = "skipped") -> Dict[str, Any]:
    return {
        "dry_run": dry_run,
        "versions": versions,
        "prowlarr_apps": apps,
        "download_clients": clients,
        "root_folders": folders,
        "bazarr": bazarr_action,
        "auth": auth or {},
        "flaresolverr": flaresolverr_action,
        "qbit": qbit_action,
        "seerr": seerr_action,
    }


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
        raise argparse.ArgumentTypeError("host must be an IP address") from exc
    return host


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Wire Starr integrations (runs inside starr LXC)")
    parser.add_argument("--qbit-host", type=valid_host, required=False, default=None)
    parser.add_argument("--qbit-user", default="admin")
    parser.add_argument("--qbit-pass-stdin", action="store_true")
    parser.add_argument("--qbit-port", type=valid_port, default=8090)
    parser.add_argument("--data-root", default=DATA_ROOT)
    parser.add_argument("--skip-auth", action="store_true")
    parser.add_argument("--auth-file", default=None)
    parser.add_argument("--auth-method", default="forms",
                        choices=["forms", "basic"])
    parser.add_argument("--skip-bazarr", action="store_true")
    parser.add_argument("--skip-flaresolverr", action="store_true")
    parser.add_argument("--skip-qbit", action="store_true")
    parser.add_argument("--skip-seerr", action="store_true")
    parser.add_argument("--jellyfin-host", type=valid_host, required=False,
                        default=None)
    parser.add_argument("--jellyfin-port", type=valid_port,
                        default=JELLYFIN_DEFAULT_PORT)
    parser.add_argument("--seerr-env", default=None)
    parser.add_argument("--seerr-settings", default=SEERR_SETTINGS_FILE)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    args.qbit_pass = ""
    if not args.skip_qbit:
        if not args.qbit_host:
            fail("--qbit-host is required unless --skip-qbit is passed")
        if not args.qbit_pass_stdin:
            fail("--qbit-pass-stdin is required unless --skip-qbit is passed")
        args.qbit_pass = sys.stdin.readline().rstrip("\r\n")
        if not args.qbit_pass:
            fail("qBittorrent password was not provided on stdin")

    prowlarr_key = read_api_key(args.data_root, "prowlarr")
    sonarr_key = read_api_key(args.data_root, "sonarr")
    radarr_key = read_api_key(args.data_root, "radarr")

    if not args.skip_qbit and not args.dry_run:
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
    qbit_action = "skipped"
    if not args.skip_qbit:
        ensure_download_client("sonarr", SONARR_BASE, sonarr_key, args.qbit_host,
                               args.qbit_port, args.qbit_user, args.qbit_pass,
                               args.dry_run, clients)
        ensure_download_client("radarr", RADARR_BASE, radarr_key, args.qbit_host,
                               args.qbit_port, args.qbit_user, args.qbit_pass,
                               args.dry_run, clients)
        if not clients["created"] and not clients["updated"]:
            qbit_action = "unchanged"
        elif args.dry_run:
            qbit_action = "would_configure"
        else:
            qbit_action = "configured"
    ensure_prowlarr_app("sonarr", prowlarr_key, sonarr_key, args.dry_run, apps)
    ensure_prowlarr_app("radarr", prowlarr_key, radarr_key, args.dry_run, apps)

    bazarr_config = os.path.join(args.data_root, "bazarr", "config", "config.yaml")
    bazarr_action = "skipped"
    if not args.skip_bazarr:
        bazarr_action = ensure_bazarr(sonarr_key, radarr_key, args.dry_run, bazarr_config)

    flaresolverr_action = "skipped"
    if not args.skip_flaresolverr:
        flaresolverr_action = ensure_flaresolverr(prowlarr_key, args.dry_run)

    seerr_action = "skipped"
    if not args.skip_seerr:
        jellyfin_api_key = ""
        if args.seerr_env:
            jellyfin_api_key = parse_auth_file(args.seerr_env).get(
                "jellyfin_api_key", "")
        seerr_action = ensure_seerr(sonarr_key, radarr_key,
                                    args.jellyfin_host or LOCALHOST_IP,
                                    args.jellyfin_port, jellyfin_api_key,
                                    args.dry_run, args.seerr_settings)

    auth: Dict[str, str] = {}
    if args.skip_auth:
        auth = {app: "skipped" for app in ("prowlarr", "sonarr", "radarr", "bazarr")}
    else:
        if not args.auth_file:
            fail("--auth-file is required unless --skip-auth is passed")
        creds = parse_auth_file(args.auth_file)
        missing = [k for k in ("prowlarr_user", "prowlarr_pass", "sonarr_user",
                               "sonarr_pass", "radarr_user", "radarr_pass",
                               "bazarr_user", "bazarr_pass") if not creds.get(k)]
        if missing:
            fail("auth file is missing: %s" % ", ".join(sorted(missing)))
        bazarr_type = {"forms": "form", "basic": "basic"}[args.auth_method]
        auth["prowlarr"] = ensure_servarr_auth(
            "prowlarr", PROWLARR_BASE, prowlarr_key, PROWLARR_HOST_PATH,
            args.auth_method, creds["prowlarr_user"], creds["prowlarr_pass"],
            args.dry_run)
        auth["sonarr"] = ensure_servarr_auth(
            "sonarr", SONARR_BASE, sonarr_key, SONARR_HOST_PATH,
            args.auth_method, creds["sonarr_user"], creds["sonarr_pass"],
            args.dry_run)
        auth["radarr"] = ensure_servarr_auth(
            "radarr", RADARR_BASE, radarr_key, RADARR_HOST_PATH,
            args.auth_method, creds["radarr_user"], creds["radarr_pass"],
            args.dry_run)
        bazarr_api_key = load_bazarr_api_key(bazarr_config)
        auth["bazarr"] = ensure_bazarr_auth(
            bazarr_api_key, creds["bazarr_user"], creds["bazarr_pass"],
            bazarr_type, args.dry_run)

    print(json.dumps(build_summary(versions, apps, clients, folders, bazarr_action, args.dry_run, auth, flaresolverr_action, qbit_action, seerr_action)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ApiError as exc:
        fail("API request failed: %s" % exc)
    except (OSError, ValueError) as exc:
        fail("configuration failed: %s" % exc)
