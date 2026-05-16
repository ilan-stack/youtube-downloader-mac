#!/bin/bash
# Download the bundled binaries (yt-dlp, ffmpeg, ffprobe) into ./Resources/.
# These are kept out of git because they're too large.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/Resources"
mkdir -p "$RES"

echo ">> Fetching yt-dlp (universal binary)"
curl -fL --retry 3 -o "$RES/yt-dlp" \
  https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos
chmod +x "$RES/yt-dlp"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo ">> Fetching ffmpeg (evermeet.cx static build)"
curl -fL --retry 3 -o "$TMP/ffmpeg.zip" \
  "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip"
unzip -q -o "$TMP/ffmpeg.zip" -d "$TMP"
mv "$TMP/ffmpeg" "$RES/ffmpeg"
chmod +x "$RES/ffmpeg"

echo ">> Fetching ffprobe (evermeet.cx static build)"
curl -fL --retry 3 -o "$TMP/ffprobe.zip" \
  "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip"
unzip -q -o "$TMP/ffprobe.zip" -d "$TMP"
mv "$TMP/ffprobe" "$RES/ffprobe"
chmod +x "$RES/ffprobe"

echo ""
echo "Done. Versions:"
"$RES/yt-dlp" --version 2>/dev/null | sed 's/^/  yt-dlp:  /'
"$RES/ffmpeg" -version 2>/dev/null | head -1 | sed 's/^/  /'
"$RES/ffprobe" -version 2>/dev/null | head -1 | sed 's/^/  /'
