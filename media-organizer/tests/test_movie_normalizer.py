import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
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

    def test_keeps_valid_title_words_that_can_also_be_release_groups(self):
        silence = movie_common.parse_movie_name("The.Silence.of.the.Lambs.1991.1080p.BluRay.mkv")
        horizon = movie_common.parse_movie_name("Event.Horizon.1997.1080p.BluRay.mkv")

        self.assertEqual(silence.title, "The Silence of the Lambs")
        self.assertEqual(silence.year, "1991")
        self.assertEqual(horizon.title, "Event Horizon")
        self.assertEqual(horizon.year, "1997")

    def test_removes_trailing_release_group_after_release_noise(self):
        parsed = movie_common.parse_movie_name(
            "Goodbye.to.Language.[Adieu.au.Langage].2014.BRRip.x264.HORiZON-ArtSubs.mkv"
        )

        self.assertEqual(parsed.title, "Goodbye to Language")
        self.assertEqual(parsed.year, "2014")

    def test_removes_contextual_edition_tags_without_leaving_cut_or_collection(self):
        new_world = movie_common.parse_movie_name("2005 The.New.World.2005.Extended.Cut.720p.BluRay.X264-AMIABLE")
        thin_red_line = movie_common.parse_movie_name("1998 The Thin Red Line 1998 Criterion Collection 720p BRRip x264-HDLiTE")

        self.assertEqual(new_world.title, "The New World")
        self.assertEqual(new_world.year, "2005")
        self.assertEqual(thin_red_line.title, "The Thin Red Line")
        self.assertEqual(thin_red_line.year, "1998")

    def test_removes_empty_parentheses_left_by_release_noise(self):
        parsed = movie_common.parse_movie_name("Before Midnight (2013) Criterion (1080p BluRay x265 HEVC 10bit AAC 5.1 Silence)")

        self.assertEqual(parsed.title, "Before Midnight")
        self.assertEqual(parsed.year, "2013")

    def test_preserves_ambiguous_words_when_they_are_part_of_title(self):
        web = movie_common.parse_movie_name("Charlotte's Web.2006.1080p.BluRay.mkv")
        proper = movie_common.parse_movie_name("A.Proper.Violence.2011.720p.WEBRip.mkv")
        sample = movie_common.parse_movie_name("Sample.This.2012.1080p.BluRay.mkv")

        self.assertEqual(web.title, "Charlotte's Web")
        self.assertEqual(proper.title, "A Proper Violence")
        self.assertEqual(sample.title, "Sample This")

    def test_removes_trailing_release_groups_after_codec_noise(self):
        lobo = movie_common.parse_movie_name("O.Lobo.Atras.da.Porta.2014.DVDRip.x264.AC3-RK.mkv")
        romeo = movie_common.parse_movie_name("Romeo.and.Juliet.1968.REMASTERED.1080p.BluRay.H264.AAC-LAMA[TGx]")
        gift = movie_common.parse_movie_name("2000 The.Gift.2000.DVDRip.XviD.AR")

        self.assertEqual(lobo.title, "O Lobo Atras Da Porta")
        self.assertEqual(lobo.year, "2014")
        self.assertEqual(romeo.title, "Romeo and Juliet")
        self.assertEqual(romeo.year, "1968")
        self.assertEqual(gift.title, "The Gift")
        self.assertEqual(gift.year, "2000")


