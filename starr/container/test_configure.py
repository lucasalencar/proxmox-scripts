#!/usr/bin/env python3
"""Unit tests for starr/container/configure.py.

Self-contained: bootstraps its own sys.path, needs no services running.
Live-service paths are exercised with fake transports, never real HTTP.
YAML round-trip tests skip when python3-ruamel.yaml is absent (CI/macOS);
they run in full inside the starr LXC where provision.sh installs it.
"""

import argparse
import contextlib
import copy
import http.server
import io
import json
import os
import sys
import tempfile
import threading
import unittest
import unittest.mock
import urllib.error
import urllib.parse
from email.message import Message

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
    def __call__(self, method, path, api_key, body=None, form=False):
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

    def test_skip_qbit_flag_defaults_off(self):
        self.assertFalse(configure.parse_args([]).skip_qbit)
        self.assertTrue(configure.parse_args(["--skip-qbit"]).skip_qbit)


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
        int_flags = dict(linked)
        int_flags["general"] = {"use_sonarr": 1, "use_radarr": 1}
        self.assertTrue(configure.is_bazarr_linked(int_flags, "SKEY", "RKEY"))
        self.assertFalse(
            configure.is_bazarr_linked({"sonarr": {"apikey": ""}}, "SKEY", "RKEY"))

    def test_settings_form_uses_api_field_names(self):
        form = configure.bazarr_settings_form("SKEY", "RKEY")
        self.assertEqual(form["settings-general-use_sonarr"], "true")
        self.assertEqual(form["settings-sonarr-port"], str(configure.SONARR_PORT))
        self.assertEqual(form, {
            "settings-sonarr-ip": "127.0.0.1",
            "settings-sonarr-port": str(configure.SONARR_PORT),
            "settings-sonarr-base_url": "",
            "settings-sonarr-ssl": "false",
            "settings-sonarr-apikey": "SKEY",
            "settings-radarr-ip": "127.0.0.1",
            "settings-radarr-port": str(configure.RADARR_PORT),
            "settings-radarr-base_url": "",
            "settings-radarr-ssl": "false",
            "settings-radarr-apikey": "RKEY",
            "settings-general-use_sonarr": "true",
            "settings-general-use_radarr": "true",
        })


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

    def test_bazarr_unchanged_writes_nothing(self):
        linked = {
            "sonarr": {"ip": configure.LOCALHOST_IP, "port": configure.SONARR_PORT,
                       "base_url": "", "ssl": False, "apikey": "S"},
            "radarr": {"ip": configure.LOCALHOST_IP, "port": configure.RADARR_PORT,
                       "base_url": "", "ssl": False, "apikey": "R"},
            "general": {"use_sonarr": True, "use_radarr": True},
        }
        transport = FakeBazarrTransport(linked)
        with unittest.mock.patch.object(configure, "bazarr_request", transport), \
             unittest.mock.patch.object(configure, "parse_bazarr_yaml",
                                        return_value={"auth": {"apikey": "AUTHKEY"}}):
            self.assertEqual(
                configure.ensure_bazarr("S", "R", False, "/nonexistent.yaml"),
                "unchanged")
        self.assertEqual(transport.writes(), [])

    def test_bazarr_api_linked_success(self):
        unlinked = {"sonarr": {"apikey": ""}, "radarr": {}, "general": {}}
        linked = {
            "sonarr": {"ip": configure.LOCALHOST_IP, "port": configure.SONARR_PORT,
                       "base_url": "", "ssl": False, "apikey": "S"},
            "radarr": {"ip": configure.LOCALHOST_IP, "port": configure.RADARR_PORT,
                       "base_url": "", "ssl": False, "apikey": "R"},
            "general": {"use_sonarr": True, "use_radarr": True},
        }
        gets = []

        def fake_request(method, path, api_key, body=None, form=False):
            if method == "GET":
                gets.append(1)
                return linked if len(gets) > 1 else unlinked
            return {"ok": True}

        with unittest.mock.patch.object(configure, "bazarr_request",
                                        side_effect=fake_request), \
             unittest.mock.patch.object(configure, "parse_bazarr_yaml",
                                        return_value={"auth": {"apikey": "AUTHKEY"}}):
            self.assertEqual(
                configure.ensure_bazarr("S", "R", False, "/nonexistent.yaml"),
                "linked")

    def test_bazarr_api_failure_fails_fast_for_retry(self):
        calls = []

        def fake_request(method, path, api_key, body=None, form=False):
            calls.append(method)
            if method == "POST":
                raise configure.ApiError(None, "connection reset")
            return {"sonarr": {"apikey": ""}, "radarr": {}, "general": {}}

        with unittest.mock.patch.object(configure, "bazarr_request",
                                        side_effect=fake_request), \
             unittest.mock.patch.object(configure, "parse_bazarr_yaml",
                                        return_value={"auth": {"apikey": "AUTHKEY"}}):
            with self.assertRaises(SystemExit):
                configure.ensure_bazarr("S", "R", False, "/nonexistent.yaml")
        self.assertIn("POST", calls)

    def test_bazarr_persist_failure_fails(self):
        transport = FakeBazarrTransport({"sonarr": {"apikey": ""},
                                         "radarr": {}, "general": {}})
        with unittest.mock.patch.object(configure, "bazarr_request", transport), \
             unittest.mock.patch.object(configure, "parse_bazarr_yaml",
                                        return_value={"auth": {"apikey": "AUTHKEY"}}), \
             unittest.mock.patch.object(configure, "wait_for_bazarr_state",
                                        return_value=False):
            with self.assertRaises(SystemExit):
                configure.ensure_bazarr("S", "R", False, "/nonexistent.yaml")

    def test_root_folder_created_and_posted(self):
        transport = FakeServarrTransport([])
        configure.servarr_request = transport
        counters = blank_counters()
        configure.ensure_root_folder(configure.SONARR_BASE, "KEY",
                                     "/data/media/Series", False, counters)
        self.assertEqual(counters, {"created": 1, "updated": 0, "unchanged": 0})
        posts = transport.writes()
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0][1], "/api/v3/rootfolder")
        self.assertEqual(posts[0][2], {"path": "/data/media/Series"})

    def test_root_folder_present_unchanged_and_inaccessible_fails(self):
        transport = FakeServarrTransport(
            [{"path": "/data/media/Series", "accessible": True}])
        configure.servarr_request = transport
        counters = blank_counters()
        configure.ensure_root_folder(configure.SONARR_BASE, "KEY",
                                     "/data/media/Series/", False, counters)
        self.assertEqual(counters["unchanged"], 1)
        self.assertEqual(transport.writes(), [])
        for bad in (False, 0):
            transport = FakeServarrTransport(
                [{"path": "/data/media/Series", "accessible": bad}])
            configure.servarr_request = transport
            with self.assertRaises(SystemExit):
                configure.ensure_root_folder(configure.SONARR_BASE, "KEY",
                                             "/data/media/Series", False,
                                             blank_counters())

    def test_download_client_updated_through_ensure(self):
        stale = {"id": 3, "enable": True, "implementation": "QBittorrent",
                 "fields": [{"name": "host", "value": "10.0.0.1"}]}
        transport = FakeServarrTransport([stale])
        configure.servarr_request = transport
        counters = blank_counters()
        configure.ensure_download_client("sonarr", configure.SONARR_BASE, "KEY",
                                         HOST, 8090, "admin", "pw", False, counters)
        self.assertEqual(counters, {"created": 0, "updated": 1, "unchanged": 0})
        writes = transport.writes()
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0][0], "PUT")
        self.assertIn("/api/v3/downloadclient/3", writes[0][1])
        self.assertEqual(configure.fields_map(writes[0][2])["host"], HOST)

    def test_prowlarr_app_updated_through_ensure(self):
        stale = {"id": 5, "implementation": "Sonarr", "enable": True,
                 "fields": [{"name": "baseUrl", "value": "http://old:8989"}]}
        transport = FakeServarrTransport([stale])
        configure.servarr_request = transport
        counters = blank_counters()
        configure.ensure_prowlarr_app("sonarr", "PKEY", "SKEY", False, counters)
        self.assertEqual(counters, {"created": 0, "updated": 1, "unchanged": 0})
        writes = transport.writes()
        self.assertEqual(len(writes), 1)
        self.assertIn("/api/v1/applications/5", writes[0][1])
        self.assertEqual(configure.fields_map(writes[0][2])["baseUrl"],
                         configure.SONARR_BASE)


