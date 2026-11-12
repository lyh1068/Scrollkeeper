import Foundation
import PDFKit
import Vision

/// A PDF as paragraphs. Pages with real text are read directly; pages that are only a
/// picture (scans) go through Apple's on-device document recognition. Lines are joined
/// back into paragraphs, and running headers, footers and page numbers are dropped.
enum PDF {
    static func read(_ data: Data, progress: (Int, Int) -> Void) async -> [String]? {
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { return nil }

        var pages: [[Line]] = []
        for index in 0..<document.pageCount {
            progress(index + 1, document.pageCount)
            guard let page = document.page(at: index) else { pages.append([]); continue }
            let hasText = (page.string ?? "").filter { !$0.isWhitespace }.count >= 20
            pages.append(hasText ? lines(of: page) : await recognize(page))
        }

        // Join lines into paragraphs, across page breaks too, remembering where each starts.
        let running = runningLines(pages)
        var paragraphs: [String] = []
        var startPage: [Int] = []
        var lastEndedShort: Bool?   // the last line of the previous page; nil if unknown (scans)
        for (index, page) in pages.enumerated() {
            let page = withoutRunningLines(page, running)
            for (k, line) in page.enumerated() {
                // At the top of a page, carry on the paragraph if the previous page's last
                // line ran to the margin (or, for scans, didn't end a sentence).
                let carriesOver = lastEndedShort.map { !$0 } ?? paragraphs.last.map { !endsSentence($0) } ?? false
                let continues = !line.newParagraph && (k > 0 || carriesOver) && !BookCodec.isChapter(line.text, markdown: false)
                if continues, let last = paragraphs.popLast() {
                    paragraphs.append(join(last, line.text))
                } else {
                    paragraphs.append(line.text)
                    startPage.append(index)
                }
            }
            if let last = page.last { lastEndedShort = last.endsShort }
        }

        // Chapters: the PDF's own bookmarks where it has them, and lines that look like
        // chapter headings. A heading repeated at the top of every page is a running head.
        let bookmarks = outline(of: document)
        var placed = Set<Int>()
        var current = ""
        var out: [String] = []
        for (n, text) in paragraphs.enumerated() {
            let page = startPage[n]
            let titles = bookmarks[page] ?? []
            if !titles.isEmpty && placed.insert(page).inserted {
                let onPage = Set(paragraphs.indices.filter { startPage[$0] == page }.map { letters(paragraphs[$0]) })
                for title in titles where !onPage.contains(letters(title)) {
                    out.append(String(BookCodec.chapterMark) + title)
                    current = letters(title)
                }
            }
            if titles.contains(where: { letters($0) == letters(text) }) || BookCodec.isChapter(text, markdown: false) {
                if letters(text) == current { continue }
                current = letters(text)
                out.append(String(BookCodec.chapterMark) + text)
            } else {
                out.append(text)
            }
        }
        return BookCodec.withoutPrintedContents(out).flatMap(BookCodec.split)
    }

    /// A printed line: whether a new paragraph starts with it, and whether it stops short
    /// of the right margin (nil when unknown, as for recognised scans).
    private struct Line {
        var text: String
        var newParagraph: Bool
        var endsShort: Bool?
        var indented = false
    }

    // MARK: Text pages

    /// The page's lines. A paragraph starts where a line is indented, where there is extra
    /// space above it, or where the line before stopped well short of the right margin.
    private static func lines(of page: PDFPage) -> [Line] {
        let items: [(text: String, box: CGRect)] = (page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? [])
            .compactMap { line in
                let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : (text, line.bounds(for: page))
            }
        guard !items.isEmpty else { return [] }
        // The margin is where the unindented lines start, not the typical start: in dialogue
        // half of all lines are the indented first lines of short paragraphs.
        let left = items.map(\.box.minX).min() ?? 0
        let right = items.map(\.box.maxX).sorted()[items.count * 9 / 10]
        let spacing = median(zip(items, items.dropFirst()).map { $0.box.minY - $1.box.minY }.filter { $0 > 0 })
        func short(_ box: CGRect) -> Bool { box.maxX < right - (right - left) * 0.15 }

        return items.indices.map { k in
            let box = items[k].box
            let indented = box.minX > left + max(4, box.height * 0.8)
            var starts = indented
            if k > 0 {
                let above = items[k - 1].box
                let gap = above.minY - box.minY
                if gap > spacing * 1.5 || gap < 0 { starts = true }                      // extra space, or a new column
                if short(above) { starts = true }                                        // the line above ended short
            }
            return Line(text: items[k].text, newParagraph: starts, endsShort: short(box), indented: indented)
        }
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        values.isEmpty ? 0 : values.sorted()[values.count / 2]
    }

