#!/usr/bin/env python3
"""Unit tests for caddy/generate_caddyfile_core.py (state.json design).

Self-contained: bootstraps its own sys.path, stdlib only, no Proxmox needed.
Interactive prompts are exercised with a fake asker, never real stdin.
"""

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import generate_caddyfile_core as core

DOMAIN = "marx.home"


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


def make_entry(ip, port, tls="http", source="auto", guest=None):
    return {"ip": ip, "port": port, "tls": tls, "source": source,
            "guest": guest}


def make_state(entries, domain=DOMAIN):
    return {"version": 1, "domain": domain, "entries": dict(entries)}


def merge(guests, state=None, answers=()):
    asker = Asker(answers)
    logs = []
    current = state if state is not None else core.empty_state(DOMAIN)
    touched = core.merge_guests(guests, current, DOMAIN, asker, logs.append)
    text, warnings = core.render_state(current, DOMAIN, touched)
    return asker, logs, current, text, warnings


class StateTests(unittest.TestCase):
    def test_empty_state(self):
        state = core.empty_state(DOMAIN)
        self.assertEqual(
            state, {"version": 1, "domain": DOMAIN, "entries": {}}
        )

    def test_save_and_load_roundtrip(self):
        state = make_state({"jellyfin": make_entry("10.0.0.7", 8096)})
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            path = handle.name
        self.addCleanup(os.unlink, path)
        core.save_state(state, path)
        self.assertEqual(core.load_state(path), state)

    def test_load_missing_file_raises(self):
        with self.assertRaises(FileNotFoundError):
            core.load_state("/nonexistent/state.json")

    def test_load_rejects_bad_version(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump({"version": 99, "domain": DOMAIN, "entries": {}}, handle)
            path = handle.name
        self.addCleanup(os.unlink, path)
        with self.assertRaises(ValueError):
            core.load_state(path)

    def test_load_rejects_malformed_content(self):
        for content in ("{not json", '{"version": 1}'):
            with tempfile.NamedTemporaryFile(
                "w", suffix=".json", delete=False
            ) as handle:
                handle.write(content)
                path = handle.name
            self.addCleanup(os.unlink, path)
            with self.assertRaises(ValueError):
                core.load_state(path)


class HelperTests(unittest.TestCase):
    def test_services_for_ip_excludes_self_and_claimed(self):
        entries = {
            "bazarr": make_entry("10.0.0.5", 6767),
            "radarr": make_entry("10.0.0.5", 7878),
        }
        self.assertEqual(
            core.services_for_ip(entries, "10.0.0.5", "starr", set()),
            ["bazarr", "radarr"],
        )
        self.assertNotIn(
            "bazarr",
            core.services_for_ip(entries, "10.0.0.5", "bazarr", set()),
        )
        self.assertEqual(
            core.services_for_ip(entries, "10.0.0.5", "starr", {"bazarr"}),
            ["radarr"],
        )
        self.assertEqual(
            core.services_for_ip(entries, "10.9.9.9", "x", set()), []
        )

    def test_suggest_subdomain_needs_unique_unclaimed_match(self):
        entries = {
            "radarr": make_entry("10.0.0.5", 7878),
            "a": make_entry("10.0.0.5", 8080),
            "b": make_entry("10.0.0.6", 8080),
        }
        self.assertEqual(
            core.suggest_subdomain(entries, 7878, set()), "radarr"
        )
        self.assertIsNone(core.suggest_subdomain(entries, 7878, {"radarr"}))
        self.assertIsNone(core.suggest_subdomain(entries, 8080, set()))
        self.assertIsNone(core.suggest_subdomain(entries, 9999, set()))

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
            core.prompt_tls("bazarr", "http", DOMAIN, asker, logs.append),
            "http",
        )
        self.assertEqual(asker.prompts, [])
        self.assertTrue(any("saved TLS" in line for line in logs))

    def test_yes_no_empty_answers(self):
        self.assertEqual(
            core.prompt_tls("j", None, DOMAIN, Asker(["y"]), lambda line: None),
            "https",
        )
        self.assertEqual(
            core.prompt_tls("j", None, DOMAIN, Asker(["n"]), lambda line: None),
            "http",
        )
        self.assertEqual(
            core.prompt_tls("j", None, DOMAIN, Asker([""]), lambda line: None),
            "http",
        )
        self.assertEqual(
            core.prompt_tls(
                "nextcloud", None, DOMAIN, Asker([""]), lambda line: None
            ),
            "https",
        )
        self.assertEqual(
            core.prompt_tls(
                "j", None, DOMAIN, Asker(["garbage"]), lambda line: None
            ),
            "http",
        )


