"""YouTube Downloader — Windows backend with full feature parity to the macOS app.

Bundles yt-dlp.exe + ffmpeg.exe via PyInstaller and serves a Flask UI rendered
inside Edge --app mode (frameless native-looking window).

Features (matches the macOS SwiftUI app):
  - Quality picker with file size estimates per option
  - Audio-only extraction (mp3 192k)
  - Trim by start/end timestamps
  - Subtitles: human + auto-translated, English always included, second language toggle
  - Browser cookies (Chrome/Edge/Firefox/Brave) to bypass YouTube rate limits
  - "Make compatible" mp4 re-encoder (H.264/AAC, 1080p cap, faststart)
  - Inline AVKit-style HTML5 player with subtitle toggle
  - Cancel any in-progress job
  - Self-update yt-dlp binary
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import threading
import time
import uuid
import urllib.request
import webbrowser
from pathlib import Path

from flask import Flask, jsonify, render_template, request, send_from_directory


# ---------------------------------------------------------------------------
# Paths

def app_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
    return Path(__file__).resolve().parent


BASE_DIR = app_dir()
DOWNLOAD_DIR = Path.home() / "Downloads" / "YTDownloader"
DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)

USER_BIN = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "YTDownloader" / "bin"
USER_BIN.mkdir(parents=True, exist_ok=True)


def resolve_binary(name: str) -> Path:
    """User override first, then bundled."""
    user_path = USER_BIN / f"{name}.exe"
    if user_path.exists():
        return user_path
    return BASE_DIR / "bin" / f"{name}.exe"


# Make sure ffmpeg is on PATH for subprocess invocations
BIN_DIR = BASE_DIR / "bin"
if BIN_DIR.exists():
    os.environ["PATH"] = f"{BIN_DIR};{os.environ.get('PATH', '')}"


# ---------------------------------------------------------------------------
# Flask

app = Flask(
    __name__,
    template_folder=str(BASE_DIR / "templates"),
)


@app.after_request
def add_cors(resp):
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Access-Control-Allow-Methods"] = "GET, POST, DELETE, OPTIONS"
    resp.headers["Access-Control-Allow-Headers"] = "Content-Type"
    return resp


@app.route("/api/<path:_p>", methods=["OPTIONS"])
def cors_preflight(_p):
    return ("", 204)


# ---------------------------------------------------------------------------
# Job tracking

JOBS: dict[str, dict] = {}
JOBS_LOCK = threading.Lock()
PROCESSES: dict[str, subprocess.Popen] = {}
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
PROG_RE = re.compile(r"^PROG\|([^|]*)\|([^|]*)\|(.*)$")
FINAL_RE = re.compile(r"^FINAL\|(.*)$")


COMMON_HEIGHTS = [2160, 1440, 1080, 720, 480, 360, 240]

SUBTITLE_LANGUAGES = [
    ("en", "English"),
    ("iw", "Hebrew"),
    ("es", "Spanish"),
    ("fr", "French"),
    ("de", "German"),
    ("it", "Italian"),
    ("pt", "Portuguese"),
    ("ru", "Russian"),
    ("ar", "Arabic"),
    ("ja", "Japanese"),
    ("ko", "Korean"),
    ("zh-Hans", "Chinese (Simplified)"),
    ("zh-Hant", "Chinese (Traditional)"),
    ("hi", "Hindi"),
    ("tr", "Turkish"),
    ("nl", "Dutch"),
    ("pl", "Polish"),
    ("sv", "Swedish"),
    ("uk", "Ukrainian"),
]
BROWSER_CHOICES = [
    ("", "None"),
    ("chrome", "Chrome"),
    ("edge", "Edge"),
    ("firefox", "Firefox"),
    ("brave", "Brave"),
    ("chromium", "Chromium"),
]


def _yt_dlp_base_args() -> list[str]:
    return ["--no-warnings", "--no-playlist", "--newline"]


def _ffmpeg_location_args() -> list[str]:
    ffmpeg = resolve_binary("ffmpeg")
    return ["--ffmpeg-location", str(ffmpeg.parent)] if ffmpeg.exists() else []


def _format_string(height, audio_only: bool) -> str:
    if audio_only:
        return "bestaudio/best"
    if height:
        return (
            f"bestvideo[height<={height}][vcodec^=avc1]+bestaudio[ext=m4a]"
            f"/best[height<={height}][vcodec^=avc1]"
            f"/bestvideo[height<={height}][ext=mp4]+bestaudio[ext=m4a]"
            f"/best[height<={height}][ext=mp4]"
            f"/best[height<={height}]"
        )
    return "bestvideo[vcodec^=avc1]+bestaudio[ext=m4a]/best[vcodec^=avc1]/best[ext=mp4]/best"


# ---------------------------------------------------------------------------
# Probe

def probe_url(url: str, cookies_from_browser: str = "") -> dict:
    yt = resolve_binary("yt-dlp")
    args = [str(yt), *_yt_dlp_base_args(), "--skip-download", "--dump-single-json", *_ffmpeg_location_args()]
    if cookies_from_browser:
        args += ["--cookies-from-browser", cookies_from_browser]
    args.append(url)
    res = subprocess.run(args, capture_output=True, text=True, timeout=60,
                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if res.returncode != 0:
        raise RuntimeError(res.stderr.strip() or f"yt-dlp exited {res.returncode}")
    import json
    info = json.loads(res.stdout)

    formats = info.get("formats") or []
    audio_only = [f for f in formats if (f.get("acodec") or "none") != "none" and (f.get("vcodec") or "none") == "none"]
    best_audio = max(audio_only, key=lambda f: f.get("abr") or 0, default=None)
    audio_size = (best_audio.get("filesize") or best_audio.get("filesize_approx") or 0) if best_audio else 0

    video_fmts = [f for f in formats if (f.get("vcodec") or "none") != "none" and f.get("height")]
    progressive = [f for f in video_fmts if (f.get("acodec") or "none") != "none"]
    video_only = [f for f in video_fmts if (f.get("acodec") or "none") == "none"]
    max_h = max((f["height"] for f in video_fmts), default=0)

    presets = []
    for h in COMMON_HEIGHTS:
        if h > max_h:
            continue
        v_cands = [f for f in video_only if f["height"] <= h]
        p_cands = [f for f in progressive if f["height"] <= h]
        best_v = max(v_cands, key=lambda f: (f["height"], f.get("tbr") or 0), default=None)
        best_p = max(p_cands, key=lambda f: (f["height"], f.get("tbr") or 0), default=None)
        actual_h = max(best_v["height"] if best_v else 0, best_p["height"] if best_p else 0)
        if actual_h != h:
            continue
        size = 0
        if best_v:
            size = (best_v.get("filesize") or best_v.get("filesize_approx") or 0) + audio_size
        elif best_p:
            size = best_p.get("filesize") or best_p.get("filesize_approx") or 0
        presets.append({"label": f"{h}p", "height": h, "audio_only": False,
                        "size_mb": round(size / 1024 / 1024, 1) if size else None})
    presets.append({"label": "Audio (mp3)", "height": 0, "audio_only": True,
                    "size_mb": round(audio_size / 1024 / 1024, 1) if audio_size else None})

    return {
        "title": info.get("title"),
        "duration": info.get("duration"),
        "thumbnail": info.get("thumbnail"),
        "uploader": info.get("uploader"),
        "presets": presets,
    }


# ---------------------------------------------------------------------------
# Download — runs yt-dlp as a subprocess with line-by-line progress parsing

def run_download(job_id: str, url: str, opts: dict):
    yt = resolve_binary("yt-dlp")
    outtmpl = str(DOWNLOAD_DIR / "%(title)s [%(id)s].%(ext)s")
    height = opts.get("height")
    audio_only = bool(opts.get("audio_only"))

    args = [str(yt), *_yt_dlp_base_args(),
            "--progress",
            "--progress-template", "PROG|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "-o", outtmpl,
            "-f", _format_string(height, audio_only),
            "--retries", "3",
            *_ffmpeg_location_args()]

    if audio_only:
        args += ["-x", "--audio-format", "mp3", "--audio-quality", "192K"]
    else:
        args += ["--merge-output-format", "mp4"]

    # Subtitles — always include English, optionally add a second language. Embed into mp4.
    inc_human = bool(opts.get("include_human_subtitles"))
    inc_auto = bool(opts.get("include_auto_subtitles"))
    if inc_human or inc_auto:
        if inc_human:
            args.append("--write-subs")
        if inc_auto:
            args.append("--write-auto-subs")
        user_lang = (opts.get("subtitle_language") or "en").strip()
        lang_parts = ["en.*", "en"]
        if user_lang and user_lang != "en":
            lang_parts += [f"{user_lang}.*", user_lang]
        args += [
            "--embed-subs",
            "--sub-langs", ",".join(lang_parts),
            "--convert-subs", "srt",
            "--sleep-subtitles", "2",
            "--ignore-errors",
        ]

    # Trim — yt-dlp's --download-sections with --force-keyframes-at-cuts
    start = (opts.get("start_time") or "").strip()
    end = (opts.get("end_time") or "").strip()
    if start or end:
        args += ["--download-sections", f"*{start}-{end}", "--force-keyframes-at-cuts"]

    cookies = (opts.get("cookies_from_browser") or "").strip()
    if cookies:
        args += ["--cookies-from-browser", cookies]

    args += ["--print", "after_move:FINAL|%(filepath)s"]
    args.append(url)

    final_path = None
    sub_warning = None

    try:
        proc = subprocess.Popen(
            args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        with JOBS_LOCK:
            PROCESSES[job_id] = proc

        for line in proc.stdout:
            line = line.strip()
            m = PROG_RE.match(line)
            if m:
                pct = ANSI_RE.sub("", m.group(1)).strip()
                spd = ANSI_RE.sub("", m.group(2)).strip()
                eta = ANSI_RE.sub("", m.group(3)).strip()
                with JOBS_LOCK:
                    if job_id in JOBS:
                        JOBS[job_id].update(status="downloading", percent=pct, speed=spd, eta=eta)
                continue
            m = FINAL_RE.match(line)
            if m:
                final_path = m.group(1)
                with JOBS_LOCK:
                    if job_id in JOBS:
                        JOBS[job_id]["status"] = "processing"

        stderr = proc.stderr.read() or ""
        proc.wait()

        with JOBS_LOCK:
            PROCESSES.pop(job_id, None)

        if proc.returncode != 0:
            cancelled = proc.returncode in (1, -1, 15) and "Cancelled" in JOBS.get(job_id, {}).get("error", "")
            with JOBS_LOCK:
                if job_id in JOBS and JOBS[job_id].get("status") != "cancelled":
                    JOBS[job_id]["status"] = "error"
                    JOBS[job_id]["error"] = (stderr[:500] or f"exit {proc.returncode}").strip()
            return

        # Detect subtitle rate-limit
        if (inc_human or inc_auto) and "HTTP Error 429" in stderr and "subtitles" in stderr:
            sub_warning = "Subtitles blocked by YouTube rate limit (HTTP 429). Wait ~30 min and try again."
        elif (inc_human or inc_auto) and "Unable to download video subtitles" in stderr:
            sub_warning = "Subtitles unavailable for this video in the chosen language."

        with JOBS_LOCK:
            if job_id in JOBS:
                JOBS[job_id]["status"] = "done"
                if final_path:
                    JOBS[job_id]["filename"] = os.path.basename(final_path)
                if sub_warning:
                    JOBS[job_id]["warning"] = sub_warning
    except Exception as e:
        with JOBS_LOCK:
            if job_id in JOBS:
                JOBS[job_id]["status"] = "error"
                JOBS[job_id]["error"] = str(e)
            PROCESSES.pop(job_id, None)


# ---------------------------------------------------------------------------
# Convert — re-encode to universally-compatible mp4 (H.264 + AAC + faststart)

def media_duration(file: Path) -> float:
    ffprobe = resolve_binary("ffprobe")
    if not ffprobe.exists():
        return 0.0
    res = subprocess.run(
        [str(ffprobe), "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(file)],
        capture_output=True, text=True, timeout=30,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    try:
        return float(res.stdout.strip())
    except ValueError:
        return 0.0


def run_convert(job_id: str, src_path: str):
    src = Path(src_path)
    if not src.exists():
        with JOBS_LOCK:
            JOBS[job_id]["status"] = "error"
            JOBS[job_id]["error"] = f"Source not found: {src_path}"
        return

    ffmpeg = resolve_binary("ffmpeg")
    if not ffmpeg.exists():
        with JOBS_LOCK:
            JOBS[job_id]["status"] = "error"
            JOBS[job_id]["error"] = "ffmpeg not bundled"
        return

    out = src.with_name(f"{src.stem} (compatible).mp4")
    n = 2
    while out.exists():
        out = src.with_name(f"{src.stem} (compatible {n}).mp4")
        n += 1

    dur = media_duration(src)
    args = [
        str(ffmpeg), "-y", "-i", str(src),
        "-c:v", "libx264", "-preset", "medium", "-crf", "23",
        "-profile:v", "main", "-level", "4.0", "-pix_fmt", "yuv420p",
        "-vf", "scale='min(1920,iw)':-2",
        "-c:a", "aac", "-b:a", "128k",
        "-movflags", "+faststart",
        "-progress", "pipe:1", "-nostats",
        str(out),
    ]
    try:
        proc = subprocess.Popen(
            args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        with JOBS_LOCK:
            PROCESSES[job_id] = proc
            JOBS[job_id]["status"] = "downloading"
            JOBS[job_id]["percent"] = "0%"

        for line in proc.stdout:
            line = line.strip()
            if line.startswith("out_time_us="):
                try:
                    us = float(line.split("=", 1)[1])
                except ValueError:
                    us = 0
                secs = us / 1_000_000
                pct = min(1.0, secs / dur) if dur else 0
                with JOBS_LOCK:
                    if job_id in JOBS:
                        JOBS[job_id]["percent"] = f"{pct*100:.0f}%"
                        rem = max(0, dur - secs)
                        JOBS[job_id]["eta"] = f"{int(rem)//60}:{int(rem)%60:02d}"
            elif line == "progress=end":
                with JOBS_LOCK:
                    if job_id in JOBS:
                        JOBS[job_id]["status"] = "processing"

        stderr = proc.stderr.read() or ""
        proc.wait()
        with JOBS_LOCK:
            PROCESSES.pop(job_id, None)

        if proc.returncode != 0:
            with JOBS_LOCK:
                if job_id in JOBS and JOBS[job_id].get("status") != "cancelled":
                    JOBS[job_id]["status"] = "error"
                    JOBS[job_id]["error"] = (stderr[:500] or f"ffmpeg exit {proc.returncode}").strip()
            return

        with JOBS_LOCK:
            if job_id in JOBS:
                JOBS[job_id]["status"] = "done"
                JOBS[job_id]["filename"] = out.name
    except Exception as e:
        with JOBS_LOCK:
            if job_id in JOBS:
                JOBS[job_id]["status"] = "error"
                JOBS[job_id]["error"] = str(e)
            PROCESSES.pop(job_id, None)


# ---------------------------------------------------------------------------
# yt-dlp self-update

def run_yt_dlp_update(job_id: str):
    url = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"
    dest = USER_BIN / "yt-dlp.exe"
    tmp = USER_BIN / "yt-dlp.download"
    try:
        with JOBS_LOCK:
            JOBS[job_id]["status"] = "downloading"
            JOBS[job_id]["percent"] = "0%"

        req = urllib.request.Request(url, headers={"User-Agent": "YTDownloader/1.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            total = int(resp.headers.get("Content-Length") or 0)
            written = 0
            with open(tmp, "wb") as f:
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    f.write(chunk)
                    written += len(chunk)
                    if total > 0:
                        pct = 100 * written / total
                        with JOBS_LOCK:
                            if job_id in JOBS:
                                JOBS[job_id]["percent"] = f"{pct:.0f}%"

        if written < 1_000_000:
            tmp.unlink(missing_ok=True)
            raise RuntimeError(f"downloaded file too small ({written} bytes)")

        if dest.exists():
            dest.unlink()
        tmp.rename(dest)

        ver = subprocess.run([str(dest), "--version"], capture_output=True, text=True, timeout=20,
                              creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        new_ver = ver.stdout.strip() or "(unknown)"

        with JOBS_LOCK:
            if job_id in JOBS:
                JOBS[job_id]["status"] = "done"
                JOBS[job_id]["title"] = f"yt-dlp updated to {new_ver}"
    except Exception as e:
        with JOBS_LOCK:
            if job_id in JOBS:
                JOBS[job_id]["status"] = "error"
                JOBS[job_id]["error"] = str(e)


# ---------------------------------------------------------------------------
# Routes

@app.route("/")
def index():
    return render_template(
        "index.html",
        subtitle_languages=SUBTITLE_LANGUAGES,
        browser_choices=BROWSER_CHOICES,
    )


@app.route("/api/info", methods=["POST"])
def api_info():
    data = request.get_json(silent=True) or {}
    url = (data.get("url") or "").strip()
    cookies = (data.get("cookies_from_browser") or "").strip()
    if not url:
        return jsonify({"error": "missing url"}), 400
    try:
        return jsonify(probe_url(url, cookies))
    except Exception as e:
        return jsonify({"error": str(e)}), 400


@app.route("/api/download", methods=["POST"])
def api_download():
    data = request.get_json(silent=True) or {}
    url = (data.get("url") or "").strip()
    if not url:
        return jsonify({"error": "missing url"}), 400
    height = data.get("height")
    if isinstance(height, str) and height.isdigit():
        height = int(height)
    if not isinstance(height, int):
        height = None

    opts = {
        "height": height,
        "audio_only": bool(data.get("audio_only")),
        "include_human_subtitles": bool(data.get("include_human_subtitles")),
        "include_auto_subtitles": bool(data.get("include_auto_subtitles")),
        "subtitle_language": data.get("subtitle_language") or "en",
        "start_time": data.get("start_time") or "",
        "end_time": data.get("end_time") or "",
        "cookies_from_browser": data.get("cookies_from_browser") or "",
    }
    job_id = uuid.uuid4().hex[:12]
    with JOBS_LOCK:
        JOBS[job_id] = {"kind": "download", "status": "queued", "url": url}
    threading.Thread(target=run_download, args=(job_id, url, opts), daemon=True).start()
    return jsonify({"job_id": job_id})


@app.route("/api/convert", methods=["POST"])
def api_convert():
    data = request.get_json(silent=True) or {}
    filename = (data.get("filename") or "").strip()
    if not filename:
        return jsonify({"error": "missing filename"}), 400
    src = DOWNLOAD_DIR / filename
    if not src.exists() or not src.is_file():
        return jsonify({"error": "file not found"}), 404
    job_id = uuid.uuid4().hex[:12]
    with JOBS_LOCK:
        JOBS[job_id] = {"kind": "convert", "status": "queued", "title": f"Converting: {filename}"}
    threading.Thread(target=run_convert, args=(job_id, str(src)), daemon=True).start()
    return jsonify({"job_id": job_id})


@app.route("/api/update-yt-dlp", methods=["POST"])
def api_update():
    job_id = uuid.uuid4().hex[:12]
    with JOBS_LOCK:
        JOBS[job_id] = {"kind": "update", "status": "queued", "title": "Updating yt-dlp…"}
    threading.Thread(target=run_yt_dlp_update, args=(job_id,), daemon=True).start()
    return jsonify({"job_id": job_id})


@app.route("/api/cancel/<job_id>", methods=["POST"])
def api_cancel(job_id: str):
    with JOBS_LOCK:
        proc = PROCESSES.get(job_id)
        if proc and proc.poll() is None:
            proc.terminate()
            if job_id in JOBS:
                JOBS[job_id]["status"] = "cancelled"
                JOBS[job_id]["error"] = "Cancelled"
            return jsonify({"cancelled": True})
    return jsonify({"cancelled": False}), 404


@app.route("/api/version")
def api_version():
    yt = resolve_binary("yt-dlp")
    if not yt.exists():
        return jsonify({"version": "?"})
    try:
        res = subprocess.run([str(yt), "--version"], capture_output=True, text=True, timeout=10,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        return jsonify({"version": res.stdout.strip() or "?"})
    except Exception:
        return jsonify({"version": "?"})


@app.route("/api/status/<job_id>")
def api_status(job_id: str):
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        return (jsonify(job), 200) if job else (jsonify({"error": "unknown"}), 404)


@app.route("/api/list")
def api_list():
    media_exts = {"mp4", "mov", "mkv", "webm", "avi", "m4v", "flv",
                  "mp3", "m4a", "wav", "aac", "ogg", "flac", "opus"}
    sidecar_exts = {"srt", "vtt", "json", "info", "description"}
    # Clean zero-byte sidecars
    for p in DOWNLOAD_DIR.iterdir():
        if p.is_file() and p.suffix.lstrip(".").lower() in sidecar_exts and p.stat().st_size == 0:
            try:
                p.unlink()
            except OSError:
                pass
    files = []
    for p in sorted(DOWNLOAD_DIR.iterdir(), key=lambda x: x.stat().st_mtime, reverse=True):
        if not p.is_file() or p.name.startswith("."):
            continue
        if p.suffix.lstrip(".").lower() not in media_exts:
            continue
        files.append({"name": p.name, "size_mb": round(p.stat().st_size / 1024 / 1024, 1)})
    return jsonify(files)


@app.route("/api/files", methods=["DELETE"])
def api_clear_files():
    deleted = 0
    for p in DOWNLOAD_DIR.iterdir():
        if p.is_file() and not p.name.startswith("."):
            try:
                p.unlink()
                deleted += 1
            except OSError:
                pass
    return jsonify({"deleted": deleted})


@app.route("/file/<path:filename>")
def serve_file(filename: str):
    return send_from_directory(DOWNLOAD_DIR, filename, as_attachment=True)


@app.route("/stream/<path:filename>")
def stream_file(filename: str):
    return send_from_directory(DOWNLOAD_DIR, filename, conditional=True)


# ---------------------------------------------------------------------------
# Launch

PORT = 8768
URL = f"http://127.0.0.1:{PORT}"


def wait_for_server(timeout: float = 30.0) -> bool:
    """Poll until the server is up. First-run launches need a generous timeout because
    PyInstaller --onefile extracts to %TEMP% and Windows Defender often scans the .exe."""
    deadline = time.time() + timeout
    consecutive_ok = 0
    while time.time() < deadline:
        try:
            urllib.request.urlopen(URL + "/api/list", timeout=0.5).read()
            consecutive_ok += 1
            # Require two successful pings — guards against the brief window between
            # socket().bind() and the server actually serving requests.
            if consecutive_ok >= 2:
                return True
            time.sleep(0.1)
        except Exception:
            consecutive_ok = 0
            time.sleep(0.15)
    return False


def run_server():
    try:
        from waitress import serve
        serve(app, host="127.0.0.1", port=PORT, threads=8, _quiet=True)
    except ImportError:
        app.run(host="127.0.0.1", port=PORT, debug=False)


def find_browser_for_app_mode() -> str | None:
    candidates = [
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        os.path.expandvars(r"%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"),
    ]
    for path in candidates:
        if os.path.exists(path):
            return path
    return None


LOADING_HTML = """<!doctype html>
<html><head>
<meta charset="utf-8">
<title>YouTube Downloader</title>
<style>
  html,body{margin:0;height:100%;background:#0f1115;color:#e6e6e6;
    font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif;}
  .center{height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px;}
  .spinner{width:42px;height:42px;border:3px solid #262a33;border-top-color:#4c8bf5;
    border-radius:50%;animation:spin 1s linear infinite;}
  @keyframes spin{to{transform:rotate(360deg);}}
  .title{font-size:18px;font-weight:600;letter-spacing:-0.02em;}
  .sub{font-size:12px;color:#8a8f99;}
</style>
</head><body>
<div class="center">
  <div class="spinner"></div>
  <div class="title">YouTube Downloader</div>
  <div class="sub" id="msg">Starting up…</div>
</div>
<script>
const URL = "__URL__";
const msg = document.getElementById('msg');
let tries = 0;
async function check() {
  tries++;
  try {
    const r = await fetch(URL + "/api/list", { cache: "no-store" });
    if (r.ok) { location.replace(URL); return; }
  } catch (e) {}
  if (tries > 5) msg.textContent = "Still starting up (this can take a moment on first launch)…";
  setTimeout(check, 400);
}
check();
</script>
</body></html>"""


def write_loading_html() -> str:
    """Write the splash page to %TEMP% and return its absolute path."""
    import tempfile
    path = os.path.join(tempfile.gettempdir(), "YTDownloader_loading.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(LOADING_HTML.replace("__URL__", URL))
    return path


def main():
    threading.Thread(target=run_server, daemon=True).start()
    browser = find_browser_for_app_mode()
    if browser:
        profile_dir = os.path.join(os.environ.get("LOCALAPPDATA", os.getcwd()), "YTDownloader", "BrowserProfile")
        os.makedirs(profile_dir, exist_ok=True)
        # Open the splash page FIRST. Its inline JS polls the API and redirects
        # to the real URL once the server is up. This avoids the brief window
        # where Edge would otherwise hit ERR_CONNECTION_REFUSED on cold start.
        loading_path = write_loading_html()
        loading_url = "file:///" + loading_path.replace("\\", "/").lstrip("/")
        subprocess.run([
            browser, f"--app={loading_url}", f"--user-data-dir={profile_dir}",
            "--window-size=820,900", "--no-first-run", "--no-default-browser-check",
        ])
        return

    # Headless fallback — wait for server then open default browser.
    wait_for_server()
    webbrowser.open(URL)
    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
