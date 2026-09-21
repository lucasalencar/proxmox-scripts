#!/usr/bin/env python3
"""Unit tests for caddy/generate_caddyfile_core.py.

Self-contained: bootstraps its own sys.path, stdlib only, no Proxmox needed.
Interactive prompts are exercised with a fake asker, never real stdin.
"""

import io
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import generate_caddyfile_core as core

DOMAIN = "marx.home"

SAVED_MULTI = """http://bazarr.marx.home {
    reverse_proxy 10.0.0.5:6767
}

http://radarr.marx.home {
    reverse_proxy 10.0.0.5:7878
}

http://sonarr.marx.home {
    reverse_proxy 10.0.0.5:8989
}

http://prowlarr.marx.home {
    reverse_proxy 10.0.0.5:9696
}

"""


class Asker:
    """Replays canned answers, records prompts, fails on unexpected prompt."""

    def __init__(self, answers):
        self.answers = list(answers)
        self.prompts = []

    def __call__(self, prompt):
        self.prompts.append(prompt)
        if not self.answers:
            raise AssertionError("unexpected prompt: %r" % (prompt,))
        return self.answers.pop(0)


def make_guest(name, ip, ports, gid="105", gtype="ct"):
    return core.Guest(name=name, gid=gid, gtype=gtype, ip=ip, ports=list(ports))


def resolve(guests, saved_text="", answers=()):
    asker = Asker(answers)
    logs = []
    routes, tls = core.parse_saved_caddyfile(saved_text, DOMAIN)
    entries, tls = core.resolve_guests(
        guests, routes, tls, DOMAIN, asker, logs.append
    )
    text, warnings = core.render_caddyfile(entries, routes, tls, DOMAIN)
    return asker, logs, entries, text, warnings


class ParseSavedTests(unittest.TestCase):
    def test_http_and_https_blocks_keep_file_order(self):
        text = (
            "http://bazarr.marx.home {\n"
            "    reverse_proxy 10.0.0.5:6767\n"
            "}\n"
            "\n"
            "nextcloud.marx.home {\n"
            "    tls internal\n"
            "    reverse_proxy 10.0.0.6:80\n"
            "}\n"
        )
        routes, tls = core.parse_saved_caddyfile(text, DOMAIN)
        self.assertEqual(list(routes), ["bazarr", "nextcloud"])
        self.assertEqual(routes["bazarr"], core.SavedRoute("bazarr", "10.0.0.5", 6767))
        self.assertEqual(routes["nextcloud"], core.SavedRoute("nextcloud", "10.0.0.6", 80))
        self.assertEqual(tls, {"bazarr": "http", "nextcloud": "https"})

    def test_ignores_unrelated_lines(self):
        routes, tls = core.parse_saved_caddyfile(
            "# comment\n\nhttp://myapp.marx.home {\n"
            "    reverse_proxy 10.9.9.9:1234\n"
            "}\n",
            DOMAIN,
        )
        self.assertEqual(list(routes), ["myapp"])
        self.assertEqual(tls, {"myapp": "http"})

    def test_reverse_proxy_without_block_is_ignored(self):
        routes, tls = core.parse_saved_caddyfile(
            "    reverse_proxy 10.9.9.9:1234\n", DOMAIN
        )
        self.assertEqual(routes, {})
        self.assertEqual(tls, {})

    def test_block_without_reverse_proxy_has_tls_only(self):
        routes, tls = core.parse_saved_caddyfile(
            "http://lonely.marx.home {\n}\n", DOMAIN
        )
        self.assertEqual(routes, {})
        self.assertEqual(tls, {"lonely": "http"})


class HelperTests(unittest.TestCase):
    def test_saved_services_for_ip_excludes_self(self):
        routes, _ = core.parse_saved_caddyfile(SAVED_MULTI, DOMAIN)
        self.assertEqual(
            core.saved_services_for_ip(routes, "10.0.0.5", "starr"),
            ["bazarr", "radarr", "sonarr", "prowlarr"],
        )
        self.assertNotIn(
            "bazarr", core.saved_services_for_ip(routes, "10.0.0.5", "bazarr")
        )
        self.assertEqual(core.saved_services_for_ip(routes, "10.9.9.9", "x"), [])

    def test_suggest_subdomain_for_port_needs_unique_match(self):
        routes, _ = core.parse_saved_caddyfile(SAVED_MULTI, DOMAIN)
        self.assertEqual(core.suggest_subdomain_for_port(routes, 7878), "radarr")
        self.assertIsNone(core.suggest_subdomain_for_port(routes, 9999))

    def test_suggest_subdomain_ambiguous_returns_none(self):
        routes = {
            "a": core.SavedRoute("a", "10.0.0.5", 8080),
            "b": core.SavedRoute("b", "10.0.0.6", 8080),
        }
        self.assertIsNone(core.suggest_subdomain_for_port(routes, 8080))

    def test_default_tls(self):
        self.assertEqual(core.default_tls_for("nextcloud"), "https")
        self.assertEqual(core.default_tls_for("nextcloudpi"), "https")
        self.assertEqual(core.default_tls_for("jellyfin"), "http")

    def test_suggest_port(self):
        self.assertEqual(core.suggest_port([]), 80)
        self.assertEqual(core.suggest_port([8080]), 8080)
        self.assertEqual(core.suggest_port([443, 8080]), 443)
        self.assertEqual(core.suggest_port([80, 443]), 80)

    def test_sanitize_subdomain(self):
        self.assertEqual(core.sanitize_subdomain("  Radarr \n"), "Radarr")
        self.assertEqual(core.sanitize_subdomain("foo.bar"), "foo")
        self.assertEqual(core.sanitize_subdomain("   "), "")


