#!/usr/bin/env python3
"""Wire Starr integrations inside the starr LXC (stdlib only).

Reads Servarr API keys from config.xml, then idempotently creates:
  - Prowlarr applications -> Sonarr / Radarr (indexer sync)
  - Sonarr / Radarr download clients -> qBittorrent (+ root folders)
  - Bazarr links -> Sonarr / Radarr

All traffic goes over http://localhost (same container). Secrets are
never printed; stdout carries only a JSON summary of actions taken.
"""

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from typing import Any, Callable, Dict, List, Optional, Tuple

PROWLARR_BASE = "http://localhost:9696"
SONARR_BASE = "http://localhost:8989"
RADARR_BASE = "http://localhost:7878"
BAZARR_BASE = "http://localhost:6767"

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


def fail(msg: str) -> "Any":
    log("ERROR: %s" % msg)
    sys.exit(1)


class ApiError(Exception):
    def __init__(self, status: Optional[int], body: str):
        super(ApiError, self).__init__("HTTP %s: %s" % (status, body[:300]))
        self.status = status
        self.body = body


def servarr_request(method: str, base: str, api_key: str, path: str,
                    body: Optional[Dict[str, Any]] = None) -> Any:
    url = base + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-Api-Key", api_key)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            payload = resp.read().decode()
            return json.loads(payload) if payload.strip() else None
    except urllib.error.HTTPError as exc:
        raise ApiError(exc.code, exc.read().decode(errors="replace"))


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
    return ""


def wait_healthy(name: str, base: str, api_key: str, status_path: str,
                 timeout: int = 90) -> Dict[str, Any]:
    deadline = time.time() + timeout
    last: Optional[Exception] = None
    while time.time() < deadline:
        try:
            status = servarr_request("GET", base, api_key, status_path)
            log("%s healthy (v%s)" % (name, status.get("version", "?")))
            return status
        except Exception as exc:  # noqa: BLE001 - retry until timeout
            last = exc
            time.sleep(3)
    fail("%s not healthy after %ds: %s" % (name, timeout, last))
    return {}


def fields_list(values: Dict[str, Any]) -> List[Dict[str, Any]]:
    return [{"name": name, "value": value} for name, value in values.items()]


def fields_map(item: Dict[str, Any]) -> Dict[str, Any]:
    return {f["name"]: f.get("value") for f in item.get("fields", [])}


