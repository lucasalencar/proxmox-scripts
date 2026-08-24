# qBittorrent

Download client for the media server stack.

## References

- [TRaSH Guides - Getting Started](https://trash-guides.info/Getting-Started/)
- [TRaSH Guides - Hardlinks and Instant Moves](https://trash-guides.info/File-and-Folder-Structure/Hardlinks-and-Instant-Moves/)
- [TRaSH Guides - Docker Folder Structure](https://trash-guides.info/File-and-Folder-Structure/How-to-set-up/Docker/)
- [TRaSH Guides - qBittorrent Basic Setup](https://trash-guides.info/Downloaders/qBittorrent/Basic-Setup/)
- [TRaSH Guides - qBittorrent Paths](https://trash-guides.info/Downloaders/qBittorrent/Paths/)
- [TRaSH Guides - qBittorrent Categories](https://trash-guides.info/Downloaders/qBittorrent/How-to-add-categories/)

## Install

```bash
bash qbittorrent/install.sh
```

## Update

```bash
bash qbittorrent/update.sh
```

## Post-Install Configuration

Follow the [TRaSH Guides - qBittorrent Basic Setup](https://trash-guides.info/Downloaders/qBittorrent/Basic-Setup/) for the recommended settings. Key points:

### Downloads > Saving Management

| Setting | Value |
|---|---|
| Default Torrent Management Mode | Automatic |
| Default Save Path | `/data/downloads` |
| Keep incomplete torrents in | (personal preference) |

### Categories

| Category | Save Path |
|---|---|
| series | `/data/downloads/series` |
| movies | `/data/downloads/movies` |
| music | `/data/downloads/music` |

### Connection > Listening Port

| Setting | Value |
|---|---|
| Protocol | TCP |
| Port | 6881 (or your VPN forwarded port) |
| Use UPnP / NAT-PMP | Disabled |

### BitTorrent > Privacy

| Setting | Value |
|---|---|
| Encryption | Allow encryption |
| Anonymous Mode | Disabled |

## Folder Structure

```
/tank/data/                  →  /data/ (inside container)
├── downloads/               →  /data/downloads/
│   ├── series/
│   ├── movies/
│   └── music/
└── media/                   →  /data/media/
    ├── Series/
    ├── Movies/
    └── Music/
```

Hardlinks work because `/data/downloads` and `/data/media` are mounted as a single filesystem via `/tank/data → /data`.
