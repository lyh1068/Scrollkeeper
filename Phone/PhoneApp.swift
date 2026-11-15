import SwiftUI
import UniformTypeIdentifiers
import WatchConnectivity

/// The iPhone side takes books (picked here, or shared from another app), turns them
/// into plain paragraphs and sends them to the watch. It also lists the books the watch
/// says it has, so they can be deleted from here.
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

                    if !sender.books.isEmpty {
                        Section("Sending") { ForEach(sender.books, content: row) }
                    }
                    if !sender.onWatch.isEmpty {
                        Section {
                            ForEach(sender.onWatch) { book in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Sender.title(book.id)).lineLimit(2)
                                    Text(book.percent.map { "\($0)% read" } ?? "Not opened yet")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                .swipeActions {
                                    Button("Delete", role: .destructive) { sender.deleteFromWatch(book.id) }
                                }
                            }
                        } header: {
                            Text("On your watch")
                        } footer: {
                            Text("Swipe a book to the left to delete it from your watch.")
                        }
                    }
                    if sender.books.isEmpty && sender.onWatch.isEmpty {
                        Section("How it works") {
                            Label("Pick books here. They're turned into plain text made for a small screen.", systemImage: "1.circle")
                            Label("They're sent to your Apple Watch and stored there, so you can read without your iPhone.", systemImage: "2.circle")
                            Label("Open Scrollkeeper on your watch and turn the Digital Crown to read.", systemImage: "3.circle")
                        }
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
        .swipeActions {
            // Not while it is being converted: that work can't be stopped halfway.
            if case .working = book.state {} else {
                Button("Remove", role: .destructive) { sender.remove(book) }
            }
        }
    }
}

// Used from background tasks; the published values are only ever set on the main thread.
final class Sender: NSObject, ObservableObject, WCSessionDelegate, @unchecked Sendable {
    static let types: [UTType] = [.plainText, .epub, .pdf] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }

    struct Book: Identifiable {
        let id: String
        var title: String
        var state: State
        var file = ""   // its name on the watch, once converted
    }
    struct WatchBook: Identifiable {
        let id: String      // its file name on the watch
        let percent: Int?   // how far it has been read; nil until it is opened
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

    @Published var books: [Book] = []          // being converted or sent
    @Published var onWatch: [WatchBook] = []   // what the watch last said it has
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
                self.update(id) { $0.title = Self.title(book.name); $0.file = book.name; $0.state = .waiting }
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

    static func title(_ fileName: String) -> String { (fileName as NSString).deletingPathExtension }

    /// Takes a row off the list. A book still waiting for the watch is not sent after all.
    func remove(_ book: Book) {
        WCSession.default.outstandingFileTransfers.first { $0.file.fileURL.lastPathComponent == book.id }?.cancel()
        try? FileManager.default.removeItem(at: Self.outbox.appendingPathComponent(book.id))
        books.removeAll { $0.id == book.id }
    }

    /// Done straight away if the watch app is open. Otherwise the request waits in a
    /// queue and is carried out when the watch is next in reach.
    func deleteFromWatch(_ name: String) {
        let session = WCSession.default, request = ["delete": name]
        if session.isReachable {
            session.sendMessage(request, replyHandler: nil) { _ in session.transferUserInfo(request) }
        } else {
            session.transferUserInfo(request)
        }
        onWatch.removeAll { $0.id == name }
    }

    /// The watch's own list, without the books it has been asked to delete but hasn't yet.
    private func showWatchBooks(_ session: WCSession) {
        let deleting = Set(session.outstandingUserInfoTransfers.filter(\.isTransferring).compactMap { $0.userInfo["delete"] as? String })
        let percent = session.receivedApplicationContext["percent"] as? [String: Int] ?? [:]
        let list = (session.receivedApplicationContext["books"] as? [String] ?? [])
            .filter { !deleting.contains($0) }
            .map { WatchBook(id: $0, percent: percent[$0]) }
        DispatchQueue.main.async {
            self.onWatch = list
            // A sent book has arrived once the watch lists it; its row here has done its job.
            let arrived = Set(list.map(\.id))
            self.books.removeAll { if case .sent = $0.state { arrived.contains($0.file) } else { false } }
        }
    }

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
            return Book(id: transfer.file.fileURL.lastPathComponent, title: Self.title(name), state: .waiting, file: name)
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
        showWatchBooks(session)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        showWatchBooks(session)
    }

    /// A delete that couldn't be delivered: the book is still on the watch, so list it again.
    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        if error != nil { showWatchBooks(session) }
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
