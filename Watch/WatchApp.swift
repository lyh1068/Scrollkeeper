import SwiftUI

@main
struct ScrollkeeperApp: App {
    @StateObject private var library = Library()
    // The book being read. Restored on launch so the app reopens where you left off.
    @AppStorage("openBook") private var openBook = ""
    @State private var path: [String] = []

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
            .onChange(of: path) { openBook = path.last ?? "" }
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: Library

    var body: some View {
        List {
            ForEach(library.books, id: \.self) { name in
                NavigationLink(value: name) {
                    Text((name as NSString).deletingPathExtension).lineLimit(2)
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