class ServarrAuthTests(unittest.TestCase):
    def test_auth_file_preserves_credential_spacing(self):
        path = write_temp("sonarr_user= admin \n"
                          "sonarr_pass= ' s3cret with spaces ' \n"
                          "# comment line\n"
                          "\n")
        creds = configure.parse_auth_file(path)
        self.assertEqual(creds["sonarr_user"], " admin ")
        self.assertEqual(creds["sonarr_pass"], " ' s3cret with spaces ' ")

    def test_desired_host_config_locks_forms_enabled(self):
        body = configure.build_servarr_host_config(
            {"id": 1, "authenticationMethod": "none",
             "authenticationRequired": "enabled",
             "username": "", "password": "",
             "passwordConfirmation": ""},
            "forms", "svc-sonarr", "Pw1!")
        self.assertEqual(body["id"], 1)
        self.assertEqual(body["authenticationMethod"], "forms")
        self.assertEqual(body["authenticationRequired"], "enabled")
        self.assertEqual(body["username"], "svc-sonarr")
        self.assertEqual(body["password"], "Pw1!")
        self.assertEqual(body.get("passwordConfirmation"), "Pw1!")

    def test_auth_plan_virgin_masked_and_drift(self):
        virgin = {"id": 1, "authenticationMethod": "none",
                  "authenticationRequired": "enabled",
                  "username": "", "password": ""}
        self.assertEqual(
            configure.plan_servarr_auth(virgin, "forms", "u", "pw"), "updated")
        masked = {"id": 1, "authenticationMethod": "forms",
                  "authenticationRequired": "enabled",
                  "username": "u", "password": "********"}
        self.assertEqual(
            configure.plan_servarr_auth(masked, "forms", "u", "pw"), "unchanged")
        drift = dict(masked, username="other")
        self.assertEqual(
            configure.plan_servarr_auth(drift, "forms", "u", "pw"), "updated")

    def test_ensure_servarr_auth_puts_merged_object(self):
        virgin = {"id": 1, "authenticationMethod": "none",
                  "authenticationRequired": "enabled",
                  "username": "", "password": "", "port": 8989}
        transport = FakeServarrTransport(virgin)
        with unittest.mock.patch.object(configure, "servarr_request", transport), \
             unittest.mock.patch.object(configure, "check_servarr_login",
                                        return_value=None):
            action = configure.ensure_servarr_auth(
                "sonarr", configure.SONARR_BASE, "KEY",
                configure.SONARR_HOST_PATH, "forms",
                "u", "pw", False)
        self.assertEqual(action, "updated")
        puts = [c for c in transport.calls if c[0] == "PUT"]
        self.assertEqual(len(puts), 1)
        self.assertIn("/api/v3/config/host/1", puts[0][1])
        self.assertEqual(puts[0][2]["username"], "u")
        self.assertEqual(puts[0][2]["port"], 8989)

    def test_ensure_servarr_auth_unchanged_writes_nothing(self):
        masked = {"id": 1, "authenticationMethod": "forms",
                  "authenticationRequired": "enabled",
                  "username": "u", "password": "********"}
        transport = FakeServarrTransport(masked)
        with unittest.mock.patch.object(configure, "servarr_request", transport), \
             unittest.mock.patch.object(configure, "probe_servarr_login",
                                        return_value=True):
            action = configure.ensure_servarr_auth(
                "sonarr", configure.SONARR_BASE, "KEY",
                configure.SONARR_HOST_PATH, "forms",
                "u", "pw", False)
        self.assertEqual(action, "unchanged")
        self.assertEqual(
            [c for c in transport.calls if c[0] != "GET"], [])

    def test_ensure_servarr_auth_heals_failed_probe_with_update(self):
        masked = {"id": 1, "authenticationMethod": "forms",
                  "authenticationRequired": "enabled",
                  "username": "u", "password": "********"}
        transport = FakeServarrTransport(masked)
        with unittest.mock.patch.object(configure, "servarr_request", transport), \
             unittest.mock.patch.object(configure, "probe_servarr_login",
                                        return_value=False), \
             unittest.mock.patch.object(configure, "check_servarr_login",
                                        return_value=None):
            action = configure.ensure_servarr_auth(
                "sonarr", configure.SONARR_BASE, "KEY",
                configure.SONARR_HOST_PATH, "forms",
                "u", "pw", False)
        self.assertEqual(action, "updated")
        self.assertEqual(len([c for c in transport.calls if c[0] == "PUT"]), 1)

    def test_ensure_servarr_auth_dry_run_writes_nothing(self):
        virgin = {"id": 1, "authenticationMethod": "none",
                  "authenticationRequired": "enabled",
                  "username": "", "password": ""}
        transport = FakeServarrTransport(virgin)
        with unittest.mock.patch.object(configure, "servarr_request", transport), \
             unittest.mock.patch.object(configure, "check_servarr_login",
                                        return_value=None) as login:
            action = configure.ensure_servarr_auth(
                "sonarr", configure.SONARR_BASE, "KEY",
                configure.SONARR_HOST_PATH, "forms",
                "u", "pw", True)
        self.assertEqual(action, "would_update")
        self.assertEqual(
            [c for c in transport.calls if c[0] != "GET"], [])
        login.assert_not_called()

