import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("YouTube Downloader")
                            .font(.system(size: 22, weight: .semibold))
                        Spacer()
                        Text("yt-dlp \(state.ytDlpVersion)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 4)

                    inputCard

                    if state.playerURL != nil {
                        playerCard
                    }

                    filesCard
                }
                .padding(20)
                .frame(maxWidth: 720)
            }
            if let toast = state.statusToast {
                Text(toast)
                    .font(.system(size: 12))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 560, minHeight: 600)
        .background(Color(white: 0.06))
        .preferredColorScheme(.dark)
        .onDrop(of: [.url, .fileURL, .text], delegate: AppDropDelegate(state: state))
    }

    // MARK: - Input card

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("https://youtube.com/watch?v=...", text: $state.urlText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: state.urlText) { _ in state.onURLChanged() }
                .onSubmit { if canDownload { state.startDownload() } }

            infoView

            HStack {
                Picker("", selection: $state.selectedPresetID) {
                    Text("Best available").tag(String?.none)
                    ForEach(state.presets) { p in
                        Text(p.displayLabel).tag(String?.some(p.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 280)

                Button("Download") { state.startDownload() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canDownload)

                Button("Reset") { state.resetForm() }
                    .buttonStyle(.bordered)
            }

            DisclosureGroup(isExpanded: $state.showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Trim:").font(.system(size: 12)).foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        TextField("Start (e.g. 0:30)", text: $state.startTime)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 140)
                        Text("to").foregroundColor(.secondary).font(.system(size: 12))
                        TextField("End (e.g. 2:00)", text: $state.endTime)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 140)
                        Spacer()
                    }
                    HStack(spacing: 16) {
                        Toggle("Human captions", isOn: $state.includeHumanSubtitles)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                            .help("Hand-uploaded subtitles. Accurate but only available on some videos.")
                        Toggle("Auto / translated", isOn: $state.includeAutoSubtitles)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                            .help("YouTube's speech-to-text. When language differs from source, YouTube auto-translates.")
                    }
                    HStack(spacing: 10) {
                        Text("Also include:").font(.system(size: 12)).foregroundColor(.secondary)
                        Picker("", selection: $state.subtitleLanguage) {
                            ForEach(AppState.subtitleLanguages, id: \.code) { lang in
                                Text(lang.code == "en" ? "English only" : lang.label).tag(lang.code)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .disabled(!state.includeHumanSubtitles && !state.includeAutoSubtitles)
                        .help("English is always included. Pick another language to add alongside — toggle between them with the CC button in the player.")
                    }
                    HStack(spacing: 10) {
                        Text("Use cookies from:").font(.system(size: 12)).foregroundColor(.secondary)
                        Picker("", selection: $state.cookiesFromBrowser) {
                            ForEach(AppState.browserChoices, id: \.code) { b in
                                Text(b.label).tag(b.code)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .disabled(state.cookiesFile != nil)
                        .help("Use cookies from a browser's cookie store. Requires the browser to be closed if it's Chrome/Edge. Disabled while a cookies file is set.")
                    }
                    HStack(spacing: 10) {
                        Text("Cookies file:").font(.system(size: 12)).foregroundColor(.secondary)
                        if let file = state.cookiesFile {
                            Text(file.lastPathComponent)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 220, alignment: .leading)
                                .help(file.path)
                            Button { state.clearCookiesFile() } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                            }
                            .buttonStyle(.plain)
                            .help("Clear")
                        } else {
                            Button("Choose cookies.txt…") { state.pickCookiesFile() }
                                .help("Export cookies from your browser with the 'Get cookies.txt LOCALLY' extension and pick the file here. Reliable alternative to the dropdown above.")
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Advanced")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            if !state.jobs.isEmpty {
                VStack(spacing: 8) {
                    ForEach(state.jobs) { job in
                        JobRow(job: job, onCancel: { state.cancelJob(job.id) })
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(Color(white: 0.10))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var infoView: some View {
        switch state.probeStatus {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Fetching info…").foregroundColor(.secondary).font(.system(size: 13))
            }
            .padding(10).background(Color(white: 0.06)).cornerRadius(8)
        case .ready:
            if let info = state.info {
                HStack(spacing: 12) {
                    if let thumb = info.thumbnail, let url = URL(string: thumb) {
                        AsyncImage(url: url) { img in img.resizable().scaledToFill() }
                            placeholder: { Color(white: 0.15) }
                            .frame(width: 100, height: 56)
                            .cornerRadius(6).clipped()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.title ?? "Untitled")
                            .font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(metaLine(info)).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(10).background(Color(white: 0.06)).cornerRadius(8)
            }
        case .error(let msg):
            Text("Could not fetch info: \(msg)")
                .font(.system(size: 12))
                .foregroundColor(Color(red: 0.97, green: 0.45, blue: 0.45))
                .padding(10).background(Color(white: 0.06)).cornerRadius(8)
        }
    }

    private func metaLine(_ info: VideoInfo) -> String {
        var parts: [String] = []
        if let u = info.uploader { parts.append(u) }
        if let d = info.duration, d > 0 { parts.append(formatDuration(d)) }
        return parts.joined(separator: " · ")
    }
    private func formatDuration(_ secs: Double) -> String {
        let s = Int(secs.rounded()); let h = s / 3600; let m = (s % 3600) / 60; let sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    private var canDownload: Bool {
        let url = state.urlText.trimmingCharacters(in: .whitespaces)
        return !url.isEmpty && (url.hasPrefix("http://") || url.hasPrefix("https://"))
    }

    // MARK: - Player

    private var playerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state.playerName).font(.system(size: 13)).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                Button { state.closePlayer() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18))
                }.buttonStyle(.plain)
            }
            if let url = state.playerURL {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(minHeight: 320).cornerRadius(8)
            }
        }
        .padding(16).background(Color(white: 0.10)).cornerRadius(12)
    }

    // MARK: - Files

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RECENT FILES").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary).tracking(0.5)
                Spacer()
                Button("Convert other file…") { state.pickAndConvert() }
                    .buttonStyle(.plain).foregroundColor(.secondary).font(.system(size: 12))
                Button("Clear all") { state.clearAllFiles() }
                    .buttonStyle(.plain).foregroundColor(.secondary).font(.system(size: 12))
                    .disabled(state.files.isEmpty)
            }
            if state.files.isEmpty {
                Text("No downloads yet. (Tip: drag a YouTube URL or a video file here.)")
                    .font(.system(size: 13)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(state.files) { f in
                        FileRow(
                            file: f,
                            onPlay: { state.openPlayer(for: f) },
                            onReveal: { state.revealInFinder(f) },
                            onConvert: { state.convertToCompatible(file: f.url) }
                        )
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .padding(16).background(Color(white: 0.10)).cornerRadius(12)
    }
}

struct JobRow: View {
    let job: Job
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayTitle).font(.system(size: 13)).lineLimit(2)
                Text(statusLine).font(.system(size: 11)).foregroundColor(.secondary).monospacedDigit()
                ProgressView(value: progressValue).progressViewStyle(.linear).tint(.accentColor)
            }
            if job.isCancellable {
                Button { onCancel() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                        .foregroundColor(.secondary)
                }.buttonStyle(.plain).help("Cancel")
            }
        }
        .padding(10).background(Color(white: 0.06)).cornerRadius(8)
    }

    private var progressValue: Double {
        switch job.status {
        case .downloading(let p, _, _): return p
        case .processing, .done: return 1.0
        default: return 0
        }
    }
    private var statusLine: String {
        switch job.status {
        case .queued: return "Queued…"
        case .probing: return "Probing…"
        case .downloading(let p, let speed, let eta):
            var parts = [String(format: "%.0f%%", p * 100)]
            if !speed.isEmpty { parts.append(speed) }
            if !eta.isEmpty { parts.append("ETA \(eta)") }
            return parts.joined(separator: " · ")
        case .processing: return "Processing…"
        case .done(let url): return url.path == "/" ? "Done" : "Done → \(url.lastPathComponent)"
        case .error(let m): return "Error: \(m)"
        }
    }
}

