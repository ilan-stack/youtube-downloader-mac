import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var urlText: String = ""
    @Published var info: VideoInfo?
    @Published var presets: [QualityPreset] = []
    @Published var selectedPresetID: String? = nil
    @Published var probeStatus: ProbeStatus = .idle

    // Advanced options
    @Published var startTime: String = ""
    @Published var endTime: String = ""
    @Published var includeHumanSubtitles: Bool = true
    @Published var includeAutoSubtitles: Bool = false
    @Published var subtitleLanguage: String = "en"
    @Published var cookiesFromBrowser: String = ""   // "" = none
    @Published var showAdvanced: Bool = false

    static let browserChoices: [(code: String, label: String)] = [
        ("", "None"),
        ("chrome", "Chrome"),
        ("safari", "Safari"),
        ("firefox", "Firefox"),
        ("brave", "Brave"),
        ("edge", "Edge"),
        ("chromium", "Chromium"),
    ]

    static let subtitleLanguages: [(code: String, label: String)] = [
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

    @Published var jobs: [Job] = []
    @Published var files: [DownloadedFile] = []
    @Published var playerURL: URL?
    @Published var playerName: String = ""

    @Published var ytDlpVersion: String = "?"
    @Published var statusToast: String?   // transient status messages

    enum ProbeStatus: Equatable {
        case idle, loading, ready, error(String)
    }

    private var probeTask: Task<Void, Never>?
    private var activeProcesses: [UUID: Process] = [:]

    init() {
        refreshFiles()
        Task { await self.refreshVersion() }
        // Auto-fill from clipboard when app becomes active.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tryClipboardAutofill() }
        }
        tryClipboardAutofill()
    }

    func refreshVersion() async {
        if let v = try? await Downloader.currentYtDlpVersion() {
            self.ytDlpVersion = v
        }
    }

    // MARK: - URL / probe

    func onURLChanged() {
        probeTask?.cancel()
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            info = nil; presets = []; selectedPresetID = nil; probeStatus = .idle
            return
        }
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            probeStatus = .idle
            return
        }
        probeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self = self else { return }
            await self.probe(url: trimmed)
        }
    }

    func probe(url: String) async {
        probeStatus = .loading
        do {
            let info = try await Downloader.probe(url: url)
            self.info = info
            self.presets = Downloader.presets(from: info)
            self.selectedPresetID = nil
            self.probeStatus = .ready
        } catch {
            self.info = nil; self.presets = []; self.selectedPresetID = nil
            self.probeStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Clipboard

    func tryClipboardAutofill() {
        guard urlText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let clipboard = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let looksLikeYouTube = lower.contains("youtube.com/") || lower.contains("youtu.be/")
        guard looksLikeYouTube,
              (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
        else { return }
        urlText = trimmed
        onURLChanged()
    }

    // MARK: - Download

    func startDownload() {
        let url = urlText.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        let preset = presets.first(where: { $0.id == selectedPresetID })
        let opts = DownloadOptions(
            preset: preset,
            startTime: startTime.trimmingCharacters(in: .whitespaces).isEmpty ? nil : startTime.trimmingCharacters(in: .whitespaces),
            endTime: endTime.trimmingCharacters(in: .whitespaces).isEmpty ? nil : endTime.trimmingCharacters(in: .whitespaces),
            includeHumanSubtitles: includeHumanSubtitles,
            includeAutoSubtitles: includeAutoSubtitles,
            subtitleLanguage: subtitleLanguage,
            cookiesFromBrowser: cookiesFromBrowser.isEmpty ? nil : cookiesFromBrowser
        )

        let job = Job(kind: .download, displayTitle: info?.title ?? url)
        jobs.insert(job, at: 0)
        let jobID = job.id

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let result = try await Downloader.download(
                    url: url, options: opts,
                    onProcess: { [weak self] proc in
                        Task { @MainActor in self?.activeProcesses[jobID] = proc }
                    },
                    progress: { status in
                        Task { @MainActor in self.updateJob(id: jobID, status: status) }
                    }
                )
                self.refreshFiles()
                if let warning = result.warning {
                    self.flashToast(warning)
                }
            } catch is CancellationError {
                self.updateJob(id: jobID, status: .error("Cancelled"))
            } catch {
                if let de = error as? DownloaderError, case .cancelled = de {
                    self.updateJob(id: jobID, status: .error("Cancelled"))
                } else {
                    self.updateJob(id: jobID, status: .error(error.localizedDescription))
                }
            }
            self.activeProcesses.removeValue(forKey: jobID)
        }
    }

    func updateJob(id: UUID, status: DownloadStatus) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].status = status
    }

    func cancelJob(_ jobID: UUID) {
        if let proc = activeProcesses[jobID], proc.isRunning {
            proc.terminate()
        }
    }

    // MARK: - Convert

    func convertToCompatible(file fileURL: URL) {
        let job = Job(kind: .convert, displayTitle: "Converting: \(fileURL.lastPathComponent)")
        jobs.insert(job, at: 0)
        let jobID = job.id

        Task { [weak self] in
            guard let self = self else { return }
            do {
                _ = try await Downloader.convertToCompatibleMP4(
                    input: fileURL,
                    onProcess: { [weak self] proc in
                        Task { @MainActor in self?.activeProcesses[jobID] = proc }
                    },
                    progress: { status in
                        Task { @MainActor in self.updateJob(id: jobID, status: status) }
                    }
                )
                self.refreshFiles()
            } catch {
                if let de = error as? DownloaderError, case .cancelled = de {
                    self.updateJob(id: jobID, status: .error("Cancelled"))
                } else {
                    self.updateJob(id: jobID, status: .error(error.localizedDescription))
                }
            }
            self.activeProcesses.removeValue(forKey: jobID)
        }
    }

    func pickAndConvert() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            convertToCompatible(file: url)
        }
    }

    // MARK: - yt-dlp self-update

    func updateYtDlp() {
        let job = Job(kind: .update, displayTitle: "Updating yt-dlp…")
        jobs.insert(job, at: 0)
        let jobID = job.id
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let newVersion = try await Downloader.updateYtDlp(progress: { pct in
                    Task { @MainActor in
                        self.updateJob(id: jobID, status: .downloading(percent: pct, speed: "", eta: ""))
                    }
                })
                self.updateJob(id: jobID, status: .done(URL(fileURLWithPath: "/")))
                self.jobs[self.jobs.firstIndex(where: { $0.id == jobID })!].displayTitle = "yt-dlp updated to \(newVersion)"
                self.ytDlpVersion = newVersion
                self.flashToast("yt-dlp updated to \(newVersion)")
            } catch {
                self.updateJob(id: jobID, status: .error(error.localizedDescription))
            }
        }
    }

    func flashToast(_ message: String) {
        statusToast = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if statusToast == message { statusToast = nil }
        }
    }

    // MARK: - Drag-and-drop

    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard let first = urls.first else { return false }
        if first.isFileURL {
            convertToCompatible(file: first)
            return true
        }
        let s = first.absoluteString
        urlText = s
        onURLChanged()
        return true
    }

    func handleDroppedText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return false }
        urlText = trimmed
        onURLChanged()
        return true
    }

    // MARK: - Files / player

    func resetForm() {
        probeTask?.cancel()
        urlText = ""; info = nil; presets = []; selectedPresetID = nil
        probeStatus = .idle
        startTime = ""; endTime = ""
        includeHumanSubtitles = true; includeAutoSubtitles = false
        subtitleLanguage = "en"
        jobs.removeAll()
    }

    private static let mediaExtensions: Set<String> = [
        "mp4", "mov", "mkv", "webm", "avi", "m4v", "flv",
        "mp3", "m4a", "wav", "aac", "ogg", "flac", "opus",
    ]
    private static let sidecarExtensions: Set<String> = ["srt", "vtt", "json", "info", "description"]

    func refreshFiles() {
        let dir = Downloader.downloadsDirectory()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { files = []; return }

        // Clean up zero-byte sidecar files (failed subtitle downloads etc.)
        for url in contents {
            let ext = url.pathExtension.lowercased()
            guard Self.sidecarExtensions.contains(ext) else { continue }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == 0 {
                try? fm.removeItem(at: url)
            }
        }

        // Re-list after cleanup, keep only media files
        let again = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let entries = again.compactMap { url -> DownloadedFile? in
            let ext = url.pathExtension.lowercased()
            guard Self.mediaExtensions.contains(ext) else { return nil }
            guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return DownloadedFile(
                url: url, name: url.lastPathComponent,
                sizeBytes: Int64(vals.fileSize ?? 0),
                modified: vals.contentModificationDate ?? .distantPast
            )
        }
        files = entries.sorted { $0.modified > $1.modified }
    }

    func clearAllFiles() {
        let dir = Downloader.downloadsDirectory()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in contents { try? fm.removeItem(at: f) }
        refreshFiles()
    }

    func openPlayer(for file: DownloadedFile) { playerURL = file.url; playerName = file.name }
    func closePlayer() { playerURL = nil; playerName = "" }
    func revealInFinder(_ file: DownloadedFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }
}

struct Job: Identifiable {
    enum Kind { case download, convert, update }
    let id = UUID()
    let kind: Kind
    var displayTitle: String
    var status: DownloadStatus = .queued

    var isCancellable: Bool {
        switch status {
        case .queued, .downloading, .processing, .probing: return kind != .update
        default: return false
        }
    }
}