class FakeOpener:
    """Replays urlopen results for cookie-flow probes (responses or exceptions)."""

    def __init__(self, script):
        self.script = list(script)
        self.opened = []

    def open(self, req, timeout=None):
        self.opened.append(req)
        item = self.script.pop(0)
        if isinstance(item, Exception):
            raise item
        return item


class ServarrLoginProbeTests(unittest.TestCase):
    STATUS = "/api/v3/system/status"

    @staticmethod
    def _login_redirect(location, cookies=()):
        headers = Message()
        headers["Location"] = location
        for name, value in cookies:
            headers["Set-Cookie"] = "%s=%s; path=/; httponly" % (name, value)
        return urllib.error.HTTPError("http://x/login", 302, "Found",
                                      headers, None)

    def test_forms_login_accepted_on_app_redirect_with_session_cookie(self):
        opener = FakeOpener(
            [self._login_redirect("/", [("SonarrAuth", "abc123")])])
        with unittest.mock.patch("urllib.request.build_opener",
                                 return_value=opener):
            self.assertIs(
                configure.probe_servarr_login("http://localhost:8989",
                                              self.STATUS, "u", "pw"), True)

    def test_forms_login_rejected_on_login_redirect_without_cookie(self):
        opener = FakeOpener(
            [self._login_redirect("/login?returnUrl=&loginFailed=true")])
        with unittest.mock.patch("urllib.request.build_opener",
                                 return_value=opener):
            self.assertIs(
                configure.probe_servarr_login("http://localhost:8989",
                                              self.STATUS, "u", "pw"), False)
        with unittest.mock.patch.object(configure, "probe_servarr_login",
                                        return_value=False) as probe:
            with self.assertRaises(SystemExit):
                configure.check_servarr_login("http://localhost:8989",
                                              self.STATUS, "u", "pw")
            probe.assert_called_once()

    def test_forms_login_transient_outage_recovers_with_retry(self):
        # Unreachable service (None) is retried; success on the third
        # attempt must not fail.
        with unittest.mock.patch.object(configure, "probe_servarr_login",
                                        side_effect=[None, None, True]) as probe, \
             unittest.mock.patch("time.sleep", return_value=None):
            self.assertIsNone(
                configure.check_servarr_login("http://localhost:8989",
                                              self.STATUS, "u", "pw"))
            self.assertEqual(probe.call_count, 3)

    def test_forms_login_prolonged_outage_fails_after_timeout(self):
        with unittest.mock.patch.object(configure, "probe_servarr_login",
                                        return_value=None):
            with self.assertRaises(SystemExit):
                configure.check_servarr_login("http://localhost:8989",
                                              self.STATUS, "u", "pw",
                                              timeout=2)

    def test_forms_login_transient_when_service_unreachable(self):
        opener = FakeOpener([OSError("connection refused")])
        with unittest.mock.patch("urllib.request.build_opener",
                                 return_value=opener):
            self.assertIsNone(
                configure.probe_servarr_login("http://localhost:8989",
                                              self.STATUS, "u", "pw"))

    def test_basic_login_uses_authorization_header(self):
        seen = []

        def fake_urlopen(req, timeout=None):
            seen.append(req)
            return FakeHTTPResponse(200, '{"version":"4.0"}')

        with unittest.mock.patch("urllib.request.urlopen",
                                 side_effect=fake_urlopen):
            self.assertIs(
                configure.probe_servarr_login("http://localhost:8989",
                                              self.STATUS, "u", "pw",
                                              "basic"), True)
        self.assertTrue(seen[0].get_header("Authorization").startswith("Basic "))

        error = urllib.error.HTTPError("http://x/", 401, "Unauthorized", {}, None)
        with unittest.mock.patch("urllib.request.urlopen", side_effect=error):
            self.assertIs(
                configure.probe_servarr_login("http://localhost:8989",
                                              self.STATUS, "u", "pw",
                                              "basic"), False)


