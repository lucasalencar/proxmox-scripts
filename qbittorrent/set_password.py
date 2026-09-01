#!/usr/bin/env python3
"""
qBittorrent WebUI password helper.

Generates PBKDF2-SHA512 hash and updates qBittorrent.conf.
Can also reset password directly inside a Proxmox LXC container.
Always generates a random password (no manual password input).

Usage:
  # Generate random password + hash
  python3 set_password.py --generate
  python3 set_password.py --generate --password-length 20

  # Update config with pre-generated hash
  python3 set_password.py --input /tmp/qbit.conf --output /tmp/qbit.new --user admin --hash '@ByteArray(...)'

  # Update config with auto-generated random password
  python3 set_password.py --input /tmp/qbit.conf --output /tmp/qbit.new --user admin

  # Full reset inside container (always auto-generates random password)
  python3 set_password.py --container 100 --user admin
  python3 set_password.py --container 100 --user admin --password-length 20
  python3 set_password.py --container 100 --user admin --hash '@ByteArray(...)'

Hash algorithm matches https://github.com/qbittorrent/qBittorrent/blob/master/src/base/utils/password.cpp
and https://gist.github.com/hastinbe/8b8d247f17481cfc262a98d661bc0fd5
"""

import argparse
import base64
import hashlib
import os
import re
import secrets
import subprocess
import sys
import tempfile


def _strip_password(pw: str | None) -> str | None:
    if pw is None:
        return None
    # Strip only trailing CR/LF from stdin/pipe (preserve intentional spaces)
    # Don't use .strip() to avoid breaking passwords with leading/trailing spaces
    return pw.rstrip("\r\n")


def generate_password(length: int = 16) -> str:
    # Same charset as qBittorrent Utils::Password::generate (no 0,1,l,o etc.)
    alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def generate_hash(password: str) -> str:
    salt = os.urandom(16)
    dk = hashlib.pbkdf2_hmac("sha512", password.encode(), salt, 100000)
    return f"@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(dk).decode()})"


def upsert(content: str, key: str, value: str) -> str:
    pattern = re.compile(rf"^{re.escape(key)}=.*$", re.MULTILINE)
    line = f"{key}={value}"
    if pattern.search(content):
        return pattern.sub(lambda m: line, content)
    return content.replace("[Preferences]", f"[Preferences]\n{line}", 1)


