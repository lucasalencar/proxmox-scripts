#!/usr/bin/env python3
"""Unit tests for starr/container/configure.py.

Self-contained: bootstraps its own sys.path, needs no services running.
Live-service paths are exercised with fake transports, never real HTTP.
YAML round-trip tests skip when python3-ruamel.yaml is absent (CI/macOS);
they run in full inside the starr LXC where provision.sh installs it.
"""

import argparse
import copy
import json
import os
import sys
import tempfile
import unittest
import unittest.mock
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import configure

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURES = os.path.join(REPO_ROOT, "tests", "fixtures", "starr")

HOST = "192.168.31.86"


def write_temp(content, suffix=".yaml"):
    tmp = tempfile.NamedTemporaryFile("w", suffix=suffix, delete=False)
    tmp.write(content)
    tmp.close()
    return tmp.name


class FakeServarrTransport:
    """Records (method, path, body); GET replays a payload, writes fake an id."""

    def __init__(self, get_payload):
        self.calls = []
        self.get_payload = get_payload

    def __call__(self, method, base, api_key, path, body=None):
        self.calls.append((method, path, body))
        if method == "GET":
            return copy.deepcopy(self.get_payload)
        return {"id": 7}

    def writes(self):
        return [call for call in self.calls if call[0] != "GET"]


class FakeBazarrTransport(FakeServarrTransport):
    def __call__(self, api_key, method, path, body=None, form=False):
        return super().__call__(method, None, api_key, path, body)


class FakeHTTPResponse:
    def __init__(self, status, body):
        self.status = status
        self._body = body

    def read(self):
        return self._body.encode()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def blank_counters():
    return {"created": 0, "updated": 0, "unchanged": 0}


class ProwlarrBuilderTests(unittest.TestCase):
    def test_sonarr_contract_and_sync(self):
        app = configure.build_prowlarr_app("sonarr", "KEY1")
        self.assertEqual(app["configContract"], "SonarrSettings")
        self.assertEqual(app["syncLevel"], "fullSync")
        fields = configure.fields_map(app)
        self.assertEqual(fields["baseUrl"], configure.SONARR_BASE)
        self.assertEqual(fields["prowlarrUrl"], configure.PROWLARR_BASE)
        self.assertEqual(fields["apiKey"], "KEY1")
        self.assertEqual(fields["syncCategories"], configure.SONARR_SYNC_CATEGORIES)
        self.assertEqual(fields["animeSyncCategories"], configure.SONARR_ANIME_CATEGORIES)

    def test_radarr_contract_and_sync(self):
        app = configure.build_prowlarr_app("radarr", "KEY2")
        fields = configure.fields_map(app)
        self.assertEqual(app["configContract"], "RadarrSettings")
        self.assertEqual(fields["baseUrl"], configure.RADARR_BASE)
        self.assertEqual(fields["syncCategories"], configure.RADARR_SYNC_CATEGORIES)

    def test_rejects_unknown_kind(self):
        with self.assertRaises(SystemExit):
            configure.build_prowlarr_app("sonar", "KEY3")


class DownloadClientBuilderTests(unittest.TestCase):
    def setUp(self):
        self.sonarr = configure.build_download_client(
            "sonarr", HOST, 8090, "admin", "pw")
        self.cmap = configure.fields_map(self.sonarr)

    def test_implementation_and_overrides(self):
        self.assertEqual(self.sonarr["implementation"], "QBittorrent")
        self.assertEqual(self.cmap["host"], HOST)
        self.assertEqual(self.cmap["port"], 8090)
        self.assertEqual(self.cmap["username"], "admin")
        self.assertEqual(self.cmap["password"], "pw")
        self.assertIs(self.cmap["useSsl"], False)

    def test_categories_replace_schema_defaults(self):
        self.assertEqual(self.cmap.get("tvCategory"), configure.SONARR_CATEGORY)
        radarr = configure.fields_map(
            configure.build_download_client("radarr", HOST, 8090, "admin", "pw"))
        self.assertEqual(radarr.get("movieCategory"), configure.RADARR_CATEGORY)
        self.assertNotEqual(radarr.get("movieCategory"), "radarr")

    def test_rejects_unknown_kind(self):
        with self.assertRaises(SystemExit):
            configure.build_download_client("radarr2", "h", 1, "u", "p")