class ServarrFormsLoopbackTests(unittest.TestCase):
    """End-to-end forms probe against a real loopback server mimicking the
    observed Servarr behavior: the login POST 302s to "/" with a session
    cookie on good credentials (back to /login without one on bad), while
    the JSON API only accepts the API key and always 401s on cookie auth.
    """

    USER = "loopback-admin"
    PASS = "s3cret!"

    STATUS = "/api/v1/system/status"

    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "LoopbackServarr/1.0"

        def _send(self, code, headers, body=b""):
            self.send_response(code)
            for name, value in headers:
                self.send_header(name, value)
            self.end_headers()
            if body:
                self.wfile.write(body)

        def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler naming
            length = int(self.headers.get("Content-Length", 0))
            fields = urllib.parse.parse_qs(
                self.rfile.read(length).decode())
            outer = self.server.outer
            if (self.path == "/login"
                    and fields.get("username") == [outer.USER]
                    and fields.get("password") == [outer.PASS]):
                self._send(302, [("Location", "/"),
                                 ("Set-Cookie",
                                  "LoopbackAuth=abc123; path=/; "
                                  "samesite=lax; httponly")])
            else:
                self._send(302, [("Location",
                                  "/login?returnUrl=&loginFailed=true")])

        def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler naming
            if self.path == self.server.outer.STATUS:
                self._send(401, [])
            else:
                self._send(200, [], b"app")

        def log_message(self, *args):
            pass

    @classmethod
    def setUpClass(cls):
        cls.server = http.server.HTTPServer(("127.0.0.1", 0), cls.Handler)
        cls.server.outer = cls
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever,
                                      daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join()
        cls.server.server_close()

    def base(self):
        return "http://localhost:%d" % self.port

    def test_probe_accepts_correct_credentials(self):
        self.assertIs(
            configure.probe_servarr_login(self.base(), self.STATUS,
                                          self.USER, self.PASS), True)

    def test_probe_rejects_wrong_credentials(self):
        self.assertIs(
            configure.probe_servarr_login(self.base(), self.STATUS,
                                          self.USER, "wrong"), False)


class BazarrAuthTests(unittest.TestCase):
    def test_login_probe_maps_account_statuses(self):
        with unittest.mock.patch.object(configure, "bazarr_request",
                                        return_value=None):
            self.assertIs(configure.probe_bazarr_login("K", "u", "pw"), True)
        error = configure.ApiError(403, "Authentication failed")
        with unittest.mock.patch.object(configure, "bazarr_request",
                                        side_effect=error):
            self.assertIs(configure.probe_bazarr_login("K", "u", "pw"), False)
        error = configure.ApiError(None, "connection reset")
        with unittest.mock.patch.object(configure, "bazarr_request",
                                        side_effect=error):
            self.assertIsNone(configure.probe_bazarr_login("K", "u", "pw"))

    def test_masked_but_rotated_password_heals_through_probe(self):
        linked = {"auth": {"type": "form", "username": "u",
                           "password": "********"}}
        transport = FakeBazarrTransport(linked)
        with unittest.mock.patch.object(configure, "bazarr_request", transport), \
             unittest.mock.patch.object(configure, "probe_bazarr_login",
                                        side_effect=[False, True]):
            action = configure.ensure_bazarr_auth(
                "APIKEY", "u", "pw", "form", False)
        self.assertEqual(action, "updated")
        self.assertTrue(any(call[0] == "POST" for call in transport.calls))

    def test_post_update_login_failure_fails(self):
        virgin = {"auth": {"type": None, "username": "", "password": ""}}
        linked = {"auth": {"type": "form", "username": "u",
                           "password": "********"}}
        gets = []

        def fake_request(method, path, api_key, body=None, form=False):
            if method == "GET":
                gets.append(1)
                return linked if len(gets) > 1 else virgin
            if path == "/api/system/account":
                raise configure.ApiError(403, "Authentication failed")
            return {"ok": True}

        with unittest.mock.patch.object(configure, "bazarr_request",
                                        side_effect=fake_request):
            with self.assertRaises(SystemExit):
                configure.ensure_bazarr_auth(
                    "APIKEY", "u", "pw", "form", False)

    def test_auth_form_uses_api_field_names(self):
        form = configure.bazarr_auth_form("form", "svc-bazarr", "Pw1!")
        self.assertEqual(form, {
            "settings-auth-type": "form",
            "settings-auth-username": "svc-bazarr",
            "settings-auth-password": "Pw1!",
        })

    def test_auth_plan_virgin_masked_and_drift(self):
        virgin = {"auth": {"type": None, "username": "", "password": ""}}
        self.assertEqual(
            configure.plan_bazarr_auth(virgin, "form", "u", "pw"), "updated")
        masked = {"auth": {"type": "form", "username": "u",
                           "password": "********"}}
        self.assertEqual(
            configure.plan_bazarr_auth(masked, "form", "u", "pw"), "unchanged")
        drift = {"auth": {"type": "form", "username": "other",
                           "password": "********"}}
        self.assertEqual(
            configure.plan_bazarr_auth(drift, "form", "u", "pw"), "updated")

    def test_auth_plan_matches_md5_digest(self):
        # Bazarr persists auth.password as an MD5 hex digest, never
        # plaintext: md5(desired) must count as unchanged.
        import hashlib
        digest = hashlib.md5("pw".encode()).hexdigest()
        stored = {"auth": {"type": "form", "username": "u",
                           "password": digest}}
        self.assertEqual(
            configure.plan_bazarr_auth(stored, "form", "u", "pw"), "unchanged")
        rotated = {"auth": {"type": "form", "username": "u",
                            "password": hashlib.md5("old".encode()).hexdigest()}}
        self.assertEqual(
            configure.plan_bazarr_auth(rotated, "form", "u", "pw"), "updated")

    def test_ensure_bazarr_auth_md5_unchanged_writes_nothing(self):
        import hashlib
        digest = hashlib.md5("pw".encode()).hexdigest()
        linked = {"auth": {"type": "form", "username": "u",
                           "password": digest}}
        transport = FakeBazarrTransport(linked)
        with unittest.mock.patch.object(configure, "bazarr_request", transport), \
             unittest.mock.patch.object(configure, "probe_bazarr_login",
                                        return_value=True):
            action = configure.ensure_bazarr_auth(
                "APIKEY", "u", "pw", "form", False)
        self.assertEqual(action, "unchanged")
        self.assertFalse(any(call[0] == "POST" for call in transport.calls))

    def test_ensure_bazarr_auth_posts_and_verifies(self):
        virgin = {"auth": {"type": None, "username": "", "password": ""}}
        linked = {"auth": {"type": "form", "username": "u",
                           "password": "********"}}
        gets = []

        def fake_request(method, path, api_key, body=None, form=False):
            if method == "GET":
                gets.append(1)
                return linked if len(gets) > 1 else virgin
            return {"ok": True}

        with unittest.mock.patch.object(configure, "bazarr_request",
                                        side_effect=fake_request):
            action = configure.ensure_bazarr_auth(
                "APIKEY", "u", "pw", "form", False)
        self.assertEqual(action, "updated")

    def test_ensure_bazarr_auth_api_failure_fails_fast_for_retry(self):
        def fake_request(method, path, api_key, body=None, form=False):
            if method == "POST":
                raise configure.ApiError(None, "connection reset")
            return {"auth": {"type": None, "username": "", "password": ""}}

        with unittest.mock.patch.object(configure, "bazarr_request",
                                        side_effect=fake_request):
            with self.assertRaises(SystemExit):
                configure.ensure_bazarr_auth(
                    "APIKEY", "u", "pw", "form", False)


