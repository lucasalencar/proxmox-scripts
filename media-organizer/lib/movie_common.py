"""Movie folder scanning, parsing, planning, and apply helpers."""

from __future__ import annotations

import csv
import json
import re
import shutil
import tempfile
import urllib.parse
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


VIDEO_EXTENSIONS = {".mkv", ".mp4", ".avi", ".m4v", ".mpg", ".mpeg", ".vob"}
CONTEXT_EXTENSIONS = {
    ".srt",
    ".sub",
    ".ass",
    ".ssa",
    ".idx",
    ".jpg",
    ".jpeg",
    ".png",
    ".nfo",
    ".txt",
}
PLAN_VERSION = 1
DEFAULT_PLAN_NAME = ".movie-organizer-plan.json"
DEFAULT_REVIEW_NAME = ".movie-organizer-review.csv"
DEFAULT_CACHE_NAME = ".movie-organizer-cache.json"

YEAR_RE = re.compile(r"(?<!\d)(18[8-9]\d|19\d{2}|20\d{2})(?!\d)")
LEADING_YEAR_RE = re.compile(r"^\s*(18[8-9]\d|19\d{2}|20\d{2})[\s._-]+(.+)$")
CD_PART_RE = re.compile(
    r"\b(?:cd|disc|disk|dvd|part|pt)[\s._-]*(?:0?[1-9]|one|two|three|four)\b",
    re.IGNORECASE,
)
NOISE_RE = re.compile(
    r"\b("
    r"480p|576p|720p|1080p|2160p|4k|uhd|hdr|hdtv|web[-_. ]?dl|webrip|web|"
    r"brrip|bluray|blu[-_. ]?ray|bdrip|dvdrip|dvd[-_. ]?rip|dvdscr|xvid|divx|"
    r"x264|x265|h264|h\.264|h265|h\.265|hevc|aac|dts|dd5|ddp5|10bit|8bit|"
    r"yify|yts|rarbg|anoXmous|publichd|psychd|ctrlhd|gaz|silence|proper|"
    r"repack|extended|unrated|directors? cut|criterion|swesub|multi|sample"
    r")\b",
    re.IGNORECASE,
)
INVALID_PATH_CHARS_RE = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
SPACING_RE = re.compile(r"\s+")


@dataclass(frozen=True)
class ParsedName:
    title: str
    year: str | None
    confidence: float
    reason: str


@dataclass(frozen=True)
class MovieCandidate:
    source: Path
    source_kind: str
    evidence_name: str
    video_files: tuple[Path, ...]
    context_files: tuple[Path, ...]
    reason: str


class TmdbSearchError(RuntimeError):
    """Raised when TMDb is configured but the API lookup cannot complete."""


def is_video(path: Path) -> bool:
    return path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS


def is_context_file(path: Path) -> bool:
    return path.is_file() and path.suffix.lower() in CONTEXT_EXTENSIONS


def parse_movie_name(raw_name: str) -> ParsedName:
    """Extract a likely title and year from a release folder or file name."""
    name = Path(raw_name).name
    if Path(name).suffix.lower() in VIDEO_EXTENSIONS | CONTEXT_EXTENSIONS:
        name = Path(name).stem

    original = name
    name = name.strip()
    name = re.sub(r"\[[^\]]*\]", " ", name)
    name = re.sub(r"\{[^}]*\}", " ", name)
    name = re.sub(r"\([^)]*(?:p|x264|x265|hevc|aac|dts|bluray|criterion|rip)[^)]*\)", " ", name, flags=re.IGNORECASE)
    name = re.sub(r"[-_][A-Za-z0-9][A-Za-z0-9_-]{2,}$", " ", name)
    name = name.replace("&", " and ")
    name = re.sub(r"[._]+", " ", name)
    name = re.sub(r"\s+-\s+[^-]*$", " ", name)
    name = CD_PART_RE.sub(" ", name)

    year: str | None = None
    leading_year = LEADING_YEAR_RE.match(name)
    if leading_year:
        year = leading_year.group(1)
        name = leading_year.group(2)
    else:
        year_match = YEAR_RE.search(name)
        if year_match:
            year = year_match.group(1)
            name = name[: year_match.start()] + " " + name[year_match.end() :]

    name = NOISE_RE.sub(" ", name)
    name = re.sub(r"\b(?:cd|disc|disk|dvd)[\s._-]*0?[1-9]\b", " ", name, flags=re.IGNORECASE)
    name = re.sub(r"\b(?:eng|pob|por|ptbr|subpack|subs?)\b", " ", name, flags=re.IGNORECASE)
    name = re.sub(r"[-_,;]+", " ", name)
    name = SPACING_RE.sub(" ", name).strip(" .-_")

    title = title_case(name) if name else title_case(original)
    confidence = 0.85 if year else 0.45
    reason = "local-year" if year else "missing-year"
    return ParsedName(title=title, year=year, confidence=confidence, reason=reason)


