#!/usr/bin/env python3
"""Pure core for caddy/generate-caddyfile.sh.

Parses saved Caddyfile blocks, resolves one entry per guest or service,
and renders the Caddyfile. Stdlib only. Reads prompts from stdin, writes
the Caddyfile to stdout and log lines to stderr.
"""

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Set, Tuple

__all__ = [
    "Guest",
    "SavedRoute",
    "Entry",
    "parse_saved_caddyfile",
    "saved_services_for_ip",
    "suggest_subdomain_for_port",
    "default_tls_for",
    "suggest_port",
    "sanitize_subdomain",
    "prompt_tls",
    "resolve_guests",
    "render_caddyfile",
    "main",
]


@dataclass
class Guest:
    name: str
    gid: str
    gtype: str
    ip: str
    ports: List[int] = field(default_factory=list)


@dataclass
class SavedRoute:
    name: str
    ip: str
    port: int


@dataclass
class Entry:
    name: str
    ip: str
    port: int
    tls: str


def parse_saved_caddyfile(
    text: str, domain: str
) -> Tuple[Dict[str, SavedRoute], Dict[str, str]]:
    routes: Dict[str, SavedRoute] = {}
    tls: Dict[str, str] = {}
    escaped = re.escape(domain)
    http_re = re.compile(r"http://([^.\s]+)\.%s\s*\{" % escaped)
    https_re = re.compile(r"([^.\s/:]+)\.%s\s*\{" % escaped)
    proxy_re = re.compile(r"reverse_proxy\s+(\d+\.\d+\.\d+\.\d+):(\d+)")
    pending_subdomain: Optional[str] = None
    for line in text.splitlines():
        match = http_re.search(line)
        if match:
            pending_subdomain = match.group(1)
            tls[pending_subdomain] = "http"
            continue
        match = https_re.search(line)
        if match:
            pending_subdomain = match.group(1)
            tls[pending_subdomain] = "https"
            continue
        match = proxy_re.search(line)
        if match and pending_subdomain:
            routes[pending_subdomain] = SavedRoute(
                pending_subdomain, match.group(1), int(match.group(2))
            )
            pending_subdomain = None
    return routes, tls


def saved_services_for_ip(
    routes: Dict[str, SavedRoute], wanted_ip: str, exclude: str
) -> List[str]:
    return [
        name
        for name, route in routes.items()
        if name and name != exclude and route.ip == wanted_ip
    ]


def suggest_subdomain_for_port(
    routes: Dict[str, SavedRoute], wanted_port: int
) -> Optional[str]:
    matches = [name for name, route in routes.items() if name and route.port == wanted_port]
    if len(matches) == 1:
        return matches[0]
    return None


def default_tls_for(name: str) -> str:
    if name.startswith("nextcloud"):
        return "https"
    return "http"


def suggest_port(ports: List[int]) -> int:
    if 80 in ports:
        return 80
    if 443 in ports:
        return 443
    if ports:
        return ports[0]
    return 80


def sanitize_subdomain(raw: str) -> str:
    return "".join(raw.split()).split(".", 1)[0]


def prompt_tls(
    name: str,
    tls_map: Dict[str, str],
    domain: str,
    ask: Callable[[str], str],
    log: Callable[[str], None],
) -> str:
    if name in tls_map:
        saved = tls_map[name]
        label = "HTTPS (tls internal)" if saved == "https" else "HTTP"
        log("  \u2713 %s \u2192 saved TLS: %s" % (name, label))
        return saved
    default = default_tls_for(name)
    marker = "Y" if default == "https" else "n"
    choice = ask(
        "  HTTPS (tls internal) for %s.%s? [Y/n] (default: %s): "
        % (name, domain, marker)
    ).strip().lower()
    if choice in ("y", "yes"):
        return "https"
    if choice in ("n", "no"):
        return "http"
    return default


