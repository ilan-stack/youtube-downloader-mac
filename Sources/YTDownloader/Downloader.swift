import Foundation

enum DownloaderError: LocalizedError {
    case binaryNotFound(String)
    case probeFailed(String)
    case downloadFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name): return "\(name) not found"
        case .probeFailed(let m): return "Could not fetch video info: \(m)"
        case .downloadFailed(let m): return "Download failed: \(m)"
        case .cancelled: return "Cancelled"
        }
    }
}

struct DownloadOptions {
    var preset: QualityPreset?
    var startTime: String?     // e.g. "1:23" or "01:23:45"
    var endTime: String?
    var includeHumanSubtitles: Bool = false
    var includeAutoSubtitles: Bool = false
    var subtitleLanguage: String = "en"  // ISO code: en, iw, he, es, fr, de, etc.
    var cookiesFromBrowser: String? = nil  // "chrome", "safari", "firefox", "brave", "edge", "chromium"
    var cookiesFile: URL? = nil  // Netscape-format cookies.txt exported from a browser extension
}

enum Downloader {

    // MARK: - Paths

    /// Writable directory for user-updated binaries (yt-dlp self-update).
    static func userBinDir() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("YTDownloader", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }

    /// yt-dlp lookup: user-updated copy > bundle > project Resources (dev).
    static func ytDlpURL() -> URL? {
        let userCopy = userBinDir().appendingPathComponent("yt-dlp")
        if FileManager.default.isExecutableFile(atPath: userCopy.path) {
            return userCopy
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/yt-dlp")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        // Dev fallback: look up from executable
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<6 {
            guard let d = dir else { break }
            let candidate = d.appendingPathComponent("Resources/yt-dlp")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }

    /// ffmpeg lookup: bundled > Homebrew > system.
    static func ffmpegURL() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ffmpeg")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        // Dev fallback
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<6 {
            guard let d = dir else { break }
            let candidate = d.appendingPathComponent("Resources/ffmpeg")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }

    /// deno lookup: bundled > Homebrew > system. yt-dlp uses deno to solve
    /// YouTube's "n challenge" — without it, downloads with cookies often fail
    /// with "Requested format is not available".
    static func denoURL() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/deno")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for path in ["/opt/homebrew/bin/deno", "/usr/local/bin/deno", "/usr/bin/deno"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<6 {
            guard let d = dir else { break }
            let candidate = d.appendingPathComponent("Resources/deno")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }

    /// Returns an environment dict with bundled binary dirs prepended to PATH so
    /// yt-dlp can locate deno / ffmpeg via PATH lookup.
    static func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var pathDirs: [String] = []
        if let dir = denoURL()?.deletingLastPathComponent().path { pathDirs.append(dir) }
        if let dir = ffmpegURL()?.deletingLastPathComponent().path { pathDirs.append(dir) }
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (pathDirs + [existing]).joined(separator: ":")
        return env
    }