struct FileRow: View {
    let file: DownloadedFile
    let onPlay: () -> Void
    let onReveal: () -> Void
    let onConvert: () -> Void

    var body: some View {
        HStack {
            Button(action: onPlay) {
                Text(file.name).font(.system(size: 13)).foregroundColor(.accentColor)
                    .lineLimit(1).multilineTextAlignment(.leading)
            }.buttonStyle(.plain).help("Click to play")
            Spacer()
            Button { onConvert() } label: {
                Image(systemName: "wand.and.stars").font(.system(size: 12)).foregroundColor(.secondary)
            }.buttonStyle(.plain).help("Make compatible mp4").disabled(file.isAudio)
            Button { onReveal() } label: {
                Image(systemName: "folder").font(.system(size: 12)).foregroundColor(.secondary)
            }.buttonStyle(.plain).help("Reveal in Finder")
            Text(file.sizeLabel).font(.system(size: 12)).foregroundColor(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Drag-and-drop

struct AppDropDelegate: DropDelegate {
    let state: AppState

    func performDrop(info: DropInfo) -> Bool {
        // Try file URLs first
        if let item = info.itemProviders(for: [.fileURL]).first {
            _ = item.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data, let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true) else { return }
                Task { @MainActor in _ = state.handleDroppedURLs([url]) }
            }
            return true
        }
        // Generic URL
        if let item = info.itemProviders(for: [.url]).first {
            _ = item.loadDataRepresentation(forTypeIdentifier: UTType.url.identifier) { data, _ in
                guard let data = data, let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true) else { return }
                Task { @MainActor in _ = state.handleDroppedURLs([url]) }
            }
            return true
        }
        // Plain text containing a URL
        if let item = info.itemProviders(for: [.text]).first {
            _ = item.loadDataRepresentation(forTypeIdentifier: UTType.text.identifier) { data, _ in
                guard let data = data, let s = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in _ = state.handleDroppedText(s) }
            }
            return true
        }
        return false
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.url, .fileURL, .text])
    }
}
