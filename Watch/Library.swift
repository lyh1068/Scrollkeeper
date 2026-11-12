import Foundation
import WatchConnectivity

/// The books on the watch: packed files in Documents, most recently opened first.
/// Also receives new books from the phone.
final class Library: NSObject, ObservableObject, WCSessionDelegate {
    static let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    @Published var books: [String] = []   // file names, e.g. "Dracula.txt"

    override init() {
        super.init()
        reload()
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
    static func positionKey(_ name: String) -> String { "position:" + name }
    static func bookmarksKey(_ name: String) -> String { "bookmarks:" + name }

    func reload() {
        let key = URLResourceKey.contentModificationDateKey
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [key, .isRegularFileKey],
                                                                 options: .skipsHiddenFiles)) ?? []
        // Books are plain files. The system keeps folders here too (an "Inbox" for
        // incoming transfers) that it recreates, so they must not be listed.
        let files = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
        func opened(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [key]))?.contentModificationDate ?? .distantPast }
        books = files.sorted { opened($0) > opened($1) }.map(\.lastPathComponent)
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

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
}
