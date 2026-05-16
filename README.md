# YouTube Downloader

A native macOS app for downloading YouTube videos. Built in Swift + SwiftUI, bundles `yt-dlp` and `ffmpeg`, runs fully offline once installed.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Paste a URL → auto-probe** title, thumbnail, duration, and the actual available qualities (with file sizes shown per option, up to 4K)
- **Audio-only extraction** as 192k mp3
- **Trim** by start/end timestamps (no need to download the full video)
- **Subtitles** in any language YouTube provides — including auto-translated tracks
- **Always-included English captions** when subtitles are on; pick a second language to embed alongside (toggle between them in the player)
- **"Make compatible"** button → re-encodes any video to universally-playable H.264 + AAC mp4 (1080p cap, `+faststart`)
- **Drag-and-drop** YouTube URLs or local video files onto the window
- **Inline AVKit player** with subtitle track selection
- **Cancel** any in-progress download or conversion
- **Self-update yt-dlp** from the Tools menu (`⌘U`) — keeps working when YouTube changes things
- **Browser cookies support** (Chrome/Safari/Firefox/Brave/Edge) to bypass YouTube rate limits using your signed-in session
- **Clipboard auto-fill** — paste-and-go when you focus the app

## Install

1. Download the latest `YouTube Downloader.dmg` from the [Releases](../../releases) page.
2. Open the .dmg → drag **YouTube Downloader** to the **Applications** folder.
3. First launch: right-click the app → **Open** → click **Open** in the Gatekeeper dialog. (The app is ad-hoc signed, not Apple-notarized — this only needs to be done once.)

## Build from source

Requirements: macOS 13+, Xcode Command Line Tools.

```bash
git clone https://github.com/ilan-stack/youtube-downloader-mac.git
cd youtube-downloader-mac
./scripts/fetch-binaries.sh   # downloads yt-dlp + ffmpeg + ffprobe (~200 MB)
./scripts/build.sh            # produces YouTube Downloader.app
./scripts/build.sh dmg        # also produces YouTube Downloader.dmg
```

The build script:
- Runs `swift build -c release`
- Assembles a proper `.app` bundle with `Info.plist`, custom icon, and the bundled binaries in `Contents/Resources/`
- Ad-hoc code-signs the result so Gatekeeper translocation doesn't break paths

To launch in development:

```bash
open "YouTube Downloader.app"
```

## Project layout

```
.
├── Package.swift                       Swift Package Manager manifest
├── Sources/YTDownloader/
│   ├── YTDownloaderApp.swift           App entry + menu commands
│   ├── ContentView.swift               Main UI (input card, player, file list)
│   ├── AppState.swift                  ObservableObject — jobs, files, drag-and-drop
│   ├── Downloader.swift                yt-dlp + ffmpeg process wrappers
│   └── Models.swift                    VideoInfo, QualityPreset, DownloadStatus, etc.
├── Resources/
│   ├── AppIcon.icns                    App icon (committed)
│   ├── yt-dlp                          (downloaded by fetch-binaries.sh)
│   ├── ffmpeg                          (downloaded by fetch-binaries.sh)
│   └── ffprobe                         (downloaded by fetch-binaries.sh)
└── scripts/
    ├── fetch-binaries.sh               One-shot: download the bundled binaries
    └── build.sh                        Build .app, optionally .dmg
```

## How it works

- **Probe**: `yt-dlp --dump-single-json --no-playlist --skip-download` returns the format list; we group it into common heights (240p/360p/480p/720p/1080p/1440p/2160p) and compute realistic combined sizes.
- **Download**: `yt-dlp -f bestvideo[vcodec^=avc1]+bestaudio[ext=m4a]/...` — we prefer the H.264 (`avc1`) codec so AVPlayer can render the result without falling back to audio-only on AV1/VP9 streams.
- **Auto-translated subtitles**: when you request a language different from the video's source (e.g. Hebrew on an English video), YouTube returns its server-side translation track which yt-dlp grabs as `iw-en-...`. Both English and the chosen language are embedded as `mov_text` tracks via `--embed-subs`.
- **Make compatible**: ffmpeg with `-c:v libx264 -preset medium -crf 23 -profile:v main -c:a aac -b:a 128k -movflags +faststart`, capped at 1920px wide.
- **Self-update**: writes the new `yt-dlp` binary to `~/Library/Application Support/YTDownloader/bin/`, which the app prefers over the bundled copy — so the `.app` signature is never invalidated by an update.

## License

MIT — see [LICENSE](LICENSE). Bundled third-party software (`yt-dlp`, `ffmpeg`, `ffprobe`) has its own licenses — see [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md). Note that the bundled ffmpeg build is GPL-3.0, so the resulting `.app` is also subject to GPL terms when distributed.

## Disclaimer

YouTube's Terms of Service prohibit downloading content. This tool is intended for personal use cases that are otherwise permitted (downloading your own uploads, content under Creative Commons or public domain, content explicitly available for offline use, etc.). You are responsible for ensuring your use complies with applicable law and platform terms.