def title_case(value: str) -> str:
    words = SPACING_RE.sub(" ", value.strip()).split(" ")
    small_words = {"a", "an", "and", "as", "at", "but", "by", "for", "in", "of", "on", "or", "the", "to"}
    titled: list[str] = []
    for index, word in enumerate(words):
        if not word:
            continue
        lower = word.lower()
        if word.isupper() and len(word) <= 4:
            titled.append(word)
        elif index > 0 and lower in small_words:
            titled.append(lower)
        else:
            titled.append("'".join(part[:1].upper() + part[1:].lower() for part in word.split("'")))
    return " ".join(titled)


def folder_name(title: str, year: str | None) -> str:
    clean_title = sanitize_path_component(title)
    return f"{clean_title} ({year})" if year else clean_title


def sanitize_path_component(value: str) -> str:
    value = INVALID_PATH_CHARS_RE.sub(" ", value)
    value = SPACING_RE.sub(" ", value).strip(" .")
    return value or "Unknown Movie"


def scan_movie_candidates(root: Path) -> tuple[list[MovieCandidate], list[dict[str, Any]]]:
    root = root.resolve()
    candidates: list[MovieCandidate] = []
    review: list[dict[str, Any]] = []
    _scan_directory(root, root, candidates, review)
    return candidates, review


def _scan_directory(
    directory: Path,
    root: Path,
    candidates: list[MovieCandidate],
    review: list[dict[str, Any]],
) -> None:
    entries = sorted(directory.iterdir(), key=lambda item: item.name.lower())
    direct_videos = tuple(item for item in entries if is_video(item))
    context_files = tuple(item for item in entries if is_context_file(item))
    subdirs = [item for item in entries if item.is_dir() and not item.name.startswith(".")]

    if not direct_videos:
        for subdir in subdirs:
            _scan_directory(subdir, root, candidates, review)
        return

    if directory == root:
        for video in direct_videos:
            candidates.append(
                MovieCandidate(
                    source=video,
                    source_kind="file",
                    evidence_name=video.name,
                    video_files=(video,),
                    context_files=tuple(),
                    reason="loose-video-file",
                )
            )
        for subdir in subdirs:
            _scan_directory(subdir, root, candidates, review)
        return

    if len(direct_videos) == 1:
        candidates.append(
            MovieCandidate(
                source=directory,
                source_kind="directory",
                evidence_name=directory.name,
                video_files=direct_videos,
                context_files=context_files,
                reason="single-video-folder",
            )
        )
        return

    if _looks_like_same_movie(direct_videos, directory.name):
        candidates.append(
            MovieCandidate(
                source=directory,
                source_kind="directory",
                evidence_name=directory.name,
                video_files=direct_videos,
                context_files=context_files,
                reason="multi-part-movie-folder",
            )
        )
        return

    if subdirs:
        for video in direct_videos:
            candidates.append(
                MovieCandidate(
                    source=video,
                    source_kind="file",
                    evidence_name=video.name,
                    video_files=(video,),
                    context_files=tuple(),
                    reason="loose-video-in-grouping-folder",
                )
            )
        for subdir in subdirs:
            _scan_directory(subdir, root, candidates, review)
        return

    review.append(
        {
            "source": str(directory),
            "reason": "multiple-direct-videos-review-required",
            "details": f"{len(direct_videos)} direct videos do not look like one multi-part movie",
        }
    )