class SummaryShapeTests(unittest.TestCase):
    def test_summary_keys_locked(self):
        summary = configure.build_summary(
            {"sonarr": "4.x"},
            {"created": 1, "updated": 0, "unchanged": 0},
            {"created": 0, "updated": 0, "unchanged": 0},
            {"created": 0, "updated": 0, "unchanged": 0},
            "linked", False,
            {"sonarr": "updated"},
            "configured", "configured")
        self.assertEqual(set(summary.keys()),
                         {"dry_run", "versions", "prowlarr_apps",
                          "download_clients", "root_folders", "bazarr", "auth",
                          "flaresolverr", "qbit", "seerr"})
        self.assertEqual(summary["flaresolverr"], "configured")
        self.assertEqual(summary["qbit"], "configured")
        self.assertEqual(summary["seerr"], "skipped")

    def test_fields_round_trip(self):
        cmap = configure.fields_map(
            configure.build_download_client("sonarr", HOST, 8090, "admin", "pw"))
        self.assertEqual(configure.fields_map({"fields": configure.fields_list(cmap)}),
                         cmap)


class FakeProwlarrTransport:
    """Path-routed Prowlarr fake: serves tags/proxies, records writes.

    POSTs to the tag endpoint mutate the served tag list so the read-back after
    creation behaves like the real API. Indexer endpoints are intentionally
    absent: ensure_flaresolverr must never touch indexers (manual tagging).
    """

    def __init__(self, tags=None, proxies=None):
        self.tags = [dict(t) for t in (tags or [])]
        self.proxies = [dict(p) for p in (proxies or [])]
        self.calls = []

    def __call__(self, method, base, api_key, path, body=None):
        self.calls.append((method, path, body))
        route = path.split("?")[0]
        if method == "GET":
            if route == configure.PROWLARR_TAG_PATH:
                return copy.deepcopy(self.tags)
            if route == configure.PROWLARR_INDEXER_PROXY_PATH:
                return copy.deepcopy(self.proxies)
            return []
        if route == configure.PROWLARR_TAG_PATH:
            next_id = max([t.get("id", 0) for t in self.tags] + [0]) + 1
            self.tags.append({"id": next_id, "label": body["label"]})
            return {"id": next_id}
        return {"id": 1}

    def writes(self):
        return [call for call in self.calls if call[0] != "GET"]

    def write_paths(self):
        return [call[1] for call in self.writes()]


FLARESOLVERR_PROXY_EXISTING = {
    "id": 9,
    "name": "FlareSolverr",
    "implementation": "FlareSolverr",
    "implementationName": "FlareSolverr",
    "configContract": "FlareSolverrSettings",
    "tags": [7],
    "fields": [{"name": "host", "value": configure.FLARESOLVERR_HOST},
               {"name": "requestTimeout",
                "value": configure.FLARESOLVERR_REQUEST_TIMEOUT}],
}