class QbitLoginTests(unittest.TestCase):
    def test_request_uses_form_content_type_and_referer(self):
        req = configure.build_qbit_login_request(HOST, 8090, "admin", "pw")
        self.assertEqual(req.get_header("Content-type"),
                         "application/x-www-form-urlencoded")
        self.assertEqual(req.get_header("Referer"), "http://%s:8090/" % HOST)

    def test_ipv6_url_is_bracketed(self):
        req = configure.build_qbit_login_request("2001:db8::86", 8090, "admin", "pw")
        self.assertEqual(req.full_url, "http://[2001:db8::86]:8090/api/v2/auth/login")

    def test_accepts_current_login_responses(self):
        self.assertTrue(configure.qbit_login_succeeded(200, "Ok."))
        self.assertTrue(configure.qbit_login_succeeded(204, ""))
        self.assertFalse(configure.qbit_login_succeeded(403, "Fails."))

    def test_successful_login_returns(self):
        with unittest.mock.patch("urllib.request.urlopen",
                                 return_value=FakeHTTPResponse(200, "Ok.")):
            self.assertIsNone(configure.check_qbit_login(HOST, 8090, "admin", "pw"))

    def test_rejected_login_fails_fast(self):
        with unittest.mock.patch("urllib.request.urlopen",
                                 return_value=FakeHTTPResponse(200, "Fails.")):
            with self.assertRaises(SystemExit):
                configure.check_qbit_login(HOST, 8090, "admin", "pw")

    def test_unauthorized_fails_fast(self):
        error = urllib.error.HTTPError("http://x/", 401, "Unauthorized", {}, None)
        with unittest.mock.patch("urllib.request.urlopen", side_effect=error):
            with self.assertRaises(SystemExit):
                configure.check_qbit_login(HOST, 8090, "admin", "pw")


class MergePlanUpsertTests(unittest.TestCase):
    def setUp(self):
        self.client = configure.build_download_client(
            "sonarr", HOST, 8090, "admin", "pw")
        self.cmap = configure.fields_map(self.client)
        self.same = {"id": 1, "enable": True, "priority": 1, "protocol": "torrent",
                     "name": "qBittorrent", "implementation": "QBittorrent",
                     "implementationName": "qBittorrent",
                     "configContract": "QBittorrentSettings",
                     "removeCompletedDownloads": True, "removeFailedDownloads": True,
                     "fields": configure.fields_list(self.cmap)}

    def test_merge_keeps_id_overrides_host_propagates_priority(self):
        existing = {"id": 3, "enable": True,
                    "fields": [{"name": "host", "value": "localhost"}]}
        merged = configure.merge_fields(existing, self.client)
        self.assertEqual(merged["id"], 3)
        self.assertEqual(configure.fields_map(merged)["host"], HOST)
        self.assertEqual(merged.get("priority"), 1)

    def test_merge_preserves_unknown_fields(self):
        existing = {"id": 3, "enable": True, "fields": [{"name": "custom", "value": "x"}]}
        merged = configure.fields_map(configure.merge_fields(existing, self.client))
        self.assertEqual(merged.get("custom"), "x")

    def test_plan_empty_stale_drift(self):
        match = configure.match_qbittorrent
        self.assertEqual(configure.plan_action(match, [], self.client), "created")
        self.assertEqual(configure.plan_action(match, [self.same], self.client),
                         "unchanged")
        stale = dict(self.same)
        stale["fields"] = configure.fields_list(dict(self.cmap, host="10.0.0.1"))
        self.assertEqual(configure.plan_action(match, [stale], self.client), "updated")
        drift = dict(self.same)
        drift["removeCompletedDownloads"] = False
        self.assertEqual(configure.plan_action(match, [drift], self.client), "updated")

    def test_plan_masked_secrets_unchanged_but_stale_host_updated(self):
        masked = dict(self.same)
        masked["fields"] = configure.fields_list(
            dict(self.cmap, password="********"))
        self.assertEqual(configure.plan_action(configure.match_qbittorrent, [masked],
                                               self.client),
                         "unchanged")
        masked_stale = dict(masked)
        masked_stale["fields"] = configure.fields_list(
            dict(self.cmap, host="10.0.0.1", password="********"))
        self.assertEqual(
            configure.plan_action(configure.match_qbittorrent, [masked_stale],
                                  self.client),
            "updated")

    def test_plan_rejects_duplicates(self):
        with self.assertRaises(SystemExit):
            configure.matching_item(configure.match_qbittorrent, [self.same, self.same])

    def test_upsert_create_update_unchanged(self):
        calls = []

        def fake_create(body):
            calls.append(("create", body))
            return {"id": 7}

        def fake_update(i, body):
            calls.append(("update", (i, body)))
            return body

        match = configure.match_qbittorrent
        action, _ = configure.upsert(match, [], self.client, fake_create, fake_update)
        self.assertEqual(action, "created")
        self.assertEqual(calls[-1][0], "create")
        action, _ = configure.upsert(match, [self.same], self.client,
                                     fake_create, fake_update)
        self.assertEqual(action, "unchanged")
        self.assertEqual(len(calls), 1)
        stale = dict(self.same)
        stale["fields"] = configure.fields_list(dict(self.cmap, host="10.0.0.1"))
        action, _ = configure.upsert(match, [stale], self.client,
                                     fake_create, fake_update)
        self.assertEqual(action, "updated")
        self.assertEqual(calls[-1][0], "update")
        self.assertEqual(calls[-1][1][0], 1)
        self.assertEqual(configure.fields_map(calls[-1][1][1])["host"], HOST)


