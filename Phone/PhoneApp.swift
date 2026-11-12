import SwiftUI
import UniformTypeIdentifiers
import WatchConnectivity

/// The iPhone side does one thing: pick books and send them to the watch.
@main
struct ScrollkeeperPhoneApp: App {
    @StateObject private var sender = Sender()
    @State private var picking = false

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Button("Send Books to Watch") { picking = true }
                    .buttonStyle(.borderedProminent)
                Text(sender.status)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .fileImporter(isPresented: $picking, allowedContentTypes: Sender.types, allowsMultipleSelection: true) { result in
                sender.send((try? result.get()) ?? [])
            }
        }
    }
}

// Used from a background task; `status` is only ever set on the main thread.
final class Sender: NSObject, ObservableObject, WCSessionDelegate, @unchecked Sendable {
    static let types: [UTType] = [.plainText, .epub, .pdf] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }

    @Published var status = "EPUB, PDF, plain text (.txt) and Markdown (.md)"

    override init() {
        super.init()
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ urls: [URL]) {
        status = "Preparing…"
        // A long novel takes seconds to convert, a scanned PDF minutes; keep the screen
        // responsive meanwhile, and say how far along a PDF is.
        Task.detached(priority: .userInitiated) {
            var unreadable = 0
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                let packed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let title = (url.lastPathComponent as NSString).deletingPathExtension
                guard let raw = try? Data(contentsOf: url),
                      let book = await Import.book(raw, named: url.lastPathComponent, progress: { page, pages in
                          DispatchQueue.main.async { self.status = "Reading \(title): page \(page) of \(pages)" }
                      }),
                      let data = BookCodec.pack(book.paragraphs),
                      (try? data.write(to: packed)) != nil
                else { unreadable += 1; continue }
                WCSession.default.transferFile(packed, metadata: ["name": book.name])
            }
            self.showProgress(unreadable: unreadable)
        }
    }

    private func showProgress(unreadable: Int = 0) {
        let session = WCSession.default
        let waiting = session.outstandingFileTransfers.filter(\.isTransferring).count
        var text = waiting > 0 ? "Sending \(waiting) to your watch…" : "All sent."
        if session.activationState != .activated || !session.isWatchAppInstalled {
            text = "Scrollkeeper isn't installed on a paired Apple Watch."
        }
        if unreadable > 0 { text += "\n\(unreadable) couldn't be read. Books bought from a store are copy-protected and can't be opened." }
        DispatchQueue.main.async { self.status = text }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        showProgress()
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
