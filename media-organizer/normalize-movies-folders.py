#!/usr/bin/env python3
"""Normalize movie folders using a dry-run manifest by default."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))

import movie_common  # noqa: E402


def require_non_root() -> None:
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        raise SystemExit("Error: this tool must NOT be run as root. Run it as your regular user.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Normalize movie folders to 'Movie Title (Year)' while preserving internal file names.",
    )
    parser.add_argument("--root", required=True, help="Movie library root to scan.")
    parser.add_argument(
        "--plan",
        help=(
            "Manifest path. In dry-run mode this is where the plan is written. "
            "In apply mode this existing plan is required."
        ),
    )
    parser.add_argument("--review-csv", help="CSV review report path for dry-run mode.")
    parser.add_argument("--cache", help="TMDb cache path for dry-run mode.")
    parser.add_argument("--dry-run", action="store_true", help="Generate a plan without changing files. This is the default.")
    parser.add_argument("--apply", action="store_true", help="Apply an existing plan. Requires --plan.")
    return parser


def main(argv: list[str] | None = None) -> int:
    require_non_root()
    parser = build_parser()
    args = parser.parse_args(argv)

    root = Path(args.root).expanduser().resolve()
    if not root.is_dir():
        parser.error(f"--root must be an existing directory: {root}")

    if args.apply:
        if not args.plan:
            parser.error("--apply requires --plan pointing to a reviewed manifest")
        result = movie_common.apply_plan(Path(args.plan).expanduser().resolve())
        print(f"Applied {result['applied']} action(s).")
        return 0

    plan_path = Path(args.plan).expanduser().resolve() if args.plan else root / movie_common.DEFAULT_PLAN_NAME
    review_path = Path(args.review_csv).expanduser().resolve() if args.review_csv else root / movie_common.DEFAULT_REVIEW_NAME
    cache_path = Path(args.cache).expanduser().resolve() if args.cache else root / movie_common.DEFAULT_CACHE_NAME
    manifest = movie_common.build_plan(
        root=root,
        plan_path=plan_path,
        review_csv_path=review_path,
        cache_path=cache_path,
        tmdb_api_key=os.environ.get("TMDB_API_KEY"),
    )

    action_count = len(manifest["actions"])
    review_count = len(manifest["review"])
    print(f"Dry-run complete. Wrote plan: {plan_path}")
    print(f"Wrote review CSV: {review_path}")
    print(f"Planned {action_count} action(s); {review_count} item(s) need manual review.")
    print(f"Apply only after review with: {Path(__file__).name} --root {root} --apply --plan {plan_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
