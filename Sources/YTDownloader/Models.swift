import Foundation

struct VideoInfo: Codable {
    let title: String?
    let uploader: String?
    let duration: Double?
    let thumbnail: String?
    let formats: [Format]?

    struct Format: Codable {
        let formatId: String?
        let ext: String?
        let height: Int?
        let width: Int?
        let fps: Double?
        let vcodec: String?
        let acodec: String?
        let abr: Double?
        let tbr: Double?
        let filesize: Int64?
        let filesizeApprox: Int64?

        enum CodingKeys: String, CodingKey {
            case formatId = "format_id"
            case ext, height, width, fps, vcodec, acodec, abr, tbr
            case filesize
            case filesizeApprox = "filesize_approx"
        }
    }
}

struct QualityPreset: Identifiable, Hashable {
    let id: String
    let label: String
    let height: Int?      // nil = audio-only
    let audioOnly: Bool
    let sizeBytes: Int64?

    var displayLabel: String {
        if let s = sizeBytes, s > 0 {
            return "\(label) — \(Self.formatSize(s))"
        }
        return label
    }

    static func formatSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }
}

struct DownloadedFile: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let sizeBytes: Int64
    let modified: Date

    var sizeLabel: String { QualityPreset.formatSize(sizeBytes) }

    var isAudio: Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp3", "m4a", "wav", "ogg", "aac", "flac"].contains(ext)
    }
}

enum DownloadStatus: Equatable {
    case queued
    case probing
    case downloading(percent: Double, speed: String, eta: String)
    case processing
    case done(URL)
    case error(String)

    var isTerminal: Bool {
        switch self {
        case .done, .error: return true
        default: return false
        }
    }

    var percent: Double {
        if case .downloading(let p, _, _) = self { return p }
        if case .processing = self { return 1.0 }
        if case .done = self { return 1.0 }
        return 0
    }
}