class MergeTests(unittest.TestCase):
    def test_new_single_service_prompts_port_and_tls(self):
        asker, _, state, text, _ = merge(
            [make_guest("jellyfin", "10.0.0.7", [8096], gid="107")],
            answers=["", "n"],
        )
        self.assertEqual(len(asker.prompts), 2)
        self.assertIn("Port for jellyfin.marx.home", asker.prompts[0])
        self.assertIn("HTTPS (tls internal) for jellyfin.marx.home", asker.prompts[1])
        self.assertEqual(
            state["entries"]["jellyfin"],
            make_entry("10.0.0.7", 8096, guest="jellyfin"),
        )
        self.assertIn("http://jellyfin.marx.home {", text)

    def test_known_guest_reused_without_prompting(self):
        state = make_state(
            {"jellyfin": make_entry("10.0.0.7", 8096, guest="jellyfin")}
        )
        asker, _, state, text, _ = merge(
            [make_guest("jellyfin", "10.0.0.7", [8096], gid="107")],
            state=state,
            answers=[],
        )
        self.assertEqual(asker.prompts, [])
        self.assertIn("reverse_proxy 10.0.0.7:8096", text)

    def test_known_guest_ip_change_updates_silently(self):
        state = make_state(
            {"jellyfin": make_entry("10.0.0.7", 8096, guest="jellyfin")}
        )
        asker, _, state, text, _ = merge(
            [make_guest("jellyfin", "10.0.0.8", [9000], gid="107")],
            state=state,
            answers=[],
        )
        self.assertEqual(asker.prompts, [])
        self.assertEqual(state["entries"]["jellyfin"]["ip"], "10.0.0.8")
        self.assertEqual(state["entries"]["jellyfin"]["port"], 8096)
        self.assertIn("reverse_proxy 10.0.0.8:8096", text)

    def test_invalid_port_falls_back_to_suggested(self):
        asker, logs, state, _, _ = merge(
            [make_guest("jellyfin", "10.0.0.7", [8096], gid="107")],
            answers=["abc", "n"],
        )
        self.assertEqual(state["entries"]["jellyfin"]["port"], 8096)
        self.assertTrue(any("Invalid port" in line for line in logs))

    def test_non_ascii_digit_port_falls_back(self):
        _, logs, state, _, _ = merge(
            [make_guest("jellyfin", "10.0.0.7", [8096], gid="107")],
            answers=["²", "n"],
        )
        self.assertEqual(state["entries"]["jellyfin"]["port"], 8096)
        self.assertTrue(any("Invalid port" in line for line in logs))

    def test_out_of_range_ports_fall_back(self):
        for bad in ("0", "99999"):
            _, logs, state, _, _ = merge(
                [make_guest("jellyfin", "10.0.0.7", [8096], gid="107")],
                answers=[bad, "n"],
            )
            self.assertEqual(state["entries"]["jellyfin"]["port"], 8096)
            self.assertTrue(any("Invalid port" in line for line in logs))

    def test_multi_service_reattached_by_ip(self):
        state = make_state(
            {
                "bazarr": make_entry("10.0.0.5", 6767, guest=None),
                "radarr": make_entry("10.0.0.5", 7878, guest=None),
                "sonarr": make_entry("10.0.0.5", 8989, guest=None),
                "prowlarr": make_entry("10.0.0.5", 9696, guest=None),
            }
        )
        asker, _, state, text, _ = merge(
            [make_guest("starr", "10.0.0.5", [6767, 7878, 8989, 9696])],
            state=state,
            answers=[],
        )
        self.assertEqual(asker.prompts, [])
        self.assertEqual(
            sorted(state["entries"]), ["bazarr", "prowlarr", "radarr", "sonarr"]
        )
        self.assertNotIn("starr.marx.home", text)

    def test_multi_service_flow(self):
        asker, _, state, text, _ = merge(
            [make_guest("starr", "10.0.0.5", [6767, 7878, 8989, 9696])],
            answers=["y", "bazarr", "n", "radarr", "n", "sonarr", "n",
                     "prowlarr", "n"],
        )
        self.assertEqual(
            [(name, state["entries"][name]["port"]) for name in state["entries"]],
            [("bazarr", 6767), ("radarr", 7878), ("sonarr", 8989),
             ("prowlarr", 9696)],
        )
        for name in ("bazarr", "radarr", "sonarr", "prowlarr"):
            self.assertIn(name + ".marx.home", text)
        self.assertNotIn("starr.marx.home", text)

    def test_multi_service_all_skipped_falls_back_to_single(self):
        asker, logs, state, text, _ = merge(
            [make_guest("starr", "10.0.0.5", [6767, 9696])],
            answers=["y", "", "", "", "n"],
        )
        self.assertEqual(sorted(state["entries"]), ["starr"])
        self.assertEqual(state["entries"]["starr"]["port"], 6767)
        self.assertIn("starr.marx.home", text)
        self.assertTrue(any("falling back" in line for line in logs))

    def test_multi_service_uses_port_suggestion_as_default(self):
        asker, _, state, text, _ = merge(
            [make_guest("starr", "10.0.0.5", [6767, 7878])],
            state=make_state(
                {"oldapp": make_entry("10.9.9.9", 6767, guest=None)}
            ),
            answers=["y", "", "svc2", "n"],
        )
        self.assertTrue(
            any("[default: oldapp]" in prompt for prompt in asker.prompts)
        )
        self.assertEqual(state["entries"]["oldapp"]["ip"], "10.0.0.5")
        self.assertEqual(state["entries"]["oldapp"]["port"], 6767)
        self.assertIn("reverse_proxy 10.0.0.5:6767", text)

    def test_two_guests_sharing_ip_each_get_own_block(self):
        asker, _, state, text, _ = merge(
            [
                make_guest("g1", "10.0.0.9", [8080], gid="201"),
                make_guest("g2", "10.0.0.9", [9090], gid="202"),
            ],
            answers=["", "n", "", "n"],
        )
        self.assertEqual(len(asker.prompts), 4)
        self.assertEqual(sorted(state["entries"]), ["g1", "g2"])
        self.assertIn("reverse_proxy 10.0.0.9:8080", text)
        self.assertIn("reverse_proxy 10.0.0.9:9090", text)

    def test_ip_swap_new_occupant_not_swallowed(self):
        asker, _, state, text, _ = merge(
            [
                make_guest("x", "10.0.0.6", [8080], gid="201"),
                make_guest("y", "10.0.0.5", [9090], gid="202"),
            ],
            state=make_state(
                {"x": make_entry("10.0.0.5", 8080, guest="x")}
            ),
            answers=["", "n"],
        )
        self.assertEqual(state["entries"]["x"]["ip"], "10.0.0.6")
        self.assertEqual(state["entries"]["y"]["ip"], "10.0.0.5")
        self.assertEqual(state["entries"]["y"]["port"], 9090)
        self.assertIn("reverse_proxy 10.0.0.6:8080", text)
        self.assertIn("reverse_proxy 10.0.0.5:9090", text)

    def test_duplicate_subdomain_no_extra_block(self):
        asker, logs, state, text, _ = merge(
            [
                make_guest("g1", "10.0.0.5", [8080], gid="201"),
                make_guest("g2", "10.0.0.6", [9090, 9091], gid="202"),
            ],
            answers=["", "n", "y", "g1", "svc", "n"],
        )
        self.assertEqual(
            [(n, state["entries"][n]["ip"], state["entries"][n]["port"])
             for n in state["entries"]],
            [("g1", "10.0.0.6", 9090), ("svc", "10.0.0.6", 9091)],
        )
        self.assertNotIn("g2.marx.home", text)
        self.assertFalse(any("falling back" in line for line in logs))

    def test_nextcloud_defaults_to_https(self):
        _, _, state, text, _ = merge(
            [make_guest("nextcloud", "10.0.0.6", [80])], answers=["", ""]
        )
        self.assertEqual(state["entries"]["nextcloud"]["tls"], "https")
        self.assertIn("nextcloud.marx.home {\n    tls internal", text)

    def test_guest_without_detected_ports_defaults_to_80(self):
        _, _, state, text, _ = merge(
            [make_guest("jellyfin", "10.0.0.7", [], gid="107")],
            answers=["", "n"],
        )
        self.assertEqual(state["entries"]["jellyfin"]["port"], 80)
        self.assertIn("reverse_proxy 10.0.0.7:80", text)

    def test_gone_guest_entry_preserved(self):
        asker, _, state, text, warnings = merge(
            [make_guest("starr", "10.0.0.5", [8989])],
            state=make_state(
                {
                    "myapp": make_entry("10.9.9.9", 1234, guest="vanished"),
                    "starr": make_entry("10.0.0.5", 8989, guest="starr"),
                }
            ),
            answers=[],
        )
        self.assertEqual(asker.prompts, [])
        self.assertIn("myapp.marx.home", text)
        self.assertIn("reverse_proxy 10.9.9.9:1234", text)
        self.assertTrue(
            any("Preserving unmanaged block myapp.marx.home" in w
                for w in warnings)
        )


