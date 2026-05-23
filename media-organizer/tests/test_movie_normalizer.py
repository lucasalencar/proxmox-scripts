import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MOVIES_DIR = REPO_ROOT / "media-organizer"
sys.path.insert(0, str(MOVIES_DIR / "lib"))

import movie_common  # noqa: E402


class MovieNameParsingTests(unittest.TestCase):
    def test_extracts_title_and_year_from_release_name(self):
        parsed = movie_common.parse_movie_name("American.Hustle.2013.1080p.BluRay.x264.YIFY.mp4")

        self.assertEqual(parsed.title, "American Hustle")
        self.assertEqual(parsed.year, "2013")
        self.assertGreaterEqual(parsed.confidence, 0.8)

    def test_extracts_leading_year_and_keeps_clean_title(self):
        parsed = movie_common.parse_movie_name("1965 Help")

        self.assertEqual(parsed.title, "Help")
        self.assertEqual(parsed.year, "1965")

    def test_missing_year_keeps_local_title_without_tmdb_requirement(self):
        parsed = movie_common.parse_movie_name("Raul.O.Inicio.O.Fim.e.o.Meio.DVDRip.XviD-3LT0N.avi")

        self.assertEqual(parsed.title, "Raul O Inicio O Fim E O Meio")
        self.assertIsNone(parsed.year)
        self.assertEqual(parsed.reason, "missing-year")


class ScannerTests(unittest.TestCase):
    def test_scanner_preserves_grouping_folder_and_detects_child_movies(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            movie_dir = root / "Bill Murray" / "1979 Meatballs"
            movie_dir.mkdir(parents=True)
            (movie_dir / "meatballs.1979.720p.bluray.x264-psychd.mkv").write_text("", encoding="utf-8")

            candidates, review = movie_common.scan_movie_candidates(root)

        self.assertEqual(review, [])
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0].source.name, "1979 Meatballs")
        self.assertEqual(candidates[0].reason, "single-video-folder")

    def test_scanner_marks_unrelated_multiple_videos_for_review(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            folder = root / "Mixed"
            folder.mkdir()
            (folder / "Movie.One.1999.mkv").write_text("", encoding="utf-8")
            (folder / "Other.Movie.2001.mkv").write_text("", encoding="utf-8")

            candidates, review = movie_common.scan_movie_candidates(root)

        self.assertEqual(candidates, [])
        self.assertEqual(review[0]["reason"], "multiple-direct-videos-review-required")


class ManifestAndApplyTests(unittest.TestCase):
    def test_dry_run_builds_manifest_without_modifying_files(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            video = root / "An.American.Werewolf.In.London.1981.mkv"
            video.write_text("video", encoding="utf-8")

            manifest = movie_common.build_plan(root)

            self.assertTrue(video.exists())
            self.assertFalse((root / "An American Werewolf in London (1981)").exists())
            self.assertEqual(manifest["dry_run"], True)
            self.assertEqual(manifest["actions"][0]["type"], "move_file_to_folder")
            self.assertEqual(Path(manifest["actions"][0]["target"]).name, "An American Werewolf in London (1981)")
            self.assertTrue((root / movie_common.DEFAULT_PLAN_NAME).exists())
            self.assertTrue((root / movie_common.DEFAULT_REVIEW_NAME).exists())

    def test_apply_moves_loose_video_into_folder_and_preserves_file_name(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            video = root / "An.American.Werewolf.In.London.1981.mkv"
            video.write_text("video", encoding="utf-8")
            movie_common.build_plan(root)

            result = movie_common.apply_plan(root / movie_common.DEFAULT_PLAN_NAME)

            target_file = root / "An American Werewolf in London (1981)" / "An.American.Werewolf.In.London.1981.mkv"
            self.assertEqual(result["applied"], 1)
            self.assertTrue(target_file.exists())
            self.assertEqual(target_file.read_text(encoding="utf-8"), "video")

    def test_apply_renames_folder_but_preserves_internal_names(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            folder = root / "American Hustle 2013"
            folder.mkdir()
            (folder / "American.Hustle.2013.1080p.BluRay.x264.YIFY.mp4").write_text("video", encoding="utf-8")
            (folder / "American.Hustle.2013.eng.srt").write_text("sub", encoding="utf-8")
            movie_common.build_plan(root)

            movie_common.apply_plan(root / movie_common.DEFAULT_PLAN_NAME)

            target = root / "American Hustle (2013)"
            self.assertTrue((target / "American.Hustle.2013.1080p.BluRay.x264.YIFY.mp4").exists())
            self.assertTrue((target / "American.Hustle.2013.eng.srt").exists())
            self.assertFalse(folder.exists())

    def test_target_collision_goes_to_review_not_actions(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "American Hustle 2013"
            source.mkdir()
            (source / "American.Hustle.2013.mkv").write_text("", encoding="utf-8")
            (root / "American Hustle (2013)").mkdir()

            manifest = movie_common.build_plan(root)

        self.assertEqual(manifest["actions"], [])
        self.assertEqual(manifest["review"][0]["reason"], "target-conflict")

    def test_without_tmdb_key_missing_year_is_reviewed_without_network(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            folder = root / "Raul O Inicio O Fim e o Meio"
            folder.mkdir()
            (folder / "Raul.O.Inicio.O.Fim.e.o.Meio.DVDRip.XviD-3LT0N.avi").write_text("", encoding="utf-8")

            manifest = movie_common.build_plan(root, tmdb_api_key=None)

        self.assertEqual(manifest["actions"], [])
        self.assertEqual(manifest["review"][0]["reason"], "missing-year-review-required")


class CliTests(unittest.TestCase):
    def test_cli_defaults_to_dry_run_and_apply_requires_plan(self):
        cli_path = MOVIES_DIR / "normalize-movies-folders.py"
        spec = importlib.util.spec_from_file_location("normalize_folders", cli_path)
        self.assertIsNotNone(spec)

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            video = root / "American.Hustle.2013.mkv"
            video.write_text("video", encoding="utf-8")

            dry_run = subprocess.run(
                [sys.executable, str(cli_path), "--root", str(root)],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertEqual(dry_run.returncode, 0, dry_run.stderr)
            self.assertTrue((root / movie_common.DEFAULT_PLAN_NAME).exists())
            self.assertTrue(video.exists())

            missing_plan = subprocess.run(
                [sys.executable, str(cli_path), "--root", str(root), "--apply"],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertNotEqual(missing_plan.returncode, 0)
            self.assertIn("--plan", missing_plan.stderr)


if __name__ == "__main__":
    unittest.main()