class ApiErrorScrubTests(unittest.TestCase):
    def test_secrets_scrubbed_diagnostics_kept(self):
        leaked = str(configure.ApiError(400, '{"message":"Invalid host",'
                                             '"password":"s3cret","apiKey":"K",'
                                             '"detail":"apikey=zzz&host=h"}'))
        self.assertNotIn("s3cret", leaked)
        self.assertNotIn('"K"', leaked)
        self.assertNotIn("zzz", leaked)
        self.assertIn("400", leaked)
        self.assertIn("Invalid host", leaked)
        self.assertIn("host=h", leaked)


class ValidPortHostTests(unittest.TestCase):
    def test_valid_port_accepts_range(self):
        self.assertEqual(configure.valid_port("8090"), 8090)
        self.assertEqual(configure.valid_port("1"), 1)
        self.assertEqual(configure.valid_port("65535"), 65535)

    def test_valid_port_rejects_out_of_range(self):
        for bad in ("0", "65536", "abc", ""):
            with self.assertRaises(argparse.ArgumentTypeError):
                configure.valid_port(bad)

    def test_valid_host_accepts_ips(self):
        self.assertEqual(configure.valid_host("1.2.3.4"), "1.2.3.4")
        self.assertEqual(configure.valid_host("2001:db8::86"), "2001:db8::86")
        self.assertEqual(configure.valid_host("[::1]"), "::1")

    def test_valid_host_rejects_non_ips(self):
        for bad in ("127.0.0.1@attacker.example", "localhost", ""):
            with self.assertRaises(argparse.ArgumentTypeError):
                configure.valid_host(bad)

    def test_parse_args_wires_validators(self):
        args = configure.parse_args(["--qbit-host", "1.2.3.4", "--qbit-port", "8090"])
        self.assertEqual(args.qbit_host, "1.2.3.4")
        self.assertEqual(args.qbit_port, 8090)
        with self.assertRaises(SystemExit):
            configure.parse_args(["--qbit-port", "0"])
        with self.assertRaises(SystemExit):
            configure.parse_args(["--qbit-host", "nope"])