class FlareSolverrTests(unittest.TestCase):
    def setUp(self):
        self._orig = configure.servarr_request
        self.addCleanup(setattr, configure, "servarr_request", self._orig)

    def connect(self, transport, healthy=True):
        configure.servarr_request = transport
        patcher = unittest.mock.patch.object(configure, "probe_flaresolverr",
                                             return_value=healthy)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_builder_shape_matches_prowlarr_flare_solverr_settings(self):
        proxy = configure.build_flaresolverr_proxy([7])
        self.assertEqual(proxy["implementation"], "FlareSolverr")
        self.assertEqual(proxy["implementationName"], "FlareSolverr")
        self.assertEqual(proxy["configContract"], "FlareSolverrSettings")
        self.assertEqual(proxy["name"], "FlareSolverr")
        self.assertEqual(proxy["tags"], [7])
        fields = configure.fields_map(proxy)
        self.assertEqual(fields["host"], configure.FLARESOLVERR_HOST)
        self.assertIn("127.0.0.1", fields["host"])
        self.assertEqual(fields["requestTimeout"],
                         configure.FLARESOLVERR_REQUEST_TIMEOUT)
        self.assertEqual(set(fields), {"host", "requestTimeout"})

    def test_creates_tag_and_proxy_without_touching_indexers(self):
        transport = FakeProwlarrTransport(proxies=[])
        self.connect(transport)

        self.assertEqual(configure.ensure_flaresolverr("KEY", False),
                         "configured")

        self.assertEqual(transport.write_paths(), [
            configure.PROWLARR_TAG_PATH,
            configure.PROWLARR_INDEXER_PROXY_PATH + "?forceSave=true",
        ])
        proxy_body = transport.writes()[1][2]
        self.assertEqual(proxy_body["tags"], [1])
        for _, path, _ in transport.calls:
            self.assertNotIn("indexer/bulk", path)
            self.assertFalse(path.split("?")[0] == "/api/v1/indexer")

    def test_unchanged_when_tag_and_proxy_converged(self):
        transport = FakeProwlarrTransport(
            tags=[{"id": 7, "label": configure.FLARESOLVERR_TAG_LABEL}],
            proxies=[copy.deepcopy(FLARESOLVERR_PROXY_EXISTING)])
        self.connect(transport)

        self.assertEqual(configure.ensure_flaresolverr("KEY", False),
                         "unchanged")
        self.assertEqual(transport.writes(), [])

    def test_dry_run_writes_nothing_and_plans_tag_and_proxy(self):
        transport = FakeProwlarrTransport()
        self.connect(transport)

        self.assertEqual(configure.ensure_flaresolverr("KEY", True),
                         "would_configure")
        self.assertEqual(transport.writes(), [])

    def test_dry_run_reports_unchanged_when_converged(self):
        transport = FakeProwlarrTransport(
            tags=[{"id": 7, "label": configure.FLARESOLVERR_TAG_LABEL}],
            proxies=[copy.deepcopy(FLARESOLVERR_PROXY_EXISTING)])
        self.connect(transport)

        self.assertEqual(configure.ensure_flaresolverr("KEY", True),
                         "unchanged")
        self.assertEqual(transport.writes(), [])

    def test_drifted_proxy_is_updated_through_ensure(self):
        drifted = copy.deepcopy(FLARESOLVERR_PROXY_EXISTING)
        drifted["fields"] = [{"name": "host", "value": "http://old:8191"},
                             {"name": "requestTimeout", "value": 60}]
        transport = FakeProwlarrTransport(
            tags=[{"id": 7, "label": configure.FLARESOLVERR_TAG_LABEL}],
            proxies=[drifted])
        self.connect(transport)

        self.assertEqual(configure.ensure_flaresolverr("KEY", False),
                         "configured")
        puts = [call for call in transport.writes() if call[0] == "PUT"]
        self.assertEqual(len(puts), 1)
        self.assertIn("/api/v1/indexerproxy/9", puts[0][1])
        self.assertTrue(puts[0][1].endswith("?forceSave=true"))
        self.assertEqual(configure.fields_map(puts[0][2])["host"],
                         configure.FLARESOLVERR_HOST)

    def test_unavailable_flaresolverr_skips_without_writes(self):
        transport = FakeProwlarrTransport()
        self.connect(transport, healthy=False)

        self.assertEqual(configure.ensure_flaresolverr("KEY", False),
                         "unavailable")
        self.assertEqual(transport.calls, [])

    def test_probe_maps_statuses_and_errors(self):
        with unittest.mock.patch("urllib.request.urlopen",
                                 return_value=FakeHTTPResponse(200, "{}")):
            self.assertTrue(configure.probe_flaresolverr())
        with unittest.mock.patch("urllib.request.urlopen",
                                 return_value=FakeHTTPResponse(500, "boom")):
            self.assertFalse(configure.probe_flaresolverr())
        for error in (urllib.error.URLError("refused"),
                      TimeoutError("timed out")):
            with unittest.mock.patch("urllib.request.urlopen",
                                     side_effect=error):
                self.assertFalse(configure.probe_flaresolverr())

    def test_find_tag_id_matches_case_insensitively(self):
        tags = [{"id": 7, "label": "FlareSolverr"}]
        self.assertEqual(configure.find_tag_id(tags, "flaresolverr"), 7)
        self.assertIsNone(configure.find_tag_id(tags, "other"))
        self.assertIsNone(configure.find_tag_id([], "flaresolverr"))

    def test_tag_creation_that_does_not_persist_fails(self):
        class StubbornTags(FakeProwlarrTransport):
            def __call__(self, method, base, api_key, path, body=None):
                if method == "GET" and path.split("?")[0] == configure.PROWLARR_TAG_PATH:
                    return []
                return super().__call__(method, base, api_key, path, body)

        transport = StubbornTags()
        self.connect(transport)

        with self.assertRaises(SystemExit):
            configure.ensure_flaresolverr("KEY", False)


