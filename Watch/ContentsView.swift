import SwiftUI

/// Bookmarks and chapters of the open book. Tapping one jumps there.
struct ContentsView: View {
    let paragraphs: [String]
    let chapters: [Int]          // paragraphs that begin a chapter
    let top: Int                 // paragraph at the top of the reader
    @Binding var bookmarks: [Int]
    let jump: (Int) -> Void

    private var current: Int? { chapters.last { $0 <= top } }
    private var marked: Bool { bookmarks.contains(top) }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Button {
                    if marked { bookmarks.removeAll { $0 == top } } else { bookmarks = (bookmarks + [top]).sorted() }
                } label: {
                    Label(marked ? "Remove Bookmark" : "Bookmark Here", systemImage: marked ? "bookmark.slash" : "bookmark")
                }

                if !bookmarks.isEmpty {
                    Section("Bookmarks") {
                        ForEach(bookmarks, id: \.self) { index in
                            Button { jump(index) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(excerpt(index)).lineLimit(2)
                                    Text("\(index * 100 / max(paragraphs.count - 1, 1))%")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { bookmarks.remove(atOffsets: $0) }
                    }
                }

                if !chapters.isEmpty {
                    Section("Chapters") {
                        ForEach(chapters, id: \.self) { index in
                            Button { jump(index) } label: {
                                Text(BookCodec.chapterTitle(paragraphs[index]) ?? "")
                                    .lineLimit(2)
                                    .foregroundStyle(index == current ? Color.accentColor : .primary)
                            }
                            .id("chapter \(index)")
                        }
                    }
                }
            }
            .onAppear {
                // In the first chapter the list already starts in the right place.
                if let current, current != chapters.first { proxy.scrollTo("chapter \(current)", anchor: .center) }
            }
        }
    }

    private func excerpt(_ index: Int) -> String {
        let text = paragraphs[index]
        return String((BookCodec.chapterTitle(text) ?? text).prefix(80))
    }
}