@unittest.skipUnless(configure.HAVE_RUAMEL, "ruamel.yaml not installed")
class BazarrYamlTests(unittest.TestCase):
    SAMPLE = ("auth:\n  apikey: 'AUTHKEY' # rotated weekly\n  type: null\n"
              "sonarr:\n  ip: 10.0.0.2\n  port: 1\n  base_url: '/wrong'\n"
              "  ssl: True\n  apikey: ''\n"
              "radarr:\n  ip: 10.0.0.3\n  port: 2\n  base_url: '/wrong'\n"
              "  ssl: True\n  apikey: ''\n"
              "general:\n  use_sonarr: False\n  use_radarr: False\n"
              "unrelated:\n  keep_me: yes # operator tuning\n")

    def test_parse_reads_keys_with_native_types(self):
        parsed = configure.parse_bazarr_yaml(write_temp(self.SAMPLE))
        self.assertEqual(parsed["auth"]["apikey"], "AUTHKEY")
        self.assertEqual(parsed["sonarr"]["apikey"], "")
        self.assertEqual(parsed["sonarr"]["port"], 1)

    def test_rewrite_persists_keys_and_preserves_file(self):
        path = write_temp(self.SAMPLE)
        configure.rewrite_bazarr_yaml(path, "SKEY", "RKEY")
        reparsed = configure.parse_bazarr_yaml(path)
        self.assertEqual(reparsed["sonarr"]["ip"], configure.LOCALHOST_IP)
        self.assertEqual(reparsed["sonarr"]["port"], configure.SONARR_PORT)
        self.assertEqual(reparsed["sonarr"]["base_url"], "")
        self.assertIs(reparsed["sonarr"]["ssl"], False)
        self.assertEqual(reparsed["sonarr"]["apikey"], "SKEY")
        self.assertEqual(reparsed["radarr"]["apikey"], "RKEY")
        self.assertIs(reparsed["general"]["use_sonarr"], True)
        self.assertIs(reparsed["general"]["use_radarr"], True)
        with open(path, encoding="utf-8") as handle:
            rewritten = handle.read()
        self.assertIn("# rotated weekly", rewritten)
        self.assertIn("keep_me", rewritten)

    def test_rewrite_adds_missing_sections(self):
        path = write_temp("auth:\n  apikey: 'AUTHKEY'\n")
        configure.rewrite_bazarr_yaml(path, "SKEY", "RKEY")
        sections = configure.parse_bazarr_yaml(path)
        self.assertEqual(sections["sonarr"]["apikey"], "SKEY")
        self.assertEqual(sections["radarr"]["apikey"], "RKEY")
        self.assertIs(sections["general"]["use_sonarr"], True)

    def test_rejects_non_mapping_top_level(self):
        with self.assertRaises(SystemExit):
            configure.parse_bazarr_yaml(write_temp("- just\n- a\n- list\n"))


class BazarrLinkingTests(unittest.TestCase):
    def test_linked_unlinked_and_root_base_url(self):
        linked = {
            "sonarr": {"ip": configure.LOCALHOST_IP, "port": configure.SONARR_PORT,
                       "base_url": "", "ssl": False, "apikey": "SKEY"},
            "radarr": {"ip": configure.LOCALHOST_IP, "port": configure.RADARR_PORT,
                       "base_url": "", "ssl": False, "apikey": "RKEY"},
            "general": {"use_sonarr": True, "use_radarr": True},
        }
        self.assertTrue(configure.is_bazarr_linked(linked, "SKEY", "RKEY"))
        slash = dict(linked)
        slash["sonarr"] = dict(linked["sonarr"], base_url="/")
        self.assertTrue(configure.is_bazarr_linked(slash, "SKEY", "RKEY"))
        self.assertFalse(
            configure.is_bazarr_linked({"sonarr": {"apikey": ""}}, "SKEY", "RKEY"))

    def test_settings_form_uses_api_field_names(self):
        form = configure.bazarr_settings_form("SKEY", "RKEY")
        self.assertEqual(form["settings-general-use_sonarr"], "true")
        self.assertEqual(form["settings-sonarr-port"], str(configure.SONARR_PORT))


class FixtureCrossCheckTests(unittest.TestCase):
    def test_builders_match_research_fixtures(self):
        dump = {
            "prowlarr_sonarr": configure.build_prowlarr_app("sonarr", "APIKEY"),
            "prowlarr_radarr": configure.build_prowlarr_app("radarr", "APIKEY"),
            "download_sonarr": configure.build_download_client(
                "sonarr", "1.2.3.4", 8090, "admin", "pw"),
            "download_radarr": configure.build_download_client(
                "radarr", "1.2.3.4", 8090, "admin", "pw"),
        }
        pairs = [("prowlarr_sonarr", "prowlarr-sonarr-schema-excerpt.json"),
                 ("prowlarr_radarr", "prowlarr-radarr-schema-excerpt.json"),
                 ("download_sonarr", "sonarr-qbittorrent-schema-excerpt.json"),
                 ("download_radarr", "radarr-qbittorrent-schema-excerpt.json")]
        for builder_key, fixture_name in pairs:
            with open(os.path.join(FIXTURES, fixture_name), encoding="utf-8") as handle:
                known = {field["name"] for field in json.load(handle)["fields"]}
            built = {field["name"] for field in dump[builder_key]["fields"]}
            self.assertEqual(built - known, set())
            self.assertEqual(known - built, set())
        for builder_key, fixture_name in pairs[:2]:
            with open(os.path.join(FIXTURES, fixture_name), encoding="utf-8") as handle:
                expected = {field["name"]: field.get("value")
                            for field in json.load(handle)["fields"]}
            actual = {field["name"]: field.get("value")
                      for field in dump[builder_key]["fields"]}
            for name, value in expected.items():
                if name == "apiKey":
                    continue
                self.assertEqual(actual.get(name), value,
                                 "%s field %s" % (builder_key, name))


