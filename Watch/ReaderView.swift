import SwiftUI
import WatchKit

/// Full-screen text. The crown moves one line per step, with a light tap every few
/// lines instead of the system's constant ticking. Tap the text for the controls;
/// ▶ scrolls on its own at the speed set beside it, which the crown also changes while it runs.
struct ReaderView: View {
    let name: String

    @EnvironmentObject private var library: Library
    @Environment(\.scenePhase) private var scenePhase
    @State private var paragraphs: [String] = []
    @State private var loaded = false
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var offset: CGFloat = 0                    // the scroll view's content offset
    @State private var range: ClosedRange<CGFloat> = 0...0    // the offsets it can scroll between
    @State private var top = 0                       // paragraph at the top of the screen
    @State private var jumping = true                // on the way to where you left off, or to a chapter
    @State private var controls = false
    @State private var autoScroll = false
    @State private var showSpeed = false
    @State private var crown = 0                     // counts crown steps; only changes matter
    @State private var target: CGFloat = 0           // where the crown is heading
    @State private var lastCrown = Date.distantPast
    @State private var linesSinceTap = 0
    @State private var chapters: [Int] = []          // paragraphs that begin a chapter
    @State private var bookmarks: [Int] = []
    @State private var showContents = false
    @FocusState private var crownFocused: Bool
    @AppStorage("fontSize") private var fontSize = 15.0
    @AppStorage("linesPerMinute") private var linesPerMinute = 30