class RenderTests(unittest.TestCase):
    def test_exact_block_format_with_header(self):
        state = make_state(
            {"nextcloud": make_entry("10.0.0.6", 80, tls="https",
                                     guest="nextcloud")}
        )
        text, _ = core.render_state(state, DOMAIN, {"nextcloud"})
        self.assertEqual(
            text,
            "# Generated by caddy/generate-caddyfile.sh — do not edit.\n"
            "# Source of truth: caddy/state.json\n"
            "\n"
            "nextcloud.marx.home {\n"
            "    tls internal\n"
            "    reverse_proxy 10.0.0.6:80\n"
            "}\n"
            "\n",
        )
        state = make_state(
            {"jellyfin": make_entry("10.0.0.7", 8096, guest="jellyfin")}
        )
        text, _ = core.render_state(state, DOMAIN, {"jellyfin"})
        self.assertIn("http://jellyfin.marx.home {\n", text)
        self.assertIn("    reverse_proxy 10.0.0.7:8096\n", text)

    def test_insertion_order_preserved(self):
        state = make_state(
            {
                "myapp": make_entry("10.9.9.9", 1234, guest=None),
                "starr": make_entry("10.0.0.5", 8989, guest="starr"),
            }
        )
        text, _ = core.render_state(state, DOMAIN, {"starr"})
        self.assertLess(text.index("myapp.marx.home"), text.index("starr.marx.home"))

    def test_empty_renders_header_only(self):
        text, warnings = core.render_state(
            core.empty_state(DOMAIN), DOMAIN, set()
        )
        self.assertTrue(text.startswith("# Generated by"))
        self.assertEqual(warnings, [])


