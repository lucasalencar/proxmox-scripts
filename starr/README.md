# Starr Stack

Single LXC container bundling all Servarr apps: **Prowlarr + Sonarr + Radarr + Bazarr** (Core set). Managed as one unit to save RAM/disk and guarantee hardlinks via a single ZFS dataset.

This implements [TRaSH Guides — Getting Started Step 3](https://trash-guides.info/Getting-Started/#3-set-up-your-official-arr-apps) without creating 4 separate LXCs.

## References

- [TRaSH Guides - Getting Started](https://trash-guides.info/Getting-Started/)
- [TRaSH Guides - Hardlinks and Instant Moves](https://trash-guides.info/File-and-Folder-Structure/Hardlinks-and-Instant-Moves/)
- [TRaSH Guides - Docker Folder Structure](https://trash-guides.info/File-and-Folder-Structure/How-to-set-up/Docker/) (adapted to LXC `/data`)
- [Prowlarr Wiki](https://wiki.servarr.com/prowlarr)
- [Sonarr Wiki](https://wiki.servarr.com/sonarr)
- [Radarr Wiki](https://wiki.servarr.com/radarr)
- [Bazarr Docs](https://wiki.bazarr.media/)

## Install

```bash
bash starr/install.sh
```

See `starr/install.sh` for what each step does.

## Update

```bash
bash starr/update.sh
```

See `starr/update.sh` for details.

## Ports & Caddy

| Service | Port | Hostname |
|---|---|---|
| Prowlarr | 9696 | `prowlarr.marx.home` |
| Sonarr | 8989 | `sonarr.marx.home` |
| Radarr | 7878 | `radarr.marx.home` |
| Bazarr | 6767 | `bazarr.marx.home` |

Single CT = single IP, 4 ports. `caddy/generate-caddyfile.sh:138` only auto-detects one port per CT (`ss -tlnp | head -1`), so you must add 4 entries manually after generation.

Append to `caddy/Caddyfile.local` (replace `<IP>` with `starr` IP from install log):

```
prowlarr.marx.home {
    tls internal
    reverse_proxy <IP>:9696
}
sonarr.marx.home {
    tls internal
    reverse_proxy <IP>:8989
}
radarr.marx.home {
    tls internal
    reverse_proxy <IP>:7878
}
bazarr.marx.home {
    tls internal
    reverse_proxy <IP>:6767
}
```

Then:

```bash
bash caddy/generate-caddyfile.sh   # or manually: pct push <caddy-id> caddy/Caddyfile.local /etc/caddy/Caddyfile && pct exec <caddy-id> -- systemctl reload caddy
```

## Folder Structure

```
/tank/data/mediaserver/      ->  /data/  (inside starr, single dataset)
├── downloads/               ->  /data/downloads/   (qBittorrent save path)
│   ├── series/              # Sonarr category "series"
│   ├── movies/              # Radarr category "movies"
│   ├── music/               # Lidarr (future)
│   └── shows/
└── media/                   ->  /data/media/      (Arr root folders + Jellyfin libraries)
    ├── Series/              # Sonarr Root Folder: /data/media/Series
    ├── Movies/              # Radarr Root Folder: /data/media/Movies
    ├── Music/
    └── Shows/
```

Hardlinks/instant moves work because source (`/data/downloads/...`) and destination (`/data/media/...`) are on the same filesystem (`/tank/data/mediaserver`).

## Post-Install Configuration (TRaSH Guides)

Follow the install log plus:

### 1. qBittorrent categories (already set via `qbittorrent/README.md:40`)

- Default Save Path: `/data/downloads`
- Categories: `series -> /data/downloads/series`, `movies -> /data/downloads/movies`

### 2. Prowlarr

- Settings -> Apps -> Add Sonarr/Radarr: `http://localhost:8989` and `http://localhost:7878` (same CT, localhost is fastest)
- Add indexers, then sync to Sonarr/Radarr

### 3. Sonarr / Radarr

- Settings -> Media Management -> Root Folder: `/data/media/Series` and `/data/media/Movies`
- Settings -> Media Management -> Naming — use [TRaSH Recommended Naming](https://trash-guides.info/Radarr/Radarr-recommended-naming-scheme/) / [Sonarr Scheme](https://trash-guides.info/Sonarr/Sonarr-recommended-naming-scheme/)
- Quality Settings: [Radarr File Size](https://trash-guides.info/Radarr/Radarr-Quality-Settings-File-Size/) / [Sonarr File Size](https://trash-guides.info/Sonarr/Sonarr-Quality-Settings-File-Size/)
- Quality Profiles + Custom Formats: [Radarr Profiles](https://trash-guides.info/Radarr/radarr-setup-quality-profiles/) / [Sonarr Profiles](https://trash-guides.info/Sonarr/sonarr-setup-quality-profiles/) — can be automated via [Guide Sync](https://trash-guides.info/Guide-Sync/) (Recyclarr)

### 4. Bazarr

- Settings -> Sonarr/Radarr -> Test connection (again `localhost`)
- Languages -> Add desired subtitle languages
- Providers -> Add OpenSubtitles etc.

### 5. Jellyfin

Already mounted `jellyfin/install.sh:26` at `/DATA/Media` and `/DATA/Gallery`. Add libraries pointing to `/DATA/Media/Movies` and `/DATA/Media/Series` (or `/data/media` if you also mount `mediaserver` there).

## Verification

```bash
# Inside starr CT
pct exec $(pct list | grep -i starr | awk "{print \$1}") -- systemctl status prowlarr sonarr radarr bazarr
pct exec $(pct list | grep -i starr | awk "{print \$1}") -- ss -tlnp | grep -E "9696|8989|7878|6767"
# Host ACL check
getfacl /tank/data/mediaserver | grep -E "1000|100000|10[0-9]{4}"
# Hardlink test (inside CT): ln /data/downloads/series/test.mkv /data/media/Series/test.mkv && ls -i both should share inode
```

## Resources

- Default: 4 cores / 4096 MB / 20 GB. Adjust `CT_CORES`/`CT_MEMORY`/`CT_DISK`/`CT_SWAP` in `starr/install.sh` if needed.
- All 4 apps share the same resource pool — more efficient than 4 x 1024 MB CTs.
