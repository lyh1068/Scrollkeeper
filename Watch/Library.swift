import Foundation
import WatchConnectivity

/// The books on the watch: packed files in Documents, most recently opened first.
/// Also receives new books from the phone, and tells the phone what is here so books
/// can be looked through, and deleted, from there too.
final class Library: NSObject, ObservableObject, WCSessionDelegate {
    static let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    @Published var books: [String] = []   // file names, e.g. "Dracula.txt"
    @Published var percent: [String: Int] = [:]   // how far each opened book has been read

    override init() {
        super.init()
        if !UserDefaults.standard.bool(forKey: "guideAdded") {
            UserDefaults.standard.set(true, forKey: "guideAdded")
            let paragraphs = BookCodec.paragraphs(fromText: Data(Guide.text.utf8), markdown: true) ?? []
            try? BookCodec.pack(paragraphs)?.write(to: Self.url(Guide.name))
        }
        reload()
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
    static func positionKey(_ name: String) -> String { "position:" + name }
    static func bookmarksKey(_ name: String) -> String { "bookmarks:" + name }
    static func lengthKey(_ name: String) -> String { "length:" + name }   // paragraphs; known once opened

    func reload() {
        let key = URLResourceKey.contentModificationDateKey
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [key, .isRegularFileKey],
                                                                 options: .skipsHiddenFiles)) ?? []
        // Books are plain files. The system keeps folders here too (an "Inbox" for
        // incoming transfers) that it recreates, so they must not be listed.
        let files = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
        func opened(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [key]))?.contentModificationDate ?? .distantPast }
        books = files.sorted { opened($0) > opened($1) }.map(\.lastPathComponent)

        let defaults = UserDefaults.standard
        percent = [:]
        for name in books {
            let length = defaults.integer(forKey: Self.lengthKey(name))
            if length > 0 { percent[name] = min(100, defaults.integer(forKey: Self.positionKey(name)) * 100 / max(length - 1, 1)) }
        }
        if WCSession.default.activationState == .activated {
            try? WCSession.default.updateApplicationContext(["books": books, "percent": percent])
        }
    }

    /// Moves a book to the top of the list.
    func markOpened(_ name: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: Self.url(name).path)
        reload()
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: Self.url(name))
        UserDefaults.standard.removeObject(forKey: Self.positionKey(name))
        UserDefaults.standard.removeObject(forKey: Self.bookmarksKey(name))
        UserDefaults.standard.removeObject(forKey: Self.lengthKey(name))
        reload()
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The received file is deleted when this method returns, so move it now.
        let name = ((file.metadata?["name"] as? String ?? UUID().uuidString) as NSString).lastPathComponent
        let destination = Self.url(name)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: file.fileURL, to: destination)
        DispatchQueue.main.async { self.reload() }
    }

    /// The phone asked for a book to be deleted: as a message if this app was open,
    /// otherwise as queued user info.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { deleteRequested(message) }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { deleteRequested(userInfo) }

    private func deleteRequested(_ request: [String: Any]) {
        guard let name = request["delete"] as? String else { return }
        DispatchQueue.main.async { self.delete((name as NSString).lastPathComponent) }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.reload() }
    }
}