class EnsureFlowTests(unittest.TestCase):
    def setUp(self):
        self._orig_servarr = configure.servarr_request
        self._orig_bazarr = configure.bazarr_request
        self.addCleanup(setattr, configure, "servarr_request", self._orig_servarr)
        self.addCleanup(setattr, configure, "bazarr_request", self._orig_bazarr)

    def test_download_client_created_with_overrides(self):
        transport = FakeServarrTransport([])
        configure.servarr_request = transport
        counters = blank_counters()
        configure.ensure_download_client("sonarr", configure.SONARR_BASE, "KEY",
                                         HOST, 8090, "admin", "pw", False, counters)
        self.assertEqual(counters, {"created": 1, "updated": 0, "unchanged": 0})
        posts = transport.writes()
        self.assertEqual(len(posts), 1)
        method, path, body = posts[0]
        self.assertEqual((method, path), ("POST", "/api/v3/downloadclient"))
        fields = configure.fields_map(body)
        self.assertEqual(body["implementation"], "QBittorrent")
        self.assertEqual(fields["host"], HOST)
        self.assertEqual(fields["port"], 8090)
        self.assertEqual(fields["tvCategory"], configure.SONARR_CATEGORY)

    def test_download_client_masked_unchanged_without_writes(self):
        desired = configure.build_download_client("sonarr", HOST, 8090, "admin", "pw")
        existing = dict(desired, id=4)
        existing["fields"] = [{"name": name,
                               "value": "********" if name in ("username", "password",
                                                               "apiKey")
                               else value}
                              for name, value in configure.fields_map(desired).items()]
        transport = FakeServarrTransport([existing])
        configure.servarr_request = transport
        counters = blank_counters()
        configure.ensure_download_client("sonarr", configure.SONARR_BASE, "KEY",
                                         HOST, 8090, "admin", "pw", False, counters)
        self.assertEqual(counters, {"created": 0, "updated": 0, "unchanged": 1})
        self.assertEqual(transport.writes(), [])

    def test_download_client_dry_run_writes_nothing(self):
        transport = FakeServarrTransport([])
        configure.servarr_request = transport
        counters = blank_counters()
        configure.ensure_download_client("sonarr", configure.SONARR_BASE, "KEY",
                                         HOST, 8090, "admin", "pw", True, counters)
        self.assertEqual(counters["created"], 1)
        self.assertEqual(transport.writes(), [])

    def test_prowlarr_app_created(self):
        transport = FakeServarrTransport([])
        configure.servarr_request = transport
        counters = blank_counters()
        configure.ensure_prowlarr_app("sonarr", "PKEY", "SKEY", False, counters)
        self.assertEqual(counters, {"created": 1, "updated": 0, "unchanged": 0})
        posts = transport.writes()
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0][1], "/api/v1/applications")
        self.assertEqual(posts[0][2]["configContract"], "SonarrSettings")

    def test_bazarr_dry_run_links_nothing(self):
        transport = FakeBazarrTransport({"sonarr": {"apikey": ""},
                                         "radarr": {}, "general": {}})
        with unittest.mock.patch.object(configure, "bazarr_request", transport), \
             unittest.mock.patch.object(configure, "parse_bazarr_yaml",
                                        return_value={"auth": {"apikey": "AUTHKEY"}}):
            self.assertEqual(
                configure.ensure_bazarr("S", "R", True, "/nonexistent.yaml"),
                "would_link")
        self.assertEqual(transport.writes(), [])


class SummaryShapeTests(unittest.TestCase):
    def test_summary_keys_locked(self):
        summary = configure.build_summary(
            {"sonarr": "4.x"},
            {"created": 1, "updated": 0, "unchanged": 0},
            {"created": 0, "updated": 0, "unchanged": 0},
            {"created": 0, "updated": 0, "unchanged": 0},
            "linked", False)
        self.assertEqual(set(summary.keys()),
                         {"dry_run", "versions", "prowlarr_apps",
                          "download_clients", "root_folders", "bazarr"})

    def test_fields_round_trip(self):
        cmap = configure.fields_map(
            configure.build_download_client("sonarr", HOST, 8090, "admin", "pw"))
        self.assertEqual(configure.fields_map({"fields": configure.fields_list(cmap)}),
                         cmap)


if __name__ == "__main__":
    unittest.main(verbosity=2)
