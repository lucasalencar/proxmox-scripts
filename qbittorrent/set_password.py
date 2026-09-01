#!/usr/bin/env python3
"""
qBittorrent WebUI password helper.

Generates PBKDF2-SHA512 hash and updates qBittorrent.conf.
Can also reset password directly inside a Proxmox LXC container.

Usage:
  # Generate hash only (password via stdin)
  printf '%s' "mypassword" | python3 set_password.py --generate

  # Update config (password via stdin, hash generated internally)
  printf '%s' "mypassword" | python3 set_password.py --input /tmp/qbit.conf --output /tmp/qbit.new --user admin

  # Update config with pre-generated hash
  python3 set_password.py --input /tmp/qbit.conf --output /tmp/qbit.new --user admin --hash '@ByteArray(...)'

  # Full reset inside container (password via stdin or --password)
  printf '%s' "mypassword" | python3 set_password.py --container 100 --user admin
  python3 set_password.py --container 100 --password "mypassword" --user admin

Hash algorithm matches https://github.com/qbittorrent/qBittorrent/blob/master/src/base/utils/password.cpp
and https://gist.github.com/hastinbe/8b8d247f17481cfc262a98d661bc0fd5
"""

import argparse
import base64
import hashlib
import os
import re
import subprocess
import sys
import tempfile


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
        if not password:
            print("error: password required via stdin, --password or --hash", file=sys.stderr)
            sys.exit(1)
        qhash = generate_hash(password)

    # Stop service
    run_cmd(["pct", "exec", container_id, "--", "systemctl", "stop", "qbittorrent-nox"])

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
    # Wait for ready (best effort)
    for _ in range(15):
        r = run_cmd(["pct", "exec", container_id, "--", "true"])
        if r.returncode == 0:
            break
        import time
        time.sleep(2)

    return qhash


def main() -> None:
    parser = argparse.ArgumentParser(description="qBittorrent password helper")
    parser.add_argument("--generate", action="store_true", help="Generate hash from stdin and print to stdout")
    parser.add_argument("--input", help="Input qBittorrent.conf path")
    parser.add_argument("--output", help="Output qBittorrent.conf path")
    parser.add_argument("--user", default="admin", help="WebUI username (default: admin)")
    parser.add_argument("--hash", dest="qhash", help="Pre-generated @ByteArray hash (if omitted, read password from stdin and generate)")
    parser.add_argument("--container", help="LXC container ID to reset password directly (requires pct)")
    parser.add_argument("--password", help="Password string (alternative to stdin, avoid shell history)")
    args = parser.parse_args()

    if args.generate:
        password = args.password if args.password is not None else sys.stdin.read()
        if not password:
            print("error: password required via stdin or --password", file=sys.stderr)
            sys.exit(1)
        print(generate_hash(password))
        return

    if args.container:
        password = args.password
        if password is None and not args.qhash:
            # Try stdin if not provided via --password
            if not sys.stdin.isatty():
                password = sys.stdin.read()
            else:
                password = None
        qhash = reset_container(args.container, args.user, password, args.qhash)
        print(qhash)
        return

    if args.input and args.output:
        qhash = args.qhash
        if not qhash:
            password = args.password if args.password is not None else sys.stdin.read()
            if not password:
                print("error: password required via stdin, --password or --hash", file=sys.stderr)
                sys.exit(1)
            qhash = generate_hash(password)
        update_config(args.input, args.output, args.user, qhash)
        return

    parser.print_help()
    sys.exit(1)


if __name__ == "__main__":
    main()