def resolve_guests(
    guests: List[Guest],
    routes: Dict[str, SavedRoute],
    tls: Dict[str, str],
    domain: str,
    ask: Callable[[str], str],
    log: Callable[[str], None],
) -> Tuple[List[Entry], Dict[str, str]]:
    saved = dict(routes)
    claimed: Set[str] = set()
    names: List[str] = []
    seen = set()

    def add_entry(name: str, ip: str, port: int) -> None:
        routes[name] = SavedRoute(name, ip, port)
        if name not in seen:
            seen.add(name)
            names.append(name)

    def reuse_saved_port(name: str, ip: str) -> None:
        log("  \u2713 %s \u2192 saved port %d" % (name, saved[name].port))
        add_entry(name, ip, saved[name].port)
        tls[name] = prompt_tls(name, tls, domain, ask, log)
        claimed.add(name)

    for guest in guests:
        name = guest.name
        ip = guest.ip
        saved_services = [
            svc
            for svc in saved_services_for_ip(saved, ip, name)
            if svc not in claimed
        ]
        if saved_services:
            log("  \u2713 %s \u2192 saved multi-service:" % name)
            for svc in saved_services:
                log("    \u2713 %s.%s \u2192 %s:%d" % (svc, domain, ip, saved[svc].port))
                add_entry(svc, ip, saved[svc].port)
            claimed.update(saved_services)
            if name in saved:
                reuse_saved_port(name, ip)
            continue
        if name in saved:
            reuse_saved_port(name, ip)
            continue
        ports = list(guest.ports)
        multi = False
        if len(ports) > 1:
            answer = ask(
                "  Does %s host multiple services (one subdomain per port)? [y/N]: "
                % name
            ).strip().lower()
            multi = answer in ("y", "yes")
        if multi:
            added_here: List[str] = []
            for port in ports:
                suggestion = suggest_subdomain_for_port(saved, port)
                if suggestion in claimed:
                    suggestion = None
                if suggestion:
                    raw = ask(
                        "  Subdomain for %s port %d (%s) [default: %s]: "
                        % (name, port, ip, suggestion)
                    )
                    raw = raw.strip() or suggestion
                else:
                    raw = ask(
                        "  Subdomain for %s port %d (%s) [empty to skip]: "
                        % (name, port, ip)
                    )
                svc = sanitize_subdomain(raw)
                if not svc:
                    continue
                tls[svc] = prompt_tls(svc, tls, domain, ask, log)
                add_entry(svc, ip, port)
                claimed.add(svc)
                added_here.append(svc)
                log("  \u2713 %s.%s \u2192 %s:%d" % (svc, domain, ip, port))
            if not added_here:
                log(
                    "  No subdomain given for %s \u2014 falling back to single-service"
                    % name
                )
            else:
                continue
        suggested = suggest_port(ports)
        raw_port = ask(
            "  Port for %s.%s (%s) [default: %d]: " % (name, domain, ip, suggested)
        ).strip() or str(suggested)
        if re.match(r"^[0-9]+$", raw_port) and 1 <= int(raw_port) <= 65535:
            port = int(raw_port)
        else:
            log("  Invalid port '%s' \u2014 using %d" % (raw_port, suggested))
            port = suggested
        add_entry(name, ip, port)
        tls[name] = prompt_tls(name, tls, domain, ask, log)
    entries = [
        Entry(entry, routes[entry].ip, routes[entry].port, tls.get(entry, "http"))
        for entry in names
    ]
    return entries, tls


def render_block(name: str, ip: str, port: int, tls_mode: str, domain: str) -> str:
    if tls_mode == "https":
        return "%s.%s {\n    tls internal\n    reverse_proxy %s:%d\n}\n\n" % (
            name,
            domain,
            ip,
            port,
        )
    return "http://%s.%s {\n    reverse_proxy %s:%d\n}\n\n" % (name, domain, ip, port)


def render_caddyfile(
    entries: List[Entry],
    routes: Dict[str, SavedRoute],
    tls: Dict[str, str],
    domain: str,
) -> Tuple[str, List[str]]:
    parts = [
        render_block(entry.name, entry.ip, entry.port, entry.tls, domain)
        for entry in entries
    ]
    warnings = []
    final = {entry.name for entry in entries}
    for name, route in routes.items():
        if not name or name in final:
            continue
        warnings.append(
            "  Preserving unmanaged block %s.%s (%s:%d)"
            % (name, domain, route.ip, route.port)
        )
        parts.append(
            render_block(name, route.ip, route.port, tls.get(name, "http"), domain)
        )
    return "".join(parts), warnings


def read_prompt(prompt: str) -> str:
    print(prompt, end="", file=sys.stderr, flush=True)
    try:
        return input()
    except EOFError:
        return ""


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Resolve guest entries and render a Caddyfile."
    )
    parser.add_argument("--domain", required=True)
    parser.add_argument("--saved-file", default=None)
    parser.add_argument("--guests-file", required=True)
    args = parser.parse_args(argv)

    def log(line: str) -> None:
        print(line, file=sys.stderr)

    try:
        with open(args.guests_file, encoding="utf-8") as handle:
            raw_guests = json.load(handle)
        guests = [
            Guest(
                name=item["name"],
                gid=str(item.get("gid", "")),
                gtype=str(item.get("gtype", "ct")),
                ip=item["ip"],
                ports=[int(port) for port in item.get("ports", [])],
            )
            for item in raw_guests
        ]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print("Error: cannot load guests file: %s" % (exc,), file=sys.stderr)
        return 1
    routes: Dict[str, SavedRoute] = {}
    tls: Dict[str, str] = {}
    if args.saved_file and os.path.exists(args.saved_file):
        try:
            with open(args.saved_file, encoding="utf-8") as handle:
                saved_text = handle.read()
        except OSError as exc:
            print("Error: cannot read saved file: %s" % (exc,), file=sys.stderr)
            return 1
        log("Loading existing configuration from %s..." % args.saved_file)
        routes, tls = parse_saved_caddyfile(saved_text, args.domain)
        if routes or tls:
            log(
                "  Found %d saved port mapping(s) and %d TLS setting(s)"
                % (len(routes), len(tls))
            )
        log("")
    entries, tls = resolve_guests(
        guests, routes, tls, args.domain, read_prompt, log
    )
    text, warnings = render_caddyfile(entries, routes, tls, args.domain)
    for warning in warnings:
        log(warning)
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