class PromptTlsTests(unittest.TestCase):
    def test_saved_tls_short_circuits_without_asking(self):
        asker = Asker(["y"])
        logs = []
        self.assertEqual(
            core.prompt_tls("bazarr", {"bazarr": "http"}, DOMAIN, asker, logs.append),
            "http",
        )
        self.assertEqual(asker.prompts, [])
        self.assertTrue(any("saved TLS" in line for line in logs))

    def test_yes_no_empty_answers(self):
        self.assertEqual(
            core.prompt_tls("j", {}, DOMAIN, Asker(["y"]), lambda line: None), "https"
        )
        self.assertEqual(
            core.prompt_tls("j", {}, DOMAIN, Asker(["n"]), lambda line: None), "http"
        )
        self.assertEqual(
            core.prompt_tls("j", {}, DOMAIN, Asker([""]), lambda line: None), "http"
        )
        self.assertEqual(
            core.prompt_tls(
                "nextcloud", {}, DOMAIN, Asker([""]), lambda line: None
            ),
            "https",
        )
        self.assertEqual(
            core.prompt_tls("j", {}, DOMAIN, Asker(["garbage"]), lambda line: None),
            "http",
        )


class ResolveTests(unittest.TestCase):
    def test_saved_single_service_reused_without_prompting(self):
        asker, logs, entries, text, warnings = resolve(
            [make_guest("jellyfin", "10.0.0.7", [8096], gid="107")],
            "http://jellyfin.marx.home {\n"
            "    reverse_proxy 10.0.0.7:8096\n"
            "}\n",
            [],
        )
        self.assertEqual(asker.prompts, [])
        self.assertEqual(
            entries, [core.Entry("jellyfin", "10.0.0.7", 8096, "http")]
        )
        self.assertIn("reverse_proxy 10.0.0.7:8096", text)

    def test_new_single_service_prompts_port_and_tls(self):
        asker, _, entries, text, _ = resolve(
            [make_guest("jellyfin", "10.0.0.7", [8096], gid="107")], "", ["", "n"]
        )
        self.assertEqual(len(asker.prompts), 2)
        self.assertIn("Port for jellyfin.marx.home", asker.prompts[0])
        self.assertIn("HTTPS (tls internal) for jellyfin.marx.home", asker.prompts[1])
        self.assertEqual(
            entries, [core.Entry("jellyfin", "10.0.0.7", 8096, "http")]
        )
        self.assertIn("http://jellyfin.marx.home {", text)

    def test_invalid_port_falls_back_to_suggested(self):
        asker, logs, entries, _, _ = resolve(
            [make_guest("jellyfin", "10.0.0.7", [8096], gid="107")],
            "",
            ["abc", "n"],
        )
        self.assertEqual(entries[0].port, 8096)
        self.assertTrue(any("Invalid port" in line for line in logs))

    def test_saved_multi_service_reattached_by_ip(self):
        asker, _, entries, text, _ = resolve(
            [make_guest("starr", "10.0.0.5", [6767, 7878, 8989, 9696])],
            SAVED_MULTI,
            [],
        )
        self.assertEqual(asker.prompts, [])
        self.assertEqual(
            [entry.name for entry in entries],
            ["bazarr", "radarr", "sonarr", "prowlarr"],
        )
        self.assertNotIn("starr.marx.home", text)

    def test_multi_service_flow(self):
        asker, _, entries, text, _ = resolve(
            [make_guest("starr", "10.0.0.5", [6767, 7878, 8989, 9696])],
            "",
            ["y", "bazarr", "n", "radarr", "n", "sonarr", "n", "prowlarr", "n"],
        )
        self.assertEqual(
            [(entry.name, entry.port) for entry in entries],
            [("bazarr", 6767), ("radarr", 7878), ("sonarr", 8989), ("prowlarr", 9696)],
        )
        for name in ("bazarr", "radarr", "sonarr", "prowlarr"):
            self.assertIn(name + ".marx.home", text)
        self.assertNotIn("starr.marx.home", text)

    def test_multi_service_all_skipped_falls_back_to_single(self):
        asker, logs, entries, text, _ = resolve(
            [make_guest("starr", "10.0.0.5", [6767, 9696])],
            "",
            ["y", "", "", "", "n"],
        )
        self.assertEqual([entry.name for entry in entries], ["starr"])
        self.assertEqual(entries[0].port, 6767)
        self.assertIn("starr.marx.home", text)
        self.assertTrue(any("falling back" in line for line in logs))

    def test_nextcloud_defaults_to_https(self):
        _, _, entries, text, _ = resolve(
            [make_guest("nextcloud", "10.0.0.6", [80])], "", ["", ""]
        )
        self.assertEqual(entries[0].tls, "https")
        self.assertIn("nextcloud.marx.home {\n    tls internal", text)


