import SwiftUI

@main
struct YTDownloaderApp: App {
    @StateObject private var sharedState = AppState()

    var body: some Scene {
        WindowGroup("YouTube Downloader") {
            ContentView(state: sharedState)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Tools") {
                Button("Update yt-dlp") { sharedState.updateYtDlp() }
                    .keyboardShortcut("u", modifiers: [.command])
                Button("Paste URL from Clipboard") { sharedState.tryClipboardAutofill() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Divider()
                Button("Open Downloads Folder") {
                    NSWorkspace.shared.open(Downloader.downloadsDirectory())
                }
            }
        }
    }
}
