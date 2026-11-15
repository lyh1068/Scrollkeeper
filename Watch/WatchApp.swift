import SwiftUI

@main
struct ScrollkeeperApp: App {
    @StateObject private var library = Library()
    // The book being read. Restored on launch so the app reopens where you left off.
    @AppStorage("openBook") private var openBook = ""
    @State private var path: [String] = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                LibraryView()
                    .navigationDestination(for: String.self) { ReaderView(name: $0) }
            }
            .environmentObject(library)
            .onAppear {
                if path.isEmpty, library.books.contains(openBook) { path = [openBook] }
            }
            .onChange(of: path) {
                openBook = path.last ?? ""
                library.reload()   // how far the book just closed was read
            }
            .onChange(of: scenePhase) { if scenePhase != .active { library.reload() } }
            // A book deleted from the phone while it is open here.
            .onChange(of: library.books) {
                if let open = path.last, !library.books.contains(open) { path = [] }
            }
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: Library

    var body: some View {
        List {
            ForEach(library.books, id: \.self) { name in
                NavigationLink(value: name) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((name as NSString).deletingPathExtension).lineLimit(2)
                        if let percent = library.percent[name] {
                            Text("\(percent)%").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { offsets in
                offsets.map { library.books[$0] }.forEach(library.delete)
            }
        }
        .navigationTitle("Books")
        .overlay {
            if library.books.isEmpty {
                Text("No books yet.\nSend EPUB, PDF, .txt or .md files from Scrollkeeper on your iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