class RenderTests(unittest.TestCase):
    def test_guest_entries_come_first_then_orphans(self):
        routes, tls = core.parse_saved_caddyfile(
            "http://myapp.marx.home {\n"
            "    reverse_proxy 10.9.9.9:1234\n"
            "}\n",
            DOMAIN,
        )
        entries = [core.Entry("starr", "10.0.0.5", 8989, "http")]
        tls = dict(tls)
        text, warnings = core.render_caddyfile(entries, routes, tls, DOMAIN)
        self.assertLess(
            text.index("starr.marx.home"), text.index("myapp.marx.home")
        )
        self.assertIn("reverse_proxy 10.0.0.5:8989", text)
        self.assertIn("reverse_proxy 10.9.9.9:1234", text)
        self.assertTrue(
            any("Preserving unmanaged block myapp.marx.home" in w for w in warnings)
        )

    def test_exact_block_format(self):
        text, _ = core.render_caddyfile(
            [core.Entry("nextcloud", "10.0.0.6", 80, "https")], {}, {}, DOMAIN
        )
        self.assertEqual(
            text,
            "nextcloud.marx.home {\n"
            "    tls internal\n"
            "    reverse_proxy 10.0.0.6:80\n"
            "}\n"
            "\n",
        )
        text, _ = core.render_caddyfile(
            [core.Entry("jellyfin", "10.0.0.7", 8096, "http")], {}, {}, DOMAIN
        )
        self.assertEqual(
            text,
            "http://jellyfin.marx.home {\n"
            "    reverse_proxy 10.0.0.7:8096\n"
            "}\n"
            "\n",
        )

    def test_empty_renders_empty(self):
        text, warnings = core.render_caddyfile([], {}, {}, DOMAIN)
        self.assertEqual(text, "")
        self.assertEqual(warnings, [])


class MainTests(unittest.TestCase):
    def test_main_end_to_end_multi_service(self):
        import json
        import tempfile

        guests = [
            {
                "name": "starr",
                "gid": "105",
                "gtype": "ct",
                "ip": "10.0.0.5",
                "ports": [6767, 7878, 8989, 9696],
            }
        ]
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(guests, handle)
            guests_path = handle.name
        self.addCleanup(os.unlink, guests_path)

        argv = [
            "generate_caddyfile_core.py",
            "--domain",
            DOMAIN,
            "--guests-file",
            guests_path,
        ]
        stdin = io.StringIO("y\nbazarr\nn\nradarr\nn\nsonarr\nn\nprowlarr\nn\n")
        stdout = io.StringIO()
        old_argv, old_stdin = sys.argv, sys.stdin
        try:
            sys.argv = argv
            sys.stdin = stdin
            with core.redirect_stdout(stdout):
                status = core.main()
        finally:
            sys.argv, sys.stdin = old_argv, old_stdin
        self.assertEqual(status, 0)
        out = stdout.getvalue()
        self.assertIn("bazarr.marx.home", out)
        self.assertIn("reverse_proxy 10.0.0.5:6767", out)
        self.assertNotIn("starr.marx.home", out)

    def test_main_rejects_invalid_guests_file(self):
        old_argv = sys.argv
        try:
            sys.argv = [
                "generate_caddyfile_core.py",
                "--guests-file",
                "/nonexistent/guests.json",
            ]
            with core.redirect_stderr(io.StringIO()):
                self.assertNotEqual(core.main(), 0)
        finally:
            sys.argv = old_argv

    def test_main_treats_eof_as_empty_answer(self):
        import json
        import tempfile

        guests = [
            {
                "name": "jellyfin",
                "gid": "107",
                "gtype": "ct",
                "ip": "10.0.0.7",
                "ports": [8096],
            }
        ]
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(guests, handle)
            guests_path = handle.name
        self.addCleanup(os.unlink, guests_path)

        old_argv, old_stdin = sys.argv, sys.stdin
        try:
            sys.argv = ["generate_caddyfile_core.py", "--guests-file", guests_path]
            sys.stdin = io.StringIO("")
            stdout = io.StringIO()
            with core.redirect_stdout(stdout):
                status = core.main()
        finally:
            sys.argv, sys.stdin = old_argv, old_stdin
        self.assertEqual(status, 0)
        self.assertIn("reverse_proxy 10.0.0.7:8096", stdout.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