class MainQbitSkipTests(unittest.TestCase):
    """main() orchestration for --skip-qbit: every transport and service call is mocked."""

    def run_main(self, argv, stdin, client_side_effect=None):
        out = io.StringIO()
        with unittest.mock.patch.object(configure, "read_api_key", return_value="KEY"), \
             unittest.mock.patch.object(configure, "wait_healthy",
                                        return_value={"version": "1"}), \
             unittest.mock.patch.object(configure, "check_qbit_login") as login, \
             unittest.mock.patch.object(configure, "ensure_root_folder") as root, \
             unittest.mock.patch.object(configure, "ensure_download_client",
                                        side_effect=client_side_effect) as client, \
             unittest.mock.patch.object(configure, "ensure_prowlarr_app"), \
             unittest.mock.patch.object(configure, "ensure_bazarr",
                                        return_value="unchanged"), \
             unittest.mock.patch.object(configure, "ensure_flaresolverr",
                                        return_value="unchanged"), \
             unittest.mock.patch.object(configure, "ensure_seerr",
                                        return_value="skipped"), \
             unittest.mock.patch.object(configure.sys, "stdin", stdin), \
             contextlib.redirect_stdout(out):
            configure.main(argv)
        return ({"login": login, "root": root, "client": client},
                json.loads(out.getvalue()))

    def test_skip_qbit_skips_client_and_login(self):
        stdin = unittest.mock.Mock()
        mocks, summary = self.run_main(["--skip-qbit", "--skip-auth"], stdin)

        mocks["login"].assert_not_called()
        mocks["client"].assert_not_called()
        # The password is never read from stdin when the client is skipped
        stdin.readline.assert_not_called()
        # Root folders are independent of the download client
        self.assertEqual(mocks["root"].call_count, 2)
        self.assertEqual(summary["qbit"], "skipped")

    def test_without_skip_qbit_credentials_reach_the_client(self):
        stdin = unittest.mock.Mock()
        stdin.readline.return_value = "pw\n"
        mocks, summary = self.run_main(
            ["--qbit-host", "1.2.3.4", "--qbit-pass-stdin", "--skip-auth"], stdin)

        mocks["login"].assert_called_once_with("1.2.3.4", 8090, "admin", "pw")
        self.assertEqual(mocks["client"].call_count, 2)
        sonarr_call = mocks["client"].call_args_list[0][0]
        self.assertEqual(sonarr_call[:7],
                         ("sonarr", configure.SONARR_BASE, "KEY",
                          "1.2.3.4", 8090, "admin", "pw"))
        # The mock performs no writes, so the counters report no change
        self.assertEqual(summary["qbit"], "unchanged")

    def test_qbit_action_reflects_client_counters(self):
        stdin = unittest.mock.Mock()
        stdin.readline.return_value = "pw\n"

        def record_write(*args):
            args[-1]["created"] += 1

        _, summary = self.run_main(
            ["--qbit-host", "1.2.3.4", "--qbit-pass-stdin", "--skip-auth"],
            stdin, client_side_effect=record_write)
        self.assertEqual(summary["qbit"], "configured")

        _, dry_summary = self.run_main(
            ["--qbit-host", "1.2.3.4", "--qbit-pass-stdin",
             "--skip-auth", "--dry-run"],
            stdin, client_side_effect=record_write)
        self.assertEqual(dry_summary["qbit"], "would_configure")

    def test_missing_qbit_credentials_fail_without_the_flag(self):
        with self.assertRaises(SystemExit):
            self.run_main(["--skip-auth"], unittest.mock.Mock())

    def test_missing_pass_stdin_flag_fails_fast(self):
        with self.assertRaises(SystemExit):
            self.run_main(["--qbit-host", "1.2.3.4", "--skip-auth"],
                          unittest.mock.Mock())


class SeerrBuilderTests(unittest.TestCase):
    def test_sonarr_payload_shape(self):
        payload = configure.build_seerr_sonarr("SKEY", 1, "HD-1080p", "/data/media/Series")
        self.assertEqual(payload["name"], "Sonarr")
        self.assertEqual(payload["hostname"], "localhost")
        self.assertEqual(payload["port"], configure.SONARR_PORT)
        self.assertEqual(payload["apiKey"], "SKEY")
        self.assertIs(payload["useSsl"], False)
        self.assertTrue(payload["isDefault"])
        self.assertEqual(payload["activeProfileId"], 1)
        self.assertEqual(payload["activeDirectory"], "/data/media/Series")

    def test_radarr_payload_shape(self):
        payload = configure.build_seerr_radarr("RKEY", 2, "HD-1080p", "/data/media/Movies")
        self.assertEqual(payload["name"], "Radarr")
        self.assertEqual(payload["hostname"], "localhost")
        self.assertEqual(payload["port"], configure.RADARR_PORT)
        self.assertEqual(payload["apiKey"], "RKEY")
        self.assertIs(payload["useSsl"], False)
        self.assertTrue(payload["isDefault"])

    def test_jellyfin_payload_shape(self):
        payload = configure.build_seerr_jellyfin("10.9.9.9", 8096, "JKEY")
        self.assertEqual(payload["ip"], "10.9.9.9")
        self.assertEqual(payload["port"], 8096)
        self.assertEqual(payload["apiKey"], "JKEY")
        self.assertIs(payload["useSsl"], False)

    def test_parse_args_wires_seerr_flags(self):
        args = configure.parse_args(["--skip-qbit", "--skip-auth",
                                     "--jellyfin-host", "10.9.9.9",
                                     "--jellyfin-port", "8096"])
        self.assertTrue(args.skip_seerr is False)
        self.assertEqual(args.jellyfin_host, "10.9.9.9")
        self.assertEqual(args.jellyfin_port, 8096)
        self.assertTrue(configure.parse_args(["--skip-seerr"]).skip_seerr)
        with self.assertRaises(SystemExit):
            configure.parse_args(["--jellyfin-port", "0"])
        with self.assertRaises(SystemExit):
            configure.parse_args(["--jellyfin-host", "not-an-ip"])


