# Third-Party Software

This application bundles the following third-party tools. They are downloaded
on demand by `scripts/fetch-binaries.sh` and packaged inside the `.app` bundle.

## yt-dlp

- **Source**: https://github.com/yt-dlp/yt-dlp
- **License**: The Unlicense (public domain)
- **Role**: All YouTube interaction — metadata probing and media download.

## ffmpeg / ffprobe

- **Source**: https://evermeet.cx/ffmpeg/ (static macOS builds maintained by Helmut K. C. Tessarek)
- **License**: GPL-3.0 (because the build includes GPL-licensed components such
  as `libx264`).
- **Role**: Merging video + audio streams, "Make compatible" mp4 re-encoding,
  duration probing for conversion progress.

Because the bundled `ffmpeg` is GPL-3.0, any distribution of the resulting
`.app` or `.dmg` is also subject to the GPL terms. Source for `ffmpeg` is
available at https://ffmpeg.org/download.html — we use the upstream binary
unmodified.

## App icon

Original SVG by the project author. Free to reuse under the same MIT terms as
the rest of the project.
