import SwiftUI
import UniformTypeIdentifiers
import WatchConnectivity

/// The iPhone side does one thing: take books (picked here, or shared from another app),
/// turn them into plain paragraphs and send them to the watch.
@main
struct ScrollkeeperPhoneApp: App {
    @StateObject private var sender = Sender()
    @State private var picking = false

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section {
                        Button { picking = true } label: {
                            Text("Send Books to Watch")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } footer: {
                        Text("EPUB, PDF, plain text (.txt) and Markdown (.md). You can also share a file to Scrollkeeper from Files, Safari, Mail and other apps.")
                    }

                    if let problem = sender.watchProblem {
                        Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }

                    if sender.books.isEmpty {
                        Section("How it works") {
                            Label("Pick books here. They're turned into plain text made for a small screen.", systemImage: "1.circle")
                            Label("They're sent to your Apple Watch and stored there, so you can read without your iPhone.", systemImage: "2.circle")
                            Label("Open Scrollkeeper on your watch and turn the Digital Crown to read.", systemImage: "3.circle")
                        }
                    } else {
                        Section("Books") { ForEach(sender.books, content: row) }
                    }
                }
                .navigationTitle("Scrollkeeper")
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: Sender.types, allowsMultipleSelection: true) { result in
                sender.send((try? result.get()) ?? [])
            }
            .onOpenURL { sender.send([$0]) }   // "Open in Scrollkeeper" from the share sheet
        }
    }

    private func row(_ book: Sender.Book) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).lineLimit(2)
                Text(book.state.text).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            switch book.state {
            case .working, .waiting: ProgressView()
            case .sent: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// Used from background tasks; the published values are only ever set on the main thread.
final class Sender: NSObject, ObservableObject, WCSessionDelegate, @unchecked Sendable {
    static let types: [UTType] = [.plainText, .epub, .pdf] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }

    struct Book: Identifiable {
        let id: String
        var title: String
        var state: State
    }
    enum State {
        case working(String), waiting, sent, failed(String)
        var text: String {
            switch self {
            case .working(let step): step
            case .waiting: "Waiting for your watch…"
            case .sent: "On your watch"
            case .failed(let why): why
            }
        }
    }

    @Published var books: [Book] = []
    @Published var watchProblem: String?

    /// Converted books wait here until the watch has taken them, which can be much later.
    private static let outbox = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Outbox")

    override init() {
        super.init()
        try? FileManager.default.createDirectory(at: Self.outbox, withIntermediateDirectories: true)
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ urls: [URL]) {
        let jobs = urls.map { (url: $0, id: UUID().uuidString) }
        books.insert(contentsOf: jobs.map { Book(id: $0.id, title: Self.title($0.url.lastPathComponent), state: .working("Waiting…")) }, at: 0)

        // A long novel takes seconds to convert, a scanned PDF minutes; keep the screen
        // responsive meanwhile, and say how far along a PDF is.
        Task.detached(priority: .userInitiated) {
            for (url, id) in jobs {
                self.update(id) { $0.state = .working("Converting…") }
                let scoped = url.startAccessingSecurityScopedResource()
                let raw = try? Data(contentsOf: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
                // A shared file arrives as a copy inside the app; don't keep it.
                if url.resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/") {
                    try? FileManager.default.removeItem(at: url)
                }

                let packed = Self.outbox.appendingPathComponent(id)
                guard let raw,
                      let book = await Import.book(raw, named: url.lastPathComponent, progress: { page, pages in
                          self.update(id) { $0.state = .working("Reading page \(page) of \(pages)…") }
                      }),
                      let data = BookCodec.pack(book.paragraphs),
                      (try? data.write(to: packed)) != nil
                else {
                    self.update(id) { $0.state = .failed(Self.whyUnreadable(url)) }
                    continue
                }
                self.update(id) { $0.title = Self.title(book.name); $0.state = .waiting }
                // Opened from a share sheet, the app may have only just started.
                for _ in 0..<50 where WCSession.default.activationState != .activated {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                WCSession.default.transferFile(packed, metadata: ["name": book.name])
            }
        }
    }

    private func update(_ id: String, _ change: @escaping (inout Book) -> Void) {
        DispatchQueue.main.async {
            if let i = self.books.firstIndex(where: { $0.id == id }) { change(&self.books[i]) }
            // Don't let the screen lock, and the work stop, halfway through a long scan.
            UIApplication.shared.isIdleTimerDisabled = self.books.contains { if case .working = $0.state { true } else { false } }
        }
    }

    private static func title(_ fileName: String) -> String { (fileName as NSString).deletingPathExtension }

    private static func whyUnreadable(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "epub": "Can't be opened. Books bought from a store are copy-protected."
        case "pdf": "No readable text found. PDFs locked with a password can't be opened."
        default: "This file isn't readable as text."
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        // Books still on their way from an earlier run get a row again. Anything else in
        // the outbox that isn't being worked on now is left over.
        let waiting = session.outstandingFileTransfers.filter(\.isTransferring)
        let rows = waiting.map { transfer -> Book in
            let name = transfer.file.metadata?["name"] as? String ?? ""
            return Book(id: transfer.file.fileURL.lastPathComponent, title: Self.title(name), state: .waiting)
        }
        DispatchQueue.main.async {
            self.books += rows.filter { row in !self.books.contains { $0.id == row.id } }
            let kept = Set(self.books.map(\.id))
            for file in (try? FileManager.default.contentsOfDirectory(at: Self.outbox, includingPropertiesForKeys: nil)) ?? []
            where !kept.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        checkWatch(session)
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        update(fileTransfer.file.fileURL.lastPathComponent) {
            $0.state = error.map { .failed("Couldn't be sent. \($0.localizedDescription)") } ?? .sent
        }
    }

    func sessionWatchStateDidChange(_ session: WCSession) { checkWatch(session) }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    private func checkWatch(_ session: WCSession) {
        var problem: String?
        if session.activationState == .activated {
            if !session.isPaired {
                problem = "No Apple Watch is paired with this iPhone. Books are read on the watch."
            } else if !session.isWatchAppInstalled {
                problem = "Scrollkeeper isn't on your Apple Watch yet. Install it from the Watch app on this iPhone."
            }
        }
        DispatchQueue.main.async { self.watchProblem = problem }
    }
}