class ScannerTests(unittest.TestCase):
    def test_scanner_ignores_macos_appledouble_video_artifacts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "._An.American.Werewolf.In.London.1981.mkv").write_text("", encoding="utf-8")
            video = root / "An.American.Werewolf.In.London.1981.mkv"
            video.write_text("", encoding="utf-8")

            candidates, review = movie_common.scan_movie_candidates(root)

        self.assertEqual(review, [])
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0].source.name, video.name)

    def test_scanner_ignores_sample_video_files(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "Movie.Sample.2001.mkv").write_text("", encoding="utf-8")
            video = root / "Movie.2001.mkv"
            video.write_text("", encoding="utf-8")

            candidates, review = movie_common.scan_movie_candidates(root)

        self.assertEqual(review, [])
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0].source.name, video.name)

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

    def test_duplicate_planned_folder_targets_go_to_review_not_actions(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            first = root / "1980 The Elephant Man"
            first.mkdir()
            (first / "the.elephant.man.1980.mkv").write_text("", encoding="utf-8")
            second = root / "1980 The Elephant Man "
            second.mkdir()
            (second / "the.elephant.man.1980.copy.mkv").write_text("", encoding="utf-8")

            manifest = movie_common.build_plan(root)

        self.assertEqual(manifest["actions"], [])
        self.assertEqual({item["reason"] for item in manifest["review"]}, {"planned-target-conflict"})

    def test_without_tmdb_key_missing_year_is_reviewed_without_network(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            folder = root / "Raul O Inicio O Fim e o Meio"
            folder.mkdir()
            (folder / "Raul.O.Inicio.O.Fim.e.o.Meio.DVDRip.XviD-3LT0N.avi").write_text("", encoding="utf-8")

            manifest = movie_common.build_plan(root, tmdb_api_key=None)

        self.assertEqual(manifest["actions"], [])
        self.assertEqual(manifest["review"][0]["reason"], "missing-year-review-required")

    def test_single_video_folder_prefers_video_name_when_it_has_year(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            folder = root / "Godard"
            folder.mkdir()
            (folder / "Goodbye.to.Language.[Adieu.au.Langage].2014.BRRip.x264.HORiZON-ArtSubs.mkv").write_text("", encoding="utf-8")

            with unittest.mock.patch.object(movie_common.urllib.request, "urlopen", side_effect=AssertionError("TMDB should not be called")):
                manifest = movie_common.build_plan(root, tmdb_api_key="fake_key")

        self.assertEqual(len(manifest["actions"]), 1)
        self.assertEqual(Path(manifest["actions"][0]["target"]).name, "Goodbye to Language (2014)")
        self.assertEqual(manifest["actions"][0]["reason"], "single-video-folder:local-year")


class TmdbReviewDetailsTests(unittest.TestCase):
    def test_missing_key_shows_not_configured_message(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            folder = root / "Raul O Inicio O Fim e o Meio"
            folder.mkdir()
            (folder / "Raul.O.Inicio.O.Fim.e.o.Meio.DVDRip.XviD-3LT0N.avi").write_text("", encoding="utf-8")

            manifest = movie_common.build_plan(root, tmdb_api_key=None)

        self.assertEqual(len(manifest["review"]), 1)
        self.assertIn("not configured", manifest["review"][0]["details"])
        self.assertEqual(manifest["messages"][0]["level"], "warning")
        self.assertEqual(manifest["messages"][0]["code"], "tmdb-api-key-missing")

    def test_network_error_raises_tmdb_search_error(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            folder = root / "Raul O Inicio O Fim e o Meio"
            folder.mkdir()
            (folder / "Raul.O.Inicio.O.Fim.e.o.Meio.DVDRip.XviD-3LT0N.avi").write_text("", encoding="utf-8")

            with unittest.mock.patch.object(movie_common.urllib.request, "urlopen", side_effect=OSError("Connection refused")):
                with self.assertRaises(movie_common.TmdbSearchError) as raised:
                    movie_common.build_plan(root, tmdb_api_key="fake_key")

        self.assertIn("network error", str(raised.exception))

    def test_no_results_shows_no_results_message(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            folder = root / "Raul O Inicio O Fim e o Meio"
            folder.mkdir()
            (folder / "Raul.O.Inicio.O.Fim.e.o.Meio.DVDRip.XviD-3LT0N.avi").write_text("", encoding="utf-8")

            mock_response = unittest.mock.MagicMock()
            mock_response.read.return_value = b'{"results": []}'
            mock_response.__enter__.return_value = mock_response

            with unittest.mock.patch.object(movie_common.urllib.request, "urlopen", return_value=mock_response):
                manifest = movie_common.build_plan(root, tmdb_api_key="fake_key")

        self.assertEqual(len(manifest["review"]), 1)
        self.assertIn("returned no results", manifest["review"][0]["details"])
        self.assertEqual(manifest["messages"][0]["level"], "warning")
        self.assertEqual(manifest["messages"][0]["code"], "tmdb-no-results")

    def test_distant_tmdb_match_is_reviewed_as_no_result(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "I'm Here.avi").write_text("", encoding="utf-8")

            mock_response = unittest.mock.MagicMock()
            mock_response.read.return_value = b'{"results": [{"id": 43939, "title": "I\\u0027m Still Here", "release_date": "2010-09-10"}]}'
            mock_response.__enter__.return_value = mock_response

            with unittest.mock.patch.object(movie_common.urllib.request, "urlopen", return_value=mock_response):
                manifest = movie_common.build_plan(root, tmdb_api_key="fake_key")

        self.assertEqual(manifest["actions"], [])
        self.assertEqual(manifest["review"][0]["reason"], "missing-year-review-required")
        self.assertEqual(manifest["messages"][0]["code"], "tmdb-no-results")

    def test_future_tmdb_match_is_reviewed_as_no_result(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "The Beatles - Live at Shea Stadium 1965 [XviD].avi").write_text("", encoding="utf-8")

            mock_response = unittest.mock.MagicMock()
            mock_response.read.return_value = b'{"results": [{"id": 1247606, "title": "The Beatles Ringo", "release_date": "2099-01-01"}]}'
            mock_response.__enter__.return_value = mock_response

            with unittest.mock.patch.object(movie_common.urllib.request, "urlopen", return_value=mock_response):
                manifest = movie_common.build_plan(root, tmdb_api_key="fake_key")

        self.assertEqual(manifest["actions"], [])
        self.assertEqual(manifest["review"][0]["reason"], "missing-year-review-required")
        self.assertEqual(manifest["messages"][0]["code"], "tmdb-no-results")

    def test_collection_suffix_tmdb_match_requires_strong_title_overlap(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            folder = root / "The Traveling Wilburys - The True History Of The Traveling Wilburys"
            folder.mkdir()
            (folder / "#Concert The Traveling Wilburys - The True History Of The Traveling Wilburys (dansker) DVDto.avi").write_text("", encoding="utf-8")

            mock_response = unittest.mock.MagicMock()
            mock_response.read.return_value = b'{"results": [{"id": 1081915, "title": "The Traveling Wilburys Collection", "release_date": "2007-01-01"}]}'
            mock_response.__enter__.return_value = mock_response

            with unittest.mock.patch.object(movie_common.urllib.request, "urlopen", return_value=mock_response):
                manifest = movie_common.build_plan(root, tmdb_api_key="fake_key")

        self.assertEqual(manifest["actions"], [])
        self.assertEqual(manifest["review"][0]["reason"], "missing-year-review-required")
        self.assertEqual(manifest["messages"][0]["code"], "tmdb-no-results")

    def test_cached_distant_tmdb_match_is_ignored(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "I'm Here.avi").write_text("", encoding="utf-8")
            cache_path = root / movie_common.DEFAULT_CACHE_NAME
            cache_path.write_text(
                json.dumps({"I'm Here|": {"id": 43939, "title": "I'm Still Here", "year": "2010"}}),
                encoding="utf-8",
            )

            mock_response = unittest.mock.MagicMock()
            mock_response.read.return_value = b'{"results": []}'
            mock_response.__enter__.return_value = mock_response

            with unittest.mock.patch.object(movie_common.urllib.request, "urlopen", return_value=mock_response):
                manifest = movie_common.build_plan(root, cache_path=cache_path, tmdb_api_key="fake_key")

        self.assertEqual(manifest["actions"], [])
        self.assertEqual(manifest["review"][0]["reason"], "missing-year-review-required")
        self.assertEqual(manifest["messages"][0]["code"], "tmdb-no-results")

    def test_cached_future_tmdb_match_is_ignored(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "The Beatles - Live at Shea Stadium 1965 [XviD].avi").write_text("", encoding="utf-8")
            cache_path = root / movie_common.DEFAULT_CACHE_NAME
            cache_path.write_text(
                json.dumps({"The Beatles|": {"id": 1247606, "title": "The Beatles Ringo", "year": "2099"}}),
                encoding="utf-8",
            )

            mock_response = unittest.mock.MagicMock()
            mock_response.read.return_value = b'{"results": []}'
            mock_response.__enter__.return_value = mock_response

            with unittest.mock.patch.object(movie_common.urllib.request, "urlopen", return_value=mock_response):
                manifest = movie_common.build_plan(root, cache_path=cache_path, tmdb_api_key="fake_key")

        self.assertEqual(manifest["actions"], [])
        self.assertEqual(manifest["review"][0]["reason"], "missing-year-review-required")
        self.assertEqual(manifest["messages"][0]["code"], "tmdb-no-results")

    def test_cached_none_does_not_hide_later_tmdb_result(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            folder = root / "Raul O Inicio O Fim e o Meio"
            folder.mkdir()
            (folder / "Raul.O.Inicio.O.Fim.e.o.Meio.DVDRip.XviD-3LT0N.avi").write_text("", encoding="utf-8")
            cache_path = root / movie_common.DEFAULT_CACHE_NAME
            cache_path.write_text(json.dumps({"Raul O Inicio O Fim E O Meio|": None}), encoding="utf-8")

            mock_response = unittest.mock.MagicMock()
            mock_response.read.return_value = b'{"results": [{"id": 84198, "title": "Raul: O Inicio, O Fim e o Meio", "release_date": "2012-03-23"}]}'
            mock_response.__enter__.return_value = mock_response

            with unittest.mock.patch.object(movie_common.urllib.request, "urlopen", return_value=mock_response) as urlopen:
                manifest = movie_common.build_plan(root, cache_path=cache_path, tmdb_api_key="fake_key")

        self.assertEqual(len(manifest["actions"]), 1)
        self.assertEqual(manifest["actions"][0]["tmdb_id"], 84198)
        self.assertEqual(manifest["messages"], [])
        urlopen.assert_called_once()


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

    def test_cli_prints_tmdb_warnings_to_stderr(self):
        cli_path = MOVIES_DIR / "normalize-movies-folders.py"
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            folder = root / "Raul O Inicio O Fim e o Meio"
            folder.mkdir()
            (folder / "Raul.O.Inicio.O.Fim.e.o.Meio.DVDRip.XviD-3LT0N.avi").write_text("", encoding="utf-8")
            env = dict(os.environ)
            env.pop("TMDB_API_KEY", None)

            dry_run = subprocess.run(
                [sys.executable, str(cli_path), "--root", str(root)],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
            )

        self.assertEqual(dry_run.returncode, 0, dry_run.stderr)
        self.assertIn("Warning:", dry_run.stderr)
        self.assertIn("TMDB_API_KEY is not configured", dry_run.stderr)

    def test_cli_exits_nonzero_when_configured_tmdb_lookup_fails(self):
        cli_path = MOVIES_DIR / "normalize-movies-folders.py"
        spec = importlib.util.spec_from_file_location("normalize_movies_folders", cli_path)
        self.assertIsNotNone(spec)
        cli = importlib.util.module_from_spec(spec)
        self.assertIsNotNone(spec.loader)
        spec.loader.exec_module(cli)

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            folder = root / "Raul O Inicio O Fim e o Meio"
            folder.mkdir()
            (folder / "Raul.O.Inicio.O.Fim.e.o.Meio.DVDRip.XviD-3LT0N.avi").write_text("", encoding="utf-8")
            stderr = io.StringIO()

            with unittest.mock.patch.dict(os.environ, {"TMDB_API_KEY": "fake-key"}):
                with unittest.mock.patch.object(movie_common.urllib.request, "urlopen", side_effect=OSError("Connection refused")):
                    with contextlib.redirect_stderr(stderr):
                        exit_code = cli.main(["--root", str(root)])

        self.assertNotEqual(exit_code, 0)
        self.assertIn("Error:", stderr.getvalue())
        self.assertIn("TMDB search failed", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