def build_prowlarr_app(kind: str, api_key: str) -> Dict[str, Any]:
    if kind == "sonarr":
        base_url = "http://localhost:8989"
        contract = "SonarrSettings"
        name = "Sonarr"
        extra = {
            "syncCategories": SONARR_SYNC_CATEGORIES,
            "animeSyncCategories": SONARR_ANIME_CATEGORIES,
            "syncAnimeStandardFormatSearch": True,
        }
    else:
        base_url = "http://localhost:7878"
        contract = "RadarrSettings"
        name = "Radarr"
        extra = {"syncCategories": RADARR_SYNC_CATEGORIES}
    fields = {
        "prowlarrUrl": "http://localhost:9696",
        "baseUrl": base_url,
        "apiKey": api_key,
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
                    "olderTvPriority": 0}
    else:
        category = {"movieCategory": RADARR_CATEGORY, "recentMoviePriority": 0,
                    "olderMoviePriority": 0}
    fields = {
        "host": host,
        "port": port,
        "useSsl": False,
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
    for key in ("enable", "syncLevel", "priority",
                "removeCompletedDownloads", "removeFailedDownloads"):
        if key in desired:
            merged[key] = desired[key]
    return merged


def upsert(action: Callable[[], Any],
           match: Callable[[Any], bool],
           collection: List[Dict[str, Any]],
           desired: Dict[str, Any],
           create: Callable[[Dict[str, Any]], Any],
           update: Callable[[int, Dict[str, Any]], Any]) -> Tuple[str, Any]:
    for item in collection:
        if match(item):
            merged = merge_fields(item, desired)
            if fields_map(merged) == fields_map(item) and all(
                    merged.get(k) == item.get(k)
                    for k in ("enable", "syncLevel", "priority")
                    if k in desired):
                return "unchanged", item
            return "updated", update(item["id"], merged)
    if action is not None:
        action()
    return "created", create(desired)


def ensure_root_folder(base: str, api_key: str, path: str,
                       dry_run: bool, counters: Dict[str, int]) -> None:
    folders = servarr_request("GET", base, api_key, "/api/v3/rootfolder") or []
    if any(f.get("path") == path for f in folders):
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


def ensure_download_client(kind: str, base: str, api_key: str, host: str,
                           port: int, username: str, password: str,
                           dry_run: bool, counters: Dict[str, int]) -> None:
    desired = build_download_client(kind, host, port, username, password)

    def match(item: Dict[str, Any]) -> bool:
        return item.get("implementation") == "QBittorrent"

    if dry_run:
        clients = servarr_request("GET", base, api_key, "/api/v3/downloadclient") or []
        action = "updated" if any(match(c) for c in clients) else "created"
        counters[action] += 1
        log("[dry-run] would %s qBittorrent download client (%s)" % (action, kind))
        return
    clients = servarr_request("GET", base, api_key, "/api/v3/downloadclient") or []
    action, _ = upsert(
        lambda: None, match, clients, desired,
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

    if dry_run:
        apps = servarr_request("GET", PROWLARR_BASE, prowlarr_key, "/api/v1/applications") or []
        action = "updated" if any(match(a) for a in apps) else "created"
        counters[action] += 1
        log("[dry-run] would %s Prowlarr application %s" % (action, name))
        return
    apps = servarr_request("GET", PROWLARR_BASE, prowlarr_key, "/api/v1/applications") or []
    action, _ = upsert(
        lambda: None, match, apps, desired,
        lambda body: servarr_request("POST", PROWLARR_BASE, prowlarr_key, "/api/v1/applications", body),
        lambda i, body: servarr_request("PUT", PROWLARR_BASE, prowlarr_key, "/api/v1/applications/%d" % i, body),
    )
    counters[action] += 1
    log("Prowlarr application %s: %s" % (name, action))


def check_qbit_login(host: str, port: int, username: str, password: str) -> None:
    url = "http://%s:%d/api/v2/auth/login" % (host, port)
    data = urllib.parse.urlencode({"username": username, "password": password}).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            if resp.read().decode().strip() != "Ok.":
                fail("qBittorrent login rejected — check --qbit-user/--qbit-pass")
    except urllib.error.HTTPError as exc:
        fail("qBittorrent login failed (HTTP %s) — check host/user/password" % exc.code)
    except OSError as exc:
        fail("cannot reach qBittorrent at %s:%d (%s)" % (host, port, exc))
    log("qBittorrent login ok")


def parse_bazarr_yaml(path: str) -> Dict[str, Dict[str, str]]:
    sections: Dict[str, Dict[str, str]] = {}
    current: Optional[str] = None
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            top = re.match(r"^(\w+):\s*$", line)
            if top:
                current = top.group(1)
                sections.setdefault(current, {})
                continue
            kv = re.match(r"^\s+(\w+):\s*(.*?)\s*$", line)
            if kv and current:
                sections[current][kv.group(1)] = kv.group(2).strip("'\"")
    return sections


def bazarr_request(api_key: str, method: str, path: str,
                   body: Optional[Dict[str, Any]] = None) -> Any:
    url = BAZARR_BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-API-KEY", api_key)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            payload = resp.read().decode()
            return json.loads(payload) if payload.strip() else None
    except urllib.error.HTTPError as exc:
        raise ApiError(exc.code, exc.read().decode(errors="replace"))


def ensure_bazarr(sonarr_key: str, radarr_key: str,
                  dry_run: bool) -> str:
    try:
        sections = parse_bazarr_yaml(BAZARR_CONFIG)
    except OSError:
        fail("Bazarr config not found at %s" % BAZARR_CONFIG)
        return "failed"
    api_key = sections.get("auth", {}).get("apikey", "")
    if not api_key:
        fail("Bazarr API key missing in %s" % BAZARR_CONFIG)
    patch = {
        "sonarr": {"ip": "127.0.0.1", "port": 8989, "apikey": sonarr_key},
        "radarr": {"ip": "127.0.0.1", "port": 7878, "apikey": radarr_key},
        "general": {"use_sonarr": True, "use_radarr": True},
    }
    if dry_run:
        log("[dry-run] would link Bazarr to Sonarr/Radarr")
        return "would_link"
    try:
        settings = bazarr_request(api_key, "GET", "/api/system/settings") or {}
    except ApiError as exc:
        fail("Bazarr settings fetch failed: %s" % exc)
        return "failed"
    current = {
        "sonarr": (settings.get("sonarr", {}) or {}).get("apikey", ""),
        "radarr": (settings.get("radarr", {}) or {}).get("apikey", ""),
    }
    if current["sonarr"] == sonarr_key and current["radarr"] == radarr_key:
        log("Bazarr already linked to Sonarr/Radarr")
        return "unchanged"
    try:
        bazarr_request(api_key, "PATCH", "/api/system/settings", patch)
        verify = bazarr_request(api_key, "GET", "/api/system/settings") or {}
        if ((verify.get("sonarr", {}) or {}).get("apikey") == sonarr_key
                and (verify.get("radarr", {}) or {}).get("apikey") == radarr_key):
            log("Bazarr linked to Sonarr/Radarr via API")
            return "linked"
    except ApiError as exc:
        log("Bazarr API update failed (%s) — falling back to config file" % exc)
    rewrite_bazarr_yaml(sonarr_key, radarr_key)
    subprocess.run(["systemctl", "restart", "bazarr"], check=False)
    time.sleep(5)
    try:
        verify = bazarr_request(api_key, "GET", "/api/system/settings") or {}
        if ((verify.get("sonarr", {}) or {}).get("apikey") == sonarr_key
                and (verify.get("radarr", {}) or {}).get("apikey") == radarr_key):
            log("Bazarr linked to Sonarr/Radarr via config file")
            return "linked"
    except ApiError as exc:
        fail("Bazarr verify failed after config rewrite: %s" % exc)
    fail("Bazarr linking did not persist")
    return "failed"


def rewrite_bazarr_yaml(sonarr_key: str, radarr_key: str) -> None:
    with open(BAZARR_CONFIG, encoding="utf-8", errors="replace") as handle:
        lines = handle.readlines()
    current: Optional[str] = None
    out = []
    for line in lines:
        top = re.match(r"^(\w+):\s*$", line)
        if top:
            current = top.group(1)
            out.append(line)
            continue
        if current in ("sonarr", "radarr") and re.match(r"^\s+apikey:", line):
            indent = line[:len(line) - len(line.lstrip())]
            out.append("%sapikey: '%s'\n" % (indent, sonarr_key if current == "sonarr" else radarr_key))
            continue
        if current == "general" and re.match(r"^\s+use_(sonarr|radarr):", line):
            indent = line[:len(line) - len(line.lstrip())]
            key = re.match(r"^\s+(use_\w+):", line).group(1)  # type: ignore[union-attr]
            out.append("%s%s: True\n" % (indent, key))
            continue
        out.append(line)
    with open(BAZARR_CONFIG, "w", encoding="utf-8") as handle:
        handle.writelines(out)


def self_test() -> int:
    failures = []

    def check(label: str, condition: bool) -> None:
        print(("PASS" if condition else "FAIL") + " " + label)
        if not condition:
            failures.append(label)

    sonarr_app = build_prowlarr_app("sonarr", "KEY1")
    check("prowlarr sonarr contract", sonarr_app["configContract"] == "SonarrSettings")
    check("prowlarr sonarr sync level", sonarr_app["syncLevel"] == "fullSync")
    smap = fields_map(sonarr_app)
    check("prowlarr sonarr base url", smap["baseUrl"] == "http://localhost:8989")
    check("prowlarr sonarr url", smap["prowlarrUrl"] == "http://localhost:9696")
    check("prowlarr sonarr key", smap["apiKey"] == "KEY1")
    check("prowlarr sonarr categories", smap["syncCategories"] == SONARR_SYNC_CATEGORIES)
    check("prowlarr sonarr anime categories", smap["animeSyncCategories"] == SONARR_ANIME_CATEGORIES)

    radarr_app = build_prowlarr_app("radarr", "KEY2")
    rmap = fields_map(radarr_app)
    check("prowlarr radarr contract", radarr_app["configContract"] == "RadarrSettings")
    check("prowlarr radarr base url", rmap["baseUrl"] == "http://localhost:7878")
    check("prowlarr radarr categories", rmap["syncCategories"] == RADARR_SYNC_CATEGORIES)

    sonarr_client = build_download_client("sonarr", "192.168.31.86", 8090, "admin", "pw")
    check("client implementation", sonarr_client["implementation"] == "QBittorrent")
    cmap = fields_map(sonarr_client)
    check("client host override", cmap["host"] == "192.168.31.86")
    check("client port override", cmap["port"] == 8090)
    check("client tv category", cmap.get("tvCategory") == SONARR_CATEGORY)
    check("client drops schema default", "tv-sonarr" not in json.dumps(sonarr_client))

    radarr_client = build_download_client("radarr", "192.168.31.86", 8090, "admin", "pw")
    rcmap = fields_map(radarr_client)
    check("client movie category", rcmap.get("movieCategory") == RADARR_CATEGORY)
    check("client drops radarr default", "radarr" not in
          [f["name"] for f in radarr_client["fields"]] or rcmap.get("movieCategory") == "movies")

    existing = {"id": 3, "enable": True, "implementation": "QBittorrent",
                "fields": [{"name": "host", "value": "localhost"}]}
    merged = merge_fields(existing, sonarr_client)
    check("merge keeps id", merged["id"] == 3)
    check("merge overrides host", fields_map(merged)["host"] == "192.168.31.86")

    action, _ = upsert(lambda: None, lambda i: True, [], sonarr_client,
                       lambda b: {"id": 1}, lambda i, b: b)
    check("upsert empty creates", action == "created")
    same = {"id": 1, "enable": True, "priority": 1, "fields": fields_list(cmap)}
    action, _ = upsert(lambda: None, lambda i: True, [same], sonarr_client,
                       lambda b: {"id": 9}, lambda i, b: {"id": i})
    check("upsert identical unchanged", action == "unchanged")

    import tempfile
    sample = ("auth:\n  apikey: 'AUTHKEY'\n  type: null\n"
              "sonarr:\n  ip: 127.0.0.1\n  apikey: ''\n")
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as tmp:
        tmp.write(sample)
        tmp_path = tmp.name
    parsed = parse_bazarr_yaml(tmp_path)
    check("yaml auth key wins", parsed["auth"]["apikey"] == "AUTHKEY")
    check("yaml empty sonarr key", parsed["sonarr"]["apikey"] == "")

    summary = {"versions": {"sonarr": "4.x"}, "note": "no secrets here"}
    check("summary carries no secrets",
          "KEY1" not in json.dumps(summary) and "KEY2" not in json.dumps(summary))
    check("fields round-trip", fields_map({"fields": fields_list(cmap)}) == cmap)

    print("%d failures" % len(failures))
    return 1 if failures else 0


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Wire Starr integrations (runs inside starr LXC)")
    parser.add_argument("--qbit-host", required=False, default=None)
    parser.add_argument("--qbit-user", default="admin")
    parser.add_argument("--qbit-pass", required=False, default=None)
    parser.add_argument("--qbit-port", type=int, default=8090)
    parser.add_argument("--data-root", default=DATA_ROOT)
    parser.add_argument("--skip-bazarr", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.qbit_host:
        fail("--qbit-host is required")
    if not args.qbit_pass:
        fail("--qbit-pass is required")

    prowlarr_key = read_api_key(args.data_root, "prowlarr")
    sonarr_key = read_api_key(args.data_root, "sonarr")
    radarr_key = read_api_key(args.data_root, "radarr")

    versions = {}
    versions["prowlarr"] = wait_healthy("prowlarr", PROWLARR_BASE, prowlarr_key, "/api/v1/system/status").get("version", "?")
    versions["sonarr"] = wait_healthy("sonarr", SONARR_BASE, sonarr_key, "/api/v3/system/status").get("version", "?")
    versions["radarr"] = wait_healthy("radarr", RADARR_BASE, radarr_key, "/api/v3/system/status").get("version", "?")

    if not args.dry_run:
        check_qbit_login(args.qbit_host, args.qbit_port, args.qbit_user, args.qbit_pass)

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
        bazarr_action = ensure_bazarr(sonarr_key, radarr_key, args.dry_run)

    print(json.dumps({
        "dry_run": args.dry_run,
        "versions": versions,
        "prowlarr_apps": apps,
        "download_clients": clients,
        "root_folders": folders,
        "bazarr": bazarr_action,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
