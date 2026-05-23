# Movie Folder Normalizer

`normalize-movies-folders.py` scans a movie library and proposes folder names in the portable format:

```text
Movie Title (Year)
```

The tool is intentionally conservative:

- dry-run is the default and does not modify files;
- applying changes requires a reviewed JSON plan with `--apply --plan`;
- video, subtitle, image, `.nfo`, and `.txt` file names are preserved by default;
- grouping folders such as collections, directors, genres, and series are kept in place while child movie folders are normalized;
- subtitle synchronization or subtitle renaming is out of scope.

## Requirements

- Python 3.10 or newer.
- Run as a regular non-root user.
- Optional: `TMDB_API_KEY` for TMDb lookup when a local year cannot be inferred.

No third-party Python packages are required.

## Dry Run

Generate a manifest and review report:

```bash
python3 media-organizer/normalize-movies-folders.py --root /path/to/Movies
```

This writes the following files inside the movie root unless you override their paths:

- `.movie-organizer-plan.json`: the reviewed manifest used for apply mode;
- `.movie-organizer-review.csv`: a spreadsheet-friendly review report;
- `.movie-organizer-cache.json`: cached TMDb search results.

You can choose explicit output paths:

```bash
python3 media-organizer/normalize-movies-folders.py \
  --root /path/to/Movies \
  --plan /path/to/plan.json \
  --review-csv /path/to/review.csv \
  --cache /path/to/cache.json
```

## Apply

Apply only after reviewing the generated plan:

```bash
python3 media-organizer/normalize-movies-folders.py --root /path/to/Movies --apply --plan /path/to/plan.json
```

Apply mode:

- renames movie folders from deepest to shallowest;
- moves loose video files into newly created movie folders;
- refuses target collisions;
- preserves every internal file name.

## TMDb Lookup

Local parsing is used first. When a movie year is missing, set `TMDB_API_KEY` to allow TMDb search:

```bash
export TMDB_API_KEY="your-token"
python3 media-organizer/normalize-movies-folders.py --root /path/to/Movies
```

The filesystem target still uses only `Title (Year)`. TMDb IDs are kept in the manifest/cache for auditability, not in folder names.

## Tests

Run the automated tests with the Python standard library:

```bash
python3 -m unittest discover -s media-organizer/tests -v
```