class FakeSeerrTransport:
    """Path-routed Seerr fake: serves sonarr/radarr lists, records writes."""

    def __init__(self, sonarr=None, radarr=None):
        self.sonarr = [dict(s) for s in (sonarr or [])]
        self.radarr = [dict(r) for r in (radarr or [])]
        self.calls = []

    def __call__(self, method, path, api_key, body=None):
        self.calls.append((method, path, body))
        route = path.split("?")[0]
        if method == "GET":
            if route == configure.SEERR_SONARR_PATH:
                return copy.deepcopy(self.sonarr)
            if route == configure.SEERR_RADARR_PATH:
                return copy.deepcopy(self.radarr)
            return []
        if route == configure.SEERR_SONARR_PATH:
            self.sonarr.append(dict(body, id=len(self.sonarr)))
            return {"id": len(self.sonarr) - 1}
        if route == configure.SEERR_RADARR_PATH:
            self.radarr.append(dict(body, id=len(self.radarr)))
            return {"id": len(self.radarr) - 1}
        return {"ok": True}

    def writes(self):
        return [call for call in self.calls if call[0] != "GET"]


class SeerrEnsureTests(unittest.TestCase):
    def setUp(self):
        self._orig = configure.seerr_request
        self.addCleanup(setattr, configure, "seerr_request", self._orig)

    def test_sonarr_created_when_empty(self):
        transport = FakeSeerrTransport()
        with unittest.mock.patch.object(configure, "seerr_request", transport):
            action = configure.ensure_seerr_sonarr(
                "APIKEY", "SKEY", 1, "HD-1080p", "/data/media/Series", False)
        self.assertEqual(action, "created")
        self.assertEqual(len(transport.writes()), 1)
        self.assertEqual(transport.writes()[0][1], configure.SEERR_SONARR_PATH)

    def test_sonarr_unchanged_writes_nothing(self):
        existing = configure.build_seerr_sonarr("SKEY", 1, "HD-1080p",
                                                "/data/media/Series")
        existing["id"] = 0
        transport = FakeSeerrTransport(sonarr=[existing])
        with unittest.mock.patch.object(configure, "seerr_request", transport):
            action = configure.ensure_seerr_sonarr(
                "APIKEY", "SKEY", 1, "HD-1080p", "/data/media/Series", False)
        self.assertEqual(action, "unchanged")
        self.assertEqual(transport.writes(), [])

    def test_sonarr_drifted_is_updated(self):
        existing = configure.build_seerr_sonarr("OLD", 9, "Other", "/old")
        existing["id"] = 0
        transport = FakeSeerrTransport(sonarr=[existing])
        with unittest.mock.patch.object(configure, "seerr_request", transport):
            action = configure.ensure_seerr_sonarr(
                "APIKEY", "SKEY", 1, "HD-1080p", "/data/media/Series", False)
        self.assertEqual(action, "updated")
        puts = [c for c in transport.writes() if c[0] == "PUT"]
        self.assertEqual(len(puts), 1)
        self.assertIn("/api/v1/settings/sonarr/0", puts[0][1])

    def test_sonarr_dry_run_writes_nothing(self):
        transport = FakeSeerrTransport()
        with unittest.mock.patch.object(configure, "seerr_request", transport):
            action = configure.ensure_seerr_sonarr(
                "APIKEY", "SKEY", 1, "HD-1080p", "/data/media/Series", True)
        self.assertEqual(action, "would_configure")
        self.assertEqual(transport.writes(), [])

    def test_radarr_created_when_empty(self):
        transport = FakeSeerrTransport()
        with unittest.mock.patch.object(configure, "seerr_request", transport):
            action = configure.ensure_seerr_radarr(
                "APIKEY", "RKEY", 2, "HD-1080p", "/data/media/Movies", False)
        self.assertEqual(action, "created")
        self.assertEqual(len(transport.writes()), 1)

    def test_jellyfin_skipped_without_key(self):
        with unittest.mock.patch.object(configure, "seerr_request") as req:
            self.assertEqual(
                configure.ensure_seerr_jellyfin("APIKEY", "10.9.9.9", 8096,
                                                "", False),
                "skipped_no_key")
            req.assert_not_called()

    def test_jellyfin_posts_with_key(self):
        calls = []

        def fake(method, path, api_key, body=None):
            calls.append((method, path, body))
            return dict(body or {})

        with unittest.mock.patch.object(configure, "seerr_request",
                                        side_effect=fake):
            action = configure.ensure_seerr_jellyfin(
                "APIKEY", "10.9.9.9", 8096, "JKEY", False)
        self.assertEqual(action, "configured")
        self.assertEqual(calls[0][1], configure.SEERR_JELLYFIN_PATH)
        self.assertEqual(calls[0][2]["apiKey"], "JKEY")

    def test_jellyfin_dry_run_writes_nothing(self):
        with unittest.mock.patch.object(configure, "seerr_request") as req:
            action = configure.ensure_seerr_jellyfin(
                "APIKEY", "10.9.9.9", 8096, "JKEY", True)
        self.assertEqual(action, "would_configure")
        req.assert_not_called()

    def test_seerr_api_key_loads_from_settings_json(self):
        doc = {"main": {"apiKey": "SEERRKEY"}, "public": {"initialized": True}}
        path = write_temp(json.dumps(doc), suffix=".json")
        try:
            self.assertEqual(configure.read_seerr_api_key(path), "SEERRKEY")
        finally:
            os.unlink(path)

    def test_seerr_api_key_missing_fails(self):
        path = write_temp(json.dumps({"main": {}}), suffix=".json")
        try:
            with self.assertRaises(SystemExit):
                configure.read_seerr_api_key(path, timeout=1)
        finally:
            os.unlink(path)

    def test_summary_carries_seerr(self):
        summary = configure.build_summary(
            {"sonarr": "4.x"},
            {"created": 0, "updated": 0, "unchanged": 0},
            {"created": 0, "updated": 0, "unchanged": 0},
            {"created": 0, "updated": 0, "unchanged": 0},
            "linked", False,
            {"sonarr": "updated"},
            "configured", "configured", "configured")
        self.assertEqual(summary["seerr"], "configured")


if __name__ == "__main__":
    unittest.main(verbosity=2)
