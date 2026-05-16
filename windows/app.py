"""YouTube Downloader — Windows-friendly Flask backend.

When packaged with PyInstaller, the executable lives next to bundled
`bin/yt-dlp.exe` and `bin/ffmpeg.exe`. We tell yt-dlp where to find them.
"""
from __future__ import annotations

import os
import re
import sys
import threading
import time
import uuid
import webbrowser
from pathlib import Path

from flask import Flask, jsonify, render_template, request, send_from_directory


# ---------------------------------------------------------------------------
# Paths

def app_dir() -> Path:
    """Folder where bundled resources live (templates, bin/...)."""
    if getattr(sys, "frozen", False):
        # PyInstaller --onedir layout: resources are next to the exe.
        # --onefile: resources are extracted to sys._MEIPASS.
        return Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
    return Path(__file__).resolve().parent


BASE_DIR = app_dir()
DOWNLOAD_DIR = Path.home() / "Downloads" / "YTDownloader"
DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)

BIN_DIR = BASE_DIR / "bin"
YT_DLP = BIN_DIR / ("yt-dlp.exe" if os.name == "nt" else "yt-dlp")
FFMPEG = BIN_DIR / ("ffmpeg.exe" if os.name == "nt" else "ffmpeg")
FFPROBE = BIN_DIR / ("ffprobe.exe" if os.name == "nt" else "ffprobe")


# Make sure yt-dlp can find ffmpeg even when invoked as a Python module.
if FFMPEG.exists():
    os.environ["PATH"] = f"{BIN_DIR};{os.environ.get('PATH', '')}" if os.name == "nt" \
        else f"{BIN_DIR}:{os.environ.get('PATH', '')}"


# Import yt_dlp lazily so PyInstaller picks it up correctly
from yt_dlp import YoutubeDL  # noqa: E402


app = Flask(
    __name__,
    template_folder=str(BASE_DIR / "templates"),
    static_folder=str(BASE_DIR / "static") if (BASE_DIR / "static").exists() else None,
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
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def progress_hook(job_id: str):
    def hook(d):
        with JOBS_LOCK:
            job = JOBS.get(job_id)
            if not job:
                return
            status = d.get("status")
            if status == "downloading":
                job["status"] = "downloading"
                job["percent"] = ANSI_RE.sub("", d.get("_percent_str") or "").strip()
                job["speed"] = ANSI_RE.sub("", d.get("_speed_str") or "").strip()
                job["eta"] = ANSI_RE.sub("", d.get("_eta_str") or "").strip()
                info = d.get("info_dict") or {}
                if not job.get("title"):
                    job["title"] = info.get("title")
            elif status == "finished":
                job["status"] = "processing"
                job["percent"] = "100%"
                fn = d.get("filename")
                if fn:
                    job["filename"] = os.path.basename(fn)
    return hook


YDL_BASE = {
    "quiet": True,
    "no_warnings": True,
    "noplaylist": True,
}
if FFMPEG.exists():
    YDL_BASE["ffmpeg_location"] = str(FFMPEG.parent)


COMMON_HEIGHTS = [2160, 1440, 1080, 720, 480, 360, 240]


def probe_url(url: str) -> dict:
    with YoutubeDL({**YDL_BASE, "skip_download": True}) as ydl:
        info = ydl.extract_info(url, download=False)

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


def build_format(height, audio_only: bool) -> str:
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


def run_download(job_id: str, url: str, height, audio_only: bool):
    outtmpl = str(DOWNLOAD_DIR / "%(title)s [%(id)s].%(ext)s")
    ydl_opts = {
        **YDL_BASE,
        "outtmpl": outtmpl,
        "progress_hooks": [progress_hook(job_id)],
        "retries": 3,
        "format": build_format(height, audio_only),
    }
    if audio_only:
        ydl_opts["postprocessors"] = [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": "mp3",
            "preferredquality": "192",
        }]
    else:
        ydl_opts["merge_output_format"] = "mp4"
    try:
        with YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=True)
            final = ydl.prepare_filename(info)
            if audio_only:
                final = os.path.splitext(final)[0] + ".mp3"
            with JOBS_LOCK:
                JOBS[job_id]["status"] = "done"
                JOBS[job_id]["filename"] = os.path.basename(final)
                JOBS[job_id]["title"] = info.get("title") or JOBS[job_id].get("title")
    except Exception as e:
        with JOBS_LOCK:
            JOBS[job_id]["status"] = "error"
            JOBS[job_id]["error"] = str(e)