    /// ffprobe lookup: bundled > Homebrew > system.
    static func ffprobeURL() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ffprobe")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for path in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<6 {
            guard let d = dir else { break }
            let candidate = d.appendingPathComponent("Resources/ffprobe")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }

    static func downloadsDirectory() -> URL {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("YTDownloader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - yt-dlp probe / download

    static func probe(url: String) async throws -> VideoInfo {
        guard let binary = ytDlpURL() else { throw DownloaderError.binaryNotFound("yt-dlp") }

        var args = ["--no-warnings", "--no-playlist", "--skip-download", "--dump-single-json", url]
        if let ffmpeg = ffmpegURL() {
            args.insert(contentsOf: ["--ffmpeg-location", ffmpeg.deletingLastPathComponent().path], at: 0)
        }
        let result = try await runProcess(executable: binary, arguments: args)
        guard result.exitCode == 0 else {
            throw DownloaderError.probeFailed(result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr)
        }
        let data = result.stdout.data(using: .utf8) ?? Data()
        do {
            return try JSONDecoder().decode(VideoInfo.self, from: data)
        } catch {
            throw DownloaderError.probeFailed("could not parse yt-dlp output: \(error.localizedDescription)")
        }
    }

    static func presets(from info: VideoInfo) -> [QualityPreset] {
        let commonHeights = [2160, 1440, 1080, 720, 480, 360, 240]
        let formats = info.formats ?? []
        let audioOnly = formats.filter { ($0.acodec ?? "none") != "none" && ($0.vcodec ?? "none") == "none" }
        let bestAudio = audioOnly.max(by: { ($0.abr ?? 0) < ($1.abr ?? 0) })
        let audioSize = (bestAudio?.filesize ?? bestAudio?.filesizeApprox ?? 0)
        let videoFormats = formats.filter { ($0.vcodec ?? "none") != "none" && $0.height != nil }
        let progressive = videoFormats.filter { ($0.acodec ?? "none") != "none" }
        let videoOnly = videoFormats.filter { ($0.acodec ?? "none") == "none" }
        let maxHeight = videoFormats.map { $0.height ?? 0 }.max() ?? 0

        var presets: [QualityPreset] = []
        for h in commonHeights where h <= maxHeight {
            let vCandidates = videoOnly.filter { ($0.height ?? 0) <= h }
            let pCandidates = progressive.filter { ($0.height ?? 0) <= h }
            let bestV = vCandidates.max(by: { ($0.height ?? 0, $0.tbr ?? 0) < ($1.height ?? 0, $1.tbr ?? 0) })
            let bestP = pCandidates.max(by: { ($0.height ?? 0, $0.tbr ?? 0) < ($1.height ?? 0, $1.tbr ?? 0) })
            let actualH = max(bestV?.height ?? 0, bestP?.height ?? 0)
            guard actualH == h else { continue }
            var size: Int64 = 0
            if let bv = bestV {
                size = (bv.filesize ?? bv.filesizeApprox ?? 0) + audioSize
            } else if let bp = bestP {
                size = bp.filesize ?? bp.filesizeApprox ?? 0
            }
            presets.append(QualityPreset(id: "v\(h)", label: "\(h)p", height: h, audioOnly: false,
                                         sizeBytes: size > 0 ? size : nil))
        }
        presets.append(QualityPreset(id: "audio", label: "Audio (mp3)", height: nil, audioOnly: true,
                                     sizeBytes: audioSize > 0 ? audioSize : nil))
        return presets
    }

    static func formatString(for preset: QualityPreset?) -> String {
        guard let preset = preset else {
            return "bestvideo[vcodec^=avc1]+bestaudio[ext=m4a]/best[vcodec^=avc1]/best[ext=mp4]/best"
        }
        if preset.audioOnly { return "bestaudio/best" }
        if let h = preset.height {
            return [
                "bestvideo[height<=\(h)][vcodec^=avc1]+bestaudio[ext=m4a]",
                "best[height<=\(h)][vcodec^=avc1]",
                "bestvideo[height<=\(h)][ext=mp4]+bestaudio[ext=m4a]",
                "best[height<=\(h)][ext=mp4]",
                "best[height<=\(h)]",
            ].joined(separator: "/")
        }
        return "bestvideo[vcodec^=avc1]+bestaudio[ext=m4a]/best[vcodec^=avc1]/best[ext=mp4]/best"
    }

    struct DownloadResult {
        let url: URL
        let warning: String?
    }

    static func download(
        url: String,
        options: DownloadOptions,
        onProcess: @escaping (Process) -> Void = { _ in },
        progress: @escaping (DownloadStatus) -> Void
    ) async throws -> DownloadResult {
        guard let binary = ytDlpURL() else { throw DownloaderError.binaryNotFound("yt-dlp") }

        let outDir = downloadsDirectory()
        let template = outDir.appendingPathComponent("%(title)s [%(id)s].%(ext)s").path

        var args = [
            "--no-warnings", "--no-playlist", "--newline",
            "--progress",
            "--progress-template", "PROG|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "-o", template,
            "-f", formatString(for: options.preset),
        ]
        if let file = options.cookiesFile {
            args.append(contentsOf: ["--cookies", file.path])
        } else if let browser = options.cookiesFromBrowser {
            args.append(contentsOf: ["--cookies-from-browser", browser])
        }
        if options.preset?.audioOnly == true {
            args.append(contentsOf: ["-x", "--audio-format", "mp3", "--audio-quality", "192K"])
        } else {
            args.append(contentsOf: ["--merge-output-format", "mp4"])
        }
        if let ffmpeg = ffmpegURL() {
            args.append(contentsOf: ["--ffmpeg-location", ffmpeg.deletingLastPathComponent().path])
        }
        if options.includeHumanSubtitles || options.includeAutoSubtitles {
            // Embed subtitles into the mp4 (mov_text track) so any player shows a CC button.
            // Always include English; if the user picked a different language, append it too
            // — both get embedded so the player can toggle between them.
            if options.includeHumanSubtitles { args.append("--write-subs") }
            if options.includeAutoSubtitles { args.append("--write-auto-subs") }
            var langParts = ["en.*", "en"]
            let userLang = options.subtitleLanguage
            if userLang != "en" {
                langParts.append("\(userLang).*")
                langParts.append(userLang)
            }
            args.append(contentsOf: [
                "--embed-subs",
                "--sub-langs", langParts.joined(separator: ","),
                "--convert-subs", "srt",
                "--sleep-subtitles", "2",
                "--ignore-errors",
            ])
        }
        if options.startTime != nil || options.endTime != nil {
            let s = options.startTime ?? ""
            let e = options.endTime ?? ""
            args.append(contentsOf: ["--download-sections", "*\(s)-\(e)", "--force-keyframes-at-cuts"])
        }
        args.append(contentsOf: ["--print", "after_move:FINAL|%(filepath)s"])
        args.append(url)

        var finalPath: String?
        var subtitleWarning: String?
        let result = try await streamProcess(
            executable: binary, arguments: args,
            onProcess: onProcess,
            onLine: { line in
                if line.hasPrefix("PROG|") {
                    let parts = line.dropFirst(5).split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                    if parts.count >= 3 {
                        let pctStr = parts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
                        let pct = (Double(pctStr) ?? 0) / 100.0
                        progress(.downloading(
                            percent: pct,
                            speed: parts[1].trimmingCharacters(in: .whitespaces),
                            eta: parts[2].trimmingCharacters(in: .whitespaces)
                        ))
                    }
                } else if line.hasPrefix("FINAL|") {
                    finalPath = String(line.dropFirst(6))
                    progress(.processing)
                }
            }
        )

        // Surface a clear warning when subtitles failed but the video succeeded.
        if options.includeHumanSubtitles || options.includeAutoSubtitles {
            let err = result.stderr
            if err.contains("HTTP Error 429") && err.contains("subtitles") {
                subtitleWarning = "Subtitles blocked by YouTube rate limit (HTTP 429). Wait ~30 min and try again."
            } else if err.contains("Unable to download video subtitles") {
                subtitleWarning = "Subtitles unavailable for this video in the chosen language."
            }
        }

        if result.exitCode == 15 || result.exitCode == -1 {
            throw DownloaderError.cancelled
        }
        guard result.exitCode == 0 else {
            throw DownloaderError.downloadFailed(result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr)
        }
        guard let path = finalPath else {
            throw DownloaderError.downloadFailed("no final path reported")
        }
        let fileURL = URL(fileURLWithPath: path)
        progress(.done(fileURL))
        return DownloadResult(url: fileURL, warning: subtitleWarning)
    }

    // MARK: - Convert to compatible mp4

    static func mediaDuration(of file: URL) async throws -> Double {
        guard let ffprobe = ffprobeURL() else { return 0 }
        let res = try await runProcess(executable: ffprobe, arguments: [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", file.path,
        ])
        return Double(res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    static func convertToCompatibleMP4(
        input: URL,
        onProcess: @escaping (Process) -> Void = { _ in },
        progress: @escaping (DownloadStatus) -> Void
    ) async throws -> URL {
        guard let ffmpeg = ffmpegURL() else {
            throw DownloaderError.binaryNotFound("ffmpeg")
        }
        let outDir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        var output = outDir.appendingPathComponent("\(base) (compatible).mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: output.path) {
            output = outDir.appendingPathComponent("\(base) (compatible \(counter)).mp4")
            counter += 1
        }
        let duration = (try? await mediaDuration(of: input)) ?? 0

        let args = [
            "-y", "-i", input.path,
            "-c:v", "libx264", "-preset", "medium", "-crf", "23",
            "-profile:v", "main", "-level", "4.0", "-pix_fmt", "yuv420p",
            "-vf", "scale='min(1920,iw)':-2",
            "-c:a", "aac", "-b:a", "128k",
            "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats",
            output.path,
        ]
        progress(.downloading(percent: 0, speed: "", eta: ""))
        let res = try await streamProcess(executable: ffmpeg, arguments: args, onProcess: onProcess, onLine: { line in
            if line.hasPrefix("out_time_us=") {
                let v = Double(line.dropFirst("out_time_us=".count)) ?? 0
                let secs = v / 1_000_000
                let pct = duration > 0 ? min(1.0, secs / duration) : 0
                progress(.downloading(percent: pct, speed: "",
                                      eta: fmtETA(remaining: max(0, duration - secs))))
            } else if line == "progress=end" {
                progress(.processing)
            }
        })
        if res.exitCode == 15 || res.exitCode == -1 { throw DownloaderError.cancelled }
        guard res.exitCode == 0 else {
            throw DownloaderError.downloadFailed("ffmpeg exited \(res.exitCode): \(res.stderr.prefix(400))")
        }
        progress(.done(output))
        return output
    }

    private static func fmtETA(remaining: Double) -> String {
        let s = Int(remaining.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - yt-dlp self-update

    static func currentYtDlpVersion() async throws -> String {
        guard let binary = ytDlpURL() else { throw DownloaderError.binaryNotFound("yt-dlp") }
        let res = try await runProcess(executable: binary, arguments: ["--version"])
        return res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Download the latest yt-dlp_macos universal binary into the user override dir.
    static func updateYtDlp(progress: @escaping (Double) -> Void) async throws -> String {
        let url = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
        let dest = userBinDir().appendingPathComponent("yt-dlp")
        let tmp = userBinDir().appendingPathComponent("yt-dlp.download")

        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        let expected = response.expectedContentLength
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tmp) else {
            throw DownloaderError.downloadFailed("cannot open temp file")
        }
        defer { try? handle.close() }
        var written: Int64 = 0
        var buffer = Data()
        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 65536 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 {
                    progress(Double(written) / Double(expected))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        try handle.close()
        if written < 1_000_000 {
            try? FileManager.default.removeItem(at: tmp)
            throw DownloaderError.downloadFailed("downloaded file too small (\(written) bytes)")
        }
        // Make executable + atomic rename
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
        progress(1.0)

        // Get the new version
        let res = try await runProcess(executable: dest, arguments: ["--version"])
        return res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Process helpers

    struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    static func runProcess(executable: URL, arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = processEnvironment()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            let outBox = DataBox()
            let errBox = DataBox()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { outBox.append(data) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { errBox.append(data) }
            }
            process.terminationHandler = { _ in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let outTail = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errTail = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                outBox.append(outTail)
                errBox.append(errTail)
                cont.resume(returning: ProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: outBox.snapshot(), encoding: .utf8) ?? "",
                    stderr: String(data: errBox.snapshot(), encoding: .utf8) ?? ""
                ))
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    static func streamProcess(
        executable: URL,
        arguments: [String],
        onProcess: @escaping (Process) -> Void = { _ in },
        onLine: @escaping (String) -> Void
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = processEnvironment()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            let stderrBox = DataBox()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                if let s = String(data: data, encoding: .utf8) {
                    for line in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                        let trimmed = String(line)
                        if !trimmed.isEmpty { DispatchQueue.main.async { onLine(trimmed) } }
                    }
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { stderrBox.append(data) }
            }
            process.terminationHandler = { _ in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let stderr = String(data: stderrBox.snapshot(), encoding: .utf8) ?? ""
                cont.resume(returning: ProcessResult(exitCode: process.terminationStatus, stdout: "", stderr: stderr))
            }
            do {
                try process.run()
                onProcess(process)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