def update_config(input_path: str, output_path: str, user: str, qhash: str) -> None:
    with open(input_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    if "[Preferences]" not in content:
        content = content.rstrip() + "\n[Preferences]\n"

    content = upsert(content, r"WebUI\Username", user)
    content = upsert(content, r"WebUI\Password_PBKDF2", qhash)

    with open(output_path, "w", encoding="utf-8") as f:
        f.write(content)


def run_cmd(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


def reset_container(container_id: str, user: str, password: str | None, qhash: str | None) -> str:
    if not qhash:
        password = _strip_password(password)
        if not password:
            print("error: password required via stdin, --password or --hash", file=sys.stderr)
            sys.exit(1)
        qhash = generate_hash(password)

    # Stop service (verify it actually stopped to avoid config overwrite on restart)
    run_cmd(["pct", "exec", container_id, "--", "systemctl", "stop", "qbittorrent-nox"])
    for _ in range(10):
        r = run_cmd(["pct", "exec", container_id, "--", "systemctl", "is-active", "qbittorrent-nox"])
        if r.stdout.strip() != "active":
            break
        import time
        time.sleep(1)

    # Fetch config
    tmp_in = tempfile.mktemp()
    tmp_out = tempfile.mktemp()
    # Try primary path, fallback to secondary
    result = run_cmd(["pct", "exec", container_id, "--", "cat", "/root/.config/qBittorrent/qBittorrent.conf"])
    if result.returncode != 0 or not result.stdout.strip():
        result = run_cmd(["pct", "exec", container_id, "--", "cat", "/home/qbittorrent/.config/qBittorrent/qBittorrent.conf"])
    if result.returncode == 0 and result.stdout.strip():
        with open(tmp_in, "w", encoding="utf-8") as f:
            f.write(result.stdout)
    else:
        with open(tmp_in, "w", encoding="utf-8") as f:
            f.write("[Preferences]\nWebUI\\Port=8090\n")

    update_config(tmp_in, tmp_out, user, qhash)

    # Push back
    with open(tmp_out, "r", encoding="utf-8") as f:
        new_content = f.read()

    # Detect target path
    check = run_cmd(["pct", "exec", container_id, "--", "test", "-f", "/root/.config/qBittorrent/qBittorrent.conf"])
    if check.returncode == 0:
        target = "/root/.config/qBittorrent/qBittorrent.conf"
    else:
        check2 = run_cmd(["pct", "exec", container_id, "--", "test", "-f", "/home/qbittorrent/.config/qBittorrent/qBittorrent.conf"])
        target = "/home/qbittorrent/.config/qBittorrent/qBittorrent.conf" if check2.returncode == 0 else "/root/.config/qBittorrent/qBittorrent.conf"
        if target == "/root/.config/qBittorrent/qBittorrent.conf":
            run_cmd(["pct", "exec", container_id, "--", "bash", "-c", "mkdir -p /root/.config/qBittorrent"])

    proc = subprocess.Popen(["pct", "exec", container_id, "--", "bash", "-c", f"cat > {target}"], stdin=subprocess.PIPE, text=True)
    proc.communicate(new_content)

    try:
        os.unlink(tmp_in)
        os.unlink(tmp_out)
    except OSError:
        pass

    run_cmd(["pct", "exec", container_id, "--", "systemctl", "start", "qbittorrent-nox"])
    # Wait for ready (best effort) - check WebUI responds
    for _ in range(15):
        r = run_cmd(["pct", "exec", container_id, "--", "bash", "-c", "curl -sf http://127.0.0.1:8090/api/v2/app/version >/dev/null 2>&1 || systemctl is-active qbittorrent-nox >/dev/null 2>&1"])
        if r.returncode == 0:
            break
        import time
        time.sleep(2)

    return qhash


def main() -> None:
    parser = argparse.ArgumentParser(description="qBittorrent password helper (always generates random password)", allow_abbrev=False)
    parser.add_argument("--generate", action="store_true", help="Generate random password + hash and print to stdout")
    parser.add_argument("--input", help="Input qBittorrent.conf path")
    parser.add_argument("--output", help="Output qBittorrent.conf path")
    parser.add_argument("--user", default="admin", help="WebUI username (default: admin)")
    parser.add_argument("--hash", dest="qhash", help="Pre-generated @ByteArray hash (if omitted, generate random password)")
    parser.add_argument("--container", help="LXC container ID to reset password directly (requires pct)")
    parser.add_argument("--password-length", type=int, default=16, help="Length for generated password (default: 16)")
    parser.add_argument("--random", action="store_true", help=argparse.SUPPRESS)  # deprecated, kept for compat
    args = parser.parse_args()

    if args.generate:
        password = generate_password(args.password_length)
        print(f"{password} {generate_hash(password)}")
        return

    if args.container:
        # Always auto-generate unless --hash is provided
        if args.qhash:
            qhash = reset_container(args.container, args.user, None, args.qhash)
            print(qhash)
        else:
            password = generate_password(args.password_length)
            qhash = reset_container(args.container, args.user, password, None)
            print(f"{password} {qhash}")
        return

    if args.input and args.output:
        qhash = args.qhash
        if not qhash:
            password = generate_password(args.password_length)
            qhash = generate_hash(password)
            update_config(args.input, args.output, args.user, qhash)
            print(f"{password} {qhash}")
        else:
            update_config(args.input, args.output, args.user, qhash)
        return

    parser.print_help()
    sys.exit(1)


if __name__ == "__main__":
    main()