# ---------------------------------------------------------------------------
# Routes

@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/info", methods=["POST"])
def api_info():
    url = (request.get_json(silent=True) or {}).get("url", "").strip()
    if not url:
        return jsonify({"error": "missing url"}), 400
    try:
        return jsonify(probe_url(url))
    except Exception as e:
        return jsonify({"error": str(e)}), 400


@app.route("/api/download", methods=["POST"])
def api_download():
    data = request.get_json(silent=True) or {}
    url = (data.get("url") or "").strip()
    height = data.get("height")
    audio_only = bool(data.get("audio_only"))
    if isinstance(height, str) and height.isdigit():
        height = int(height)
    if not isinstance(height, int):
        height = None
    if not url:
        return jsonify({"error": "missing url"}), 400
    job_id = uuid.uuid4().hex[:12]
    with JOBS_LOCK:
        JOBS[job_id] = {"status": "queued", "url": url, "height": height, "audio_only": audio_only}
    threading.Thread(target=run_download, args=(job_id, url, height, audio_only), daemon=True).start()
    return jsonify({"job_id": job_id})


@app.route("/api/status/<job_id>")
def api_status(job_id: str):
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        return (jsonify(job), 200) if job else (jsonify({"error": "unknown job"}), 404)


@app.route("/api/list")
def api_list():
    files = []
    for p in sorted(DOWNLOAD_DIR.iterdir(), key=lambda x: x.stat().st_mtime, reverse=True):
        if p.is_file() and not p.name.startswith("."):
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


def wait_for_server(timeout: float = 6.0) -> bool:
    """Poll the API until it responds (or timeout)."""
    import urllib.request
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            urllib.request.urlopen(URL + "/api/list", timeout=0.5).read()
            return True
        except Exception:
            time.sleep(0.1)
    return False


def run_server():
    """Background thread: run the Flask app via waitress (production WSGI)."""
    try:
        from waitress import serve
        serve(app, host="127.0.0.1", port=PORT, threads=8, _quiet=True)
    except ImportError:
        app.run(host="127.0.0.1", port=PORT, debug=False)


def find_browser_for_app_mode() -> str | None:
    """Find Edge or Chrome — both support --app= which opens a URL in a frameless window
    that looks like a native desktop app (no tabs, no address bar, dedicated taskbar entry)."""
    candidates = [
        # Microsoft Edge (always installed on Windows 10/11)
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        # Chrome — typical installs
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        os.path.expandvars(r"%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"),
    ]
    for path in candidates:
        if os.path.exists(path):
            return path
    return None


def main():
    threading.Thread(target=run_server, daemon=True).start()
    if not wait_for_server():
        print("Server failed to start within 6 seconds.")
        return

    browser = find_browser_for_app_mode()
    if browser:
        # --app= opens the URL in its own window, no browser chrome. When the user
        # closes the window, this subprocess returns and main() exits, which kills
        # the Flask daemon thread cleanly.
        profile_dir = os.path.join(os.environ.get("LOCALAPPDATA", os.getcwd()), "YTDownloader", "BrowserProfile")
        os.makedirs(profile_dir, exist_ok=True)
        import subprocess
        subprocess.run([
            browser,
            f"--app={URL}",
            f"--user-data-dir={profile_dir}",
            "--window-size=820,900",
            "--no-first-run",
            "--no-default-browser-check",
        ])
        return

    # Fallback: default browser (Chrome/Edge/Firefox) — opens as a regular tab.
    webbrowser.open(URL)
    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