    private let linesPerTap = 5
    private var lineHeight: CGFloat { fontSize * 1.2 }   // one line of Latin text at this size
    private var isMarkdown: Bool { ["md", "markdown"].contains((name as NSString).pathExtension.lowercased()) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(paragraphs.indices, id: \.self) { index in
                    paragraph(paragraphs[index])
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 2)
            // No padding above this: it makes the scroll view disagree with itself about
            // where the top is, and every auto-scroll step got pulled back by that much.
        }
        .ignoresSafeArea(edges: .top)   // use the space the hidden title bar would take
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { offset = $1 }
        .onScrollGeometryChange(for: ClosedRange<CGFloat>.self) { g in
            let top = -g.contentInsets.top
            return top...max(top, g.contentSize.height + g.contentInsets.bottom - g.containerSize.height)
        } action: { range = $1 }
        .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.01) { visible in
            guard let first = visible.min() else { return }
            // During a jump the scroll view still reports the place it is leaving, and
            // sometimes nothing after that; don't take the old place for the new one.
            if jumping && !visible.contains(top) { return }
            top = first
        }
        .font(.system(size: fontSize).width(.condensed))
        .onTapGesture {
            if autoScroll { autoScroll = false; controls = true } else { controls.toggle() }
            crownFocused = true
        }
        // The crown goes to an invisible view beside the text rather than to the scroll
        // view, so the system's scroll haptics are off and we choose when to tap. (Wrapped
        // around the scroll view instead, its indicator would flash at every scroll step.)
        .background {
            Color.black
                .focusable()
                .focused($crownFocused)
                .focusEffectDisabled()
                .digitalCrownRotation(detent: $crown, from: -1_000_000, through: 1_000_000, by: 1,
                                      sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: false)
        }
        .onChange(of: crown) { old, new in crownTurned(by: new - old) }
        .task(id: autoScroll && scenePhase == .active) { await scrollByItself() }
        .task(id: showSpeed) {
            guard showSpeed, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            showSpeed = false
        }
        .overlay {
            if !loaded {
                ProgressView()
            } else if paragraphs.allSatisfy(\.isEmpty) {
                Text("This book is empty or couldn't be opened.\nTry sending it again from your iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .overlay(alignment: .bottom) {
            if controls {
                controlBar
            } else if showSpeed {
                Text("\(linesPerMinute) lines/min")
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.85), in: Capsule())
            }
        }
        .toolbar(controls ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showContents = true } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("Chapters and bookmarks")
            }
        }
        .sheet(isPresented: $showContents) {
            ContentsView(paragraphs: paragraphs, chapters: chapters, top: top, bookmarks: $bookmarks) { index in
                showContents = false
                controls = false
                Task { await jump(to: index) }
            }
        }
        ._statusBarHidden(!controls)   // the clock, too; it comes back with the controls
        .task {
            let url = Library.url(name)
            let book = await Task.detached { BookCodec.unpack((try? Data(contentsOf: url)) ?? Data()) }.value
            top = min(UserDefaults.standard.integer(forKey: Library.positionKey(name)), max(book.count - 1, 0))
            chapters = book.indices.filter { book[$0].first == BookCodec.chapterMark }
            bookmarks = UserDefaults.standard.array(forKey: Library.bookmarksKey(name)) as? [Int] ?? []
            paragraphs = book
            loaded = true
            UserDefaults.standard.set(book.count, forKey: Library.lengthKey(name))   // for the percentage in the book list
            library.markOpened(name)
            crownFocused = true
            try? await Task.sleep(for: .milliseconds(50))   // let the text lay out before jumping
            await jump(to: top)
        }
        .onChange(of: top) { UserDefaults.standard.set(top, forKey: Library.positionKey(name)) }
        .onChange(of: bookmarks) { UserDefaults.standard.set(bookmarks, forKey: Library.bookmarksKey(name)) }
    }

    private func jump(to index: Int) async {
        jumping = true
        top = index
        position.scrollTo(id: index, anchor: .top)
        try? await Task.sleep(for: .milliseconds(500))
        jumping = false
    }

    private func crownTurned(by steps: Int) {
        if autoScroll {
            setSpeed(linesPerMinute + steps)
            showSpeed = true
            return
        }
        // Keep adding to the destination while the crown is turning; start from where
        // the text actually is once it has rested (it may have been dragged meanwhile).
        let start = Date.now.timeIntervalSince(lastCrown) < 0.4 ? target : offset
        lastCrown = .now
        target = min(max(start + CGFloat(steps) * lineHeight, range.lowerBound), range.upperBound)
        guard target != start else { return }   // already at the top or the end
        withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(y: target) }

        linesSinceTap += abs(steps)
        if linesSinceTap >= linesPerTap {
            linesSinceTap = 0
            WKInterfaceDevice.current().play(.click)
        }
    }

    /// Runs while auto-scroll is on and the screen is awake; lowering your wrist pauses it.
    private func scrollByItself() async {
        guard autoScroll, scenePhase == .active else { return }
        var y = offset
        var last = Date.now
        while (try? await Task.sleep(for: .milliseconds(33))) != nil {
            if abs(offset - y) > 2 * lineHeight { y = offset }   // the text was dragged
            y += CGFloat(linesPerMinute) / 60 * lineHeight * Date.now.timeIntervalSince(last)
            last = .now
            position.scrollTo(y: min(y, range.upperBound))
            if y >= range.upperBound { autoScroll = false }
        }
    }

    private func setSpeed(_ newValue: Int) {
        linesPerMinute = min(120, max(5, newValue))
        showSpeed = true
    }

    @ViewBuilder
    private func paragraph(_ text: String) -> some View {
        if let title = BookCodec.chapterTitle(text) {
            Text(isMarkdown ? inline(title) : AttributedString(title))
                .bold()
                .padding(.top, 10)
        } else if !isMarkdown {
            Text(text)
        } else if text.hasPrefix("#") {
            Text(inline(String(text.drop { $0 == "#" || $0 == " " }))).bold()
        } else if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ") {
            Text(inline("• " + text.dropFirst(2)))
        } else {
            Text(inline(text))
        }
    }

    /// Bold, italic, code and links. Block syntax is handled in `paragraph`.
    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// Text size and progress on top; auto-scroll speed and ▶ below. Every button is a
    /// finger-sized tile (44 points tall, Apple's minimum for a comfortable tap).
    private var controlBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button("A−") { fontSize = max(10, fontSize - 1) }
                    .frame(width: 52)
                    .accessibilityLabel("Smaller text")
                Text("\(top * 100 / max(paragraphs.count - 1, 1))%")
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("\(top * 100 / max(paragraphs.count - 1, 1)) percent read")
                Button("A+") { fontSize = min(24, fontSize + 1) }
                    .frame(width: 52)
                    .accessibilityLabel("Larger text")
            }
            HStack(spacing: 6) {
                Button { setSpeed(linesPerMinute - 5) } label: { Image(systemName: "minus") }
                    .frame(width: 52)
                    .accessibilityLabel("Scroll slower")
                Button {
                    controls = false
                    autoScroll = true
                    showSpeed = true
                } label: {
                    Label("\(linesPerMinute)/min", systemImage: "play.fill")
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .accessibilityLabel("Start auto-scroll, \(linesPerMinute) lines per minute")
                Button { setSpeed(linesPerMinute + 5) } label: { Image(systemName: "plus") }
                    .frame(width: 52)
                    .accessibilityLabel("Scroll faster")
            }
        }
        .font(.body)
        .buttonStyle(Tile())
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black)
    }
}

private struct Tile: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color(white: configuration.isPressed ? 0.35 : 0.2), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