class MainTests(unittest.TestCase):
    def write_guests(self, guests):
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(guests, handle)
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def write_state(self, state):
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(state, handle)
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def test_sync_writes_state_and_stdout_stays_empty(self):
        guests_path = self.write_guests(
            [
                {
                    "name": "starr",
                    "gid": "105",
                    "gtype": "ct",
                    "ip": "10.0.0.5",
                    "ports": [6767, 7878, 8989, 9696],
                }
            ]
        )
        state_path = tempfile.mktemp(suffix=".json")
        self.addCleanup(
            lambda: os.unlink(state_path) if os.path.exists(state_path) else None
        )
        old_argv, old_stdin = sys.argv, sys.stdin
        try:
            sys.argv = [
                "generate_caddyfile_core.py",
                "sync",
                "--domain",
                DOMAIN,
                "--state",
                state_path,
                "--guests-file",
                guests_path,
            ]
            sys.stdin = io.StringIO(
                "y\nbazarr\nn\nradarr\nn\nsonarr\nn\nprowlarr\nn\n"
            )
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                status = core.main()
        finally:
            sys.argv, sys.stdin = old_argv, old_stdin
        self.assertEqual(status, 0)
        self.assertEqual(stdout.getvalue(), "")
        state = core.load_state(state_path)
        self.assertEqual(
            sorted(state["entries"]), ["bazarr", "prowlarr", "radarr", "sonarr"]
        )

    def test_second_sync_is_idempotent_without_input(self):
        guests = [
            {
                "name": "jellyfin",
                "gid": "107",
                "gtype": "ct",
                "ip": "10.0.0.7",
                "ports": [8096],
            }
        ]
        guests_path = self.write_guests(guests)
        state_path = tempfile.mktemp(suffix=".json")
        self.addCleanup(
            lambda: os.unlink(state_path) if os.path.exists(state_path) else None
        )
        old_argv, old_stdin = sys.argv, sys.stdin
        try:
            argv = [
                "generate_caddyfile_core.py",
                "sync",
                "--domain",
                DOMAIN,
                "--state",
                state_path,
                "--guests-file",
                guests_path,
            ]
            sys.argv = argv
            sys.stdin = io.StringIO("\n\n")
            with redirect_stdout(io.StringIO()):
                self.assertEqual(core.main(), 0)
            before = core.load_state(state_path)
            sys.stdin = io.StringIO("")
            with redirect_stdout(io.StringIO()):
                self.assertEqual(core.main(), 0)
            after = core.load_state(state_path)
        finally:
            sys.argv, sys.stdin = old_argv, old_stdin
        self.assertEqual(before, after)

    def test_render_stdout_is_pure_caddyfile(self):
        state_path = self.write_state(
            make_state(
                {"jellyfin": make_entry("10.0.0.7", 8096, guest="jellyfin")}
            )
        )
        old_argv = sys.argv
        try:
            sys.argv = [
                "generate_caddyfile_core.py",
                "render",
                "--state",
                state_path,
            ]
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                status = core.main()
        finally:
            sys.argv = old_argv
        self.assertEqual(status, 0)
        out = stdout.getvalue()
        self.assertIn("reverse_proxy 10.0.0.7:8096", out)
        self.assertNotIn("Subdomain for", out)
        self.assertNotIn("saved port", out)

    def test_sync_treats_eof_as_empty_answer(self):
        guests_path = self.write_guests(
            [
                {
                    "name": "jellyfin",
                    "gid": "107",
                    "gtype": "ct",
                    "ip": "10.0.0.7",
                    "ports": [8096],
                }
            ]
        )
        state_path = tempfile.mktemp(suffix=".json")
        self.addCleanup(
            lambda: os.unlink(state_path) if os.path.exists(state_path) else None
        )
        old_argv, old_stdin = sys.argv, sys.stdin
        try:
            sys.argv = [
                "generate_caddyfile_core.py",
                "sync",
                "--domain",
                DOMAIN,
                "--state",
                state_path,
                "--guests-file",
                guests_path,
            ]
            sys.stdin = io.StringIO("")
            with redirect_stdout(io.StringIO()):
                status = core.main()
        finally:
            sys.argv, sys.stdin = old_argv, old_stdin
        self.assertEqual(status, 0)
        state = core.load_state(state_path)
        self.assertEqual(state["entries"]["jellyfin"]["port"], 8096)

    def test_sync_rejects_invalid_guests_file(self):
        state_path = tempfile.mktemp(suffix=".json")
        self.addCleanup(
            lambda: os.unlink(state_path) if os.path.exists(state_path) else None
        )
        old_argv = sys.argv
        try:
            sys.argv = [
                "generate_caddyfile_core.py",
                "sync",
                "--domain",
                DOMAIN,
                "--state",
                state_path,
                "--guests-file",
                "/nonexistent/guests.json",
            ]
            stdout, stderr = io.StringIO(), io.StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                self.assertEqual(core.main(), 1)
        finally:
            sys.argv = old_argv
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("Error", stderr.getvalue())

    def test_sync_rejects_malformed_guests_file(self):
        for content in ("{not json", '[{"name": "x"}]'):
            with tempfile.NamedTemporaryFile(
                "w", suffix=".json", delete=False
            ) as handle:
                handle.write(content)
                guests_path = handle.name
            self.addCleanup(os.unlink, guests_path)
            state_path = tempfile.mktemp(suffix=".json")
            self.addCleanup(
                lambda p=state_path: os.unlink(p) if os.path.exists(p) else None
            )
            old_argv = sys.argv
            try:
                sys.argv = [
                    "generate_caddyfile_core.py",
                    "sync",
                    "--domain",
                    DOMAIN,
                    "--state",
                    state_path,
                    "--guests-file",
                    guests_path,
                ]
                stdout, stderr = io.StringIO(), io.StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    self.assertEqual(core.main(), 1)
            finally:
                sys.argv = old_argv
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("Error", stderr.getvalue())

    def test_render_rejects_missing_state(self):
        old_argv = sys.argv
        try:
            sys.argv = [
                "generate_caddyfile_core.py",
                "render",
                "--state",
                "/nonexistent/state.json",
            ]
            stdout, stderr = io.StringIO(), io.StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                self.assertEqual(core.main(), 1)
        finally:
            sys.argv = old_argv
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("Error", stderr.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