    // MARK: Scanned pages

    /// Paragraphs of a page that is only a picture, read by on-device document recognition.
    private static func recognize(_ page: PDFPage) async -> [Line] {
        guard let image = render(page) else { return [] }
        var request = RecognizeDocumentsRequest()
        let wanted = ["zh-Hans", "zh-Hant", "en-US"].map { Locale.Language(identifier: $0) }
        request.textRecognitionOptions.recognitionLanguages = wanted.filter(request.supportedRecognitionLanguages.contains)
        request.textRecognitionOptions.useLanguageCorrection = true
        guard let document = try? await request.perform(on: image, orientation: nil).first?.document else { return [] }
        return document.paragraphs.enumerated().compactMap { k, paragraph in
            let text = paragraph.transcript.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .reduce("") { $0.isEmpty ? $1 : join($0, $1) }
            // The first paragraph may carry on from the previous page.
            return text.isEmpty ? nil : Line(text: text, newParagraph: k > 0)
        }
    }

    /// The page as an image, at twice its printed size so small text stays legible.
    private static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let scale: CGFloat = 2
        guard let context = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    // MARK: Headers, footers, page numbers

    /// Text that shows up at the top or bottom of many pages: a book title or author
    /// printed as a running head, or a footer.
    private static func runningLines(_ pages: [[Line]]) -> Set<String> {
        var counts: [String: Int] = [:]
        for page in pages {
            for key in Set((page.prefix(2) + page.suffix(2)).map { letters($0.text) }) where !key.isEmpty {
                counts[key, default: 0] += 1
            }
        }
        let needed = max(3, pages.count / 4)
        return Set(counts.filter { $0.value >= needed }.keys)
    }

    private static func withoutRunningLines(_ page: [Line], _ running: Set<String>) -> [Line] {
        func isRunning(_ line: Line) -> Bool { running.contains(letters(line.text)) || isPageNumber(line.text) }
        var page = page
        for _ in 0..<2 { if let first = page.first, isRunning(first) { page.removeFirst() } }
        for _ in 0..<2 { if let last = page.last, isRunning(last) { page.removeLast() } }
        // The space below a removed running head said nothing about paragraphs.
        if !page.isEmpty { page[0].newParagraph = page[0].indented }
        return page
    }

    private static let pageNumber = try! NSRegularExpression(
        pattern: "^[-–—·\\s]*(page\\s*)?([0-9]+|[ivxlcdm]+)(\\s*(/|of)\\s*[0-9]+)?[-–—·\\s]*$|^第\\s*[0-9]+\\s*页$",
        options: .caseInsensitive)

    private static func isPageNumber(_ text: String) -> Bool {
        pageNumber.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: Chapters

    /// Bookmark titles by the page they point to.
    private static func outline(of document: PDFDocument) -> [Int: [String]] {
        var titles: [Int: [String]] = [:]
        func walk(_ item: PDFOutline) {
            for i in 0..<item.numberOfChildren {
                guard let child = item.child(at: i) else { continue }
                let label = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty, let page = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page {
                    titles[document.index(for: page), default: []].append(label)
                }
                walk(child)
            }
        }
        if let root = document.outlineRoot { walk(root) }
        return titles
    }

    // MARK: Text helpers

    private static func letters(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return true }
        return ".!?。！？…\"”」』:：)）".contains(last)
    }

    /// Two pieces of one paragraph: hyphenated words are rejoined, and Chinese and
    /// Japanese need no space between lines.
    private static func join(_ a: String, _ b: String) -> String {
        if a.hasSuffix("--") || a.hasSuffix("—") { return a + b }                          // a dash, not a hyphen
        if a.hasSuffix("-"), b.first?.isLowercase == true { return String(a.dropLast()) + b }
        if let x = a.last, let y = b.first, isWide(x) || isWide(y) { return a + b }
        return a + " " + b
    }

    private static func isWide(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFF00...0xFFEF).contains(v)
    }
}