def _looks_like_same_movie(video_files: tuple[Path, ...], directory_name: str) -> bool:
    parsed_videos = [parse_movie_name(video.name) for video in video_files]
    years = {parsed.year for parsed in parsed_videos if parsed.year}
    normalized_titles = {_normalize_compare_title(parsed.title) for parsed in parsed_videos if parsed.title}
    directory_parsed = parse_movie_name(directory_name)
    directory_title = _normalize_compare_title(directory_parsed.title)

    if len(years) == 1 and len(normalized_titles) == 1:
        return True
    if len(years) == 1 and any(title and (title in directory_title or directory_title in title) for title in normalized_titles):
        return True
    return all(CD_PART_RE.search(video.stem) for video in video_files)


def _normalize_compare_title(title: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", title.lower())


def build_plan(
    root: Path,
    plan_path: Path | None = None,
    review_csv_path: Path | None = None,
    cache_path: Path | None = None,
    tmdb_api_key: str | None = None,
) -> dict[str, Any]:
    root = root.resolve()
    plan_path = (plan_path or root / DEFAULT_PLAN_NAME).resolve()
    review_csv_path = (review_csv_path or root / DEFAULT_REVIEW_NAME).resolve()
    cache_path = (cache_path or root / DEFAULT_CACHE_NAME).resolve()
    cache = load_json_file(cache_path, default={})
    candidates, review_items = scan_movie_candidates(root)
    actions: list[dict[str, Any]] = []
    messages: list[dict[str, Any]] = []

    for candidate in candidates:
        parsed = parse_movie_name(candidate.evidence_name)
        tmdb_result = None
        tmdb_error = None
        if not parsed.year and tmdb_api_key:
            tmdb_result, tmdb_error = search_tmdb(parsed.title, parsed.year, tmdb_api_key, cache)
            if tmdb_result:
                parsed = ParsedName(
                    title=tmdb_result["title"],
                    year=tmdb_result.get("year") or parsed.year,
                    confidence=0.95,
                    reason="tmdb-match",
                )

        if not parsed.year:
            if tmdb_api_key:
                if tmdb_error:
                    details = f"No local year found and TMDB search failed ({tmdb_error})"
                    raise TmdbSearchError(f"{details} [{candidate.source}]")
                else:
                    details = "No local year found and TMDB search returned no results"
                    messages.append(
                        {
                            "level": "warning",
                            "code": "tmdb-no-results",
                            "source": str(candidate.source),
                            "details": details,
                        }
                    )
            else:
                details = "No local year found and TMDB_API_KEY is not configured"
                messages.append(
                    {
                        "level": "warning",
                        "code": "tmdb-api-key-missing",
                        "source": str(candidate.source),
                        "details": details,
                    }
                )
            review_items.append(
                {
                    "source": str(candidate.source),
                    "reason": "missing-year-review-required",
                    "details": details,
                }
            )
            continue

        target = candidate.source.parent / folder_name(parsed.title, parsed.year)
        action_type = "move_file_to_folder" if candidate.source_kind == "file" else "rename_folder"
        conflicts = detect_conflicts(candidate.source, target, action_type)
        if candidate.source.resolve() == target.resolve():
            continue
        if conflicts:
            review_items.append(
                {
                    "source": str(candidate.source),
                    "target": str(target),
                    "reason": "target-conflict",
                    "details": "; ".join(conflicts),
                }
            )
            continue

        actions.append(
            {
                "type": action_type,
                "source": str(candidate.source),
                "target": str(target),
                "title": parsed.title,
                "year": parsed.year,
                "tmdb_id": tmdb_result.get("id") if tmdb_result else None,
                "confidence": parsed.confidence,
                "reason": candidate.reason + ":" + parsed.reason,
                "conflicts": conflicts,
                "preserve_internal_names": True,
                "video_files": [str(path) for path in candidate.video_files],
            }
        )

    save_json_file(cache_path, cache)
    manifest = {
        "version": PLAN_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "root": str(root),
        "dry_run": True,
        "preserve_internal_names": True,
        "actions": actions,
        "review": review_items,
        "messages": messages,
    }
    save_json_file(plan_path, manifest)
    write_review_csv(review_csv_path, manifest)
    return manifest


def detect_conflicts(source: Path, target: Path, action_type: str) -> list[str]:
    if action_type == "rename_folder":
        if target.exists() and source.resolve() != target.resolve():
            return ["target already exists"]
        return []

    if target.exists() and not target.is_dir():
        return ["target folder path exists as a file"]
    destination_file = target / source.name
    if destination_file.exists() and source.resolve() != destination_file.resolve():
        return ["destination file already exists"]
    return []


def search_tmdb(query: str, year: str | None, api_key: str, cache: dict[str, Any]) -> tuple[dict[str, Any] | None, str | None]:
    cache_key = f"{query}|{year or ''}"
    if cache_key in cache and cache[cache_key] is not None:
        return cache[cache_key], None

    params = {"query": query}
    if year:
        params["year"] = year
        params["primary_release_year"] = year
    url = "https://api.themoviedb.org/3/search/movie?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {api_key}", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return None, f"HTTP {exc.code} {exc.reason}"
    except urllib.error.URLError as exc:
        return None, f"network error: {exc.reason}"
    except OSError as exc:
        return None, f"network error: {exc}"
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None, "invalid JSON response"

    result = _best_tmdb_result(payload.get("results", []), year)
    if result:
        cache[cache_key] = result
    else:
        cache.pop(cache_key, None)
    return result, None


def _best_tmdb_result(results: list[dict[str, Any]], year: str | None) -> dict[str, Any] | None:
    if not results:
        return None
    selected = results[0]
    if year:
        for result in results:
            if str(result.get("release_date", ""))[:4] == year:
                selected = result
                break
    release_year = str(selected.get("release_date", ""))[:4] or None
    return {"id": selected.get("id"), "title": selected.get("title") or selected.get("original_title"), "year": release_year}


def apply_plan(plan_path: Path) -> dict[str, Any]:
    manifest = load_json_file(plan_path, default=None)
    if not isinstance(manifest, dict):
        raise ValueError(f"Invalid plan file: {plan_path}")
    if manifest.get("version") != PLAN_VERSION:
        raise ValueError(f"Unsupported plan version: {manifest.get('version')}")

    actions = manifest.get("actions", [])
    results: list[dict[str, Any]] = []
    for action in sorted(actions, key=lambda item: len(Path(item["source"]).parts), reverse=True):
        if action.get("conflicts"):
            results.append({"source": action["source"], "status": "skipped", "reason": "conflicts"})
            continue
        if action["type"] == "rename_folder":
            _apply_rename_folder(Path(action["source"]), Path(action["target"]))
        elif action["type"] == "move_file_to_folder":
            _apply_move_file_to_folder(Path(action["source"]), Path(action["target"]))
        else:
            raise ValueError(f"Unsupported action type: {action['type']}")
        results.append({"source": action["source"], "target": action["target"], "status": "applied"})
    return {"applied": sum(1 for item in results if item["status"] == "applied"), "results": results}


def _apply_rename_folder(source: Path, target: Path) -> None:
    if not source.is_dir():
        raise FileNotFoundError(f"Source folder does not exist: {source}")
    if target.exists():
        raise FileExistsError(f"Target already exists: {target}")
    if not target.parent.is_dir():
        raise FileNotFoundError(f"Target parent does not exist: {target.parent}")
    source.rename(target)


def _apply_move_file_to_folder(source: Path, target_folder: Path) -> None:
    if not source.is_file():
        raise FileNotFoundError(f"Source file does not exist: {source}")
    if target_folder.exists() and not target_folder.is_dir():
        raise FileExistsError(f"Target folder path exists as a file: {target_folder}")
    destination = target_folder / source.name
    if destination.exists():
        raise FileExistsError(f"Destination file already exists: {destination}")
    target_folder.mkdir(parents=False, exist_ok=True)
    source.rename(destination)


def load_json_file(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def save_json_file(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        temp_name = handle.name
    shutil.move(temp_name, path)


def write_review_csv(path: Path, manifest: dict[str, Any]) -> None:
    rows = []
    for action in manifest.get("actions", []):
        rows.append(
            {
                "kind": "action",
                "source": action.get("source", ""),
                "target": action.get("target", ""),
                "reason": action.get("reason", ""),
                "confidence": action.get("confidence", ""),
                "details": "",
            }
        )
    for item in manifest.get("review", []):
        rows.append(
            {
                "kind": "review",
                "source": item.get("source", ""),
                "target": item.get("target", ""),
                "reason": item.get("reason", ""),
                "confidence": "",
                "details": item.get("details", ""),
            }
        )
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["kind", "source", "target", "reason", "confidence", "details"])
        writer.writeheader()
        writer.writerows(rows)
