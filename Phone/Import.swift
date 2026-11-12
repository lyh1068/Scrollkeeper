import Foundation

/// Turns a picked file into the paragraphs the watch shows. EPUB and PDF are read here
/// on the phone, so the watch only ever sees plain paragraphs.
enum Import {
    /// The name to store the book under on the watch, and its paragraphs. `progress`
    /// gets (page, pages) while a PDF is read, which can take a while for scans.
    static func book(_ raw: Data, named fileName: String,
                     progress: (Int, Int) -> Void = { _, _ in }) async -> (name: String, paragraphs: [String])? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext == "pdf" {
            guard let paragraphs = await PDF.read(raw, progress: progress), !paragraphs.isEmpty else { return nil }
            return (fileName, paragraphs)
        }
        if ext == "epub" {
            guard let book = EPUB.read(raw), !book.paragraphs.isEmpty else { return nil }
            // EPUB file names are often ISBNs; the book's own title reads better.
            let title = book.title?.replacingOccurrences(of: "/", with: "-") ?? (fileName as NSString).deletingPathExtension
            return (title + ".epub", book.paragraphs)
        }
        guard let paragraphs = BookCodec.paragraphs(fromText: raw, markdown: ["md", "markdown"].contains(ext)) else { return nil }
        return (fileName, paragraphs)
    }
}

/// A DRM-free EPUB: the text of its chapters in reading order, with chapters marked
/// from the book's table of contents. Pictures, styles and fonts are left out.
enum EPUB {
    static func read(_ data: Data) -> (title: String?, paragraphs: [String])? {
        guard let zip = Zip(data),
              let container = zip.text("META-INF/container.xml"),
              let opfPath = first(#"full-path\s*=\s*["']([^"']+)["']"#, in: container),
              let opf = zip.text(opfPath)
        else { return nil }
        // Bought books are encrypted; there is nothing readable inside.
        if let encryption = zip.text("META-INF/encryption.xml"), first(#"URI\s*=\s*["'][^"']*(\.x?html?)["']"#, in: encryption) != nil {
            return nil
        }

        // The manifest names every file; the spine says which ones to read, in order.
        let folder = (opfPath as NSString).deletingLastPathComponent
        var files: [String: String] = [:]   // manifest id → path in the zip
        var navPath: String?, ncxPath: String?
        for tag in all(#"<item\b[^>]*>"#, in: opf) {
            guard let id = attribute("id", in: tag), let href = attribute("href", in: tag) else { continue }
            let path = resolve(href, in: folder)
            files[id] = path
            if attribute("properties", in: tag)?.split(separator: " ").contains("nav") == true { navPath = path }
            if attribute("media-type", in: tag) == "application/x-dtbncx+xml" { ncxPath = path }
        }
        let spine = all(#"<itemref\b[^>]*>"#, in: opf).compactMap { attribute("idref", in: $0) }.compactMap { files[$0] }

        // Table of contents: for each file, chapter titles by the id they start at
        // ("" for the top of the file). EPUB 3 has a nav page; EPUB 2 an NCX file.
        var toc: [String: [String: String]] = [:]
        func add(_ href: String, _ title: String, from tocPath: String) {
            let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let path = resolve(String(parts[0]), in: (tocPath as NSString).deletingLastPathComponent)
            let id = parts.count > 1 ? String(parts[1]) : ""
            let title = plain(title)
            if !title.isEmpty && toc[path]?[id] == nil { toc[path, default: [:]][id] = title }
        }
        if let navPath, let nav = zip.text(navPath) {
            let list = first(#"(?s)<nav\b[^>]*toc[^>]*>(.*?)</nav>"#, in: nav) ?? nav
            for m in matches(#"(?s)<a\b([^>]*)>(.*?)</a>"#, in: list) {
                if let href = attribute("href", in: m[1]) { add(href, m[2], from: navPath) }
            }
        } else if let ncxPath, let ncx = zip.text(ncxPath) {
            for m in matches(#"(?s)<navLabel\b[^>]*>\s*<text\b[^>]*>(.*?)</text>\s*</navLabel>\s*<content\b([^>]*)>"#, in: ncx) {
                if let src = attribute("src", in: m[2]) { add(src, m[1], from: ncxPath) }
            }
        }

        var paragraphs: [String] = []
        for path in spine {
            guard let page = zip.text(path) else { continue }
            append(page, chapters: toc[path] ?? [:], to: &paragraphs)
        }
        let title = first(#"(?s)<dc:title\b[^>]*>(.*?)</dc:title>"#, in: opf).map(plain)
        return (title?.isEmpty == false ? title : nil, BookCodec.withoutPrintedContents(paragraphs).flatMap(BookCodec.split))
    }

    // MARK: Pages

    private static let blocks: Set = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote",
                                      "section", "article", "header", "footer", "aside", "pre", "tr", "dt", "dd",
                                      "figcaption", "table", "ul", "ol", "br", "hr"]
    private static let hidden: Set = ["head", "script", "style"]

    /// Adds the text of one XHTML page, one paragraph per block. Where the table of
    /// contents says a chapter starts, the next paragraph is marked, or, if it isn't the
    /// chapter's title, the title is put in front of it. Headings in the text are marked
    /// too: many tables of contents list only parts or books, not their chapters.
    private static func append(_ page: String, chapters: [String: String], to out: inout [String]) {
        var text = ""
        var chapter = chapters[""]   // title waiting for the next paragraph
        var heading = false          // inside <h1>…<h4>
        var hiddenDepth = 0

        func flush() {
            let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            text = ""
            guard !line.isEmpty else { return }
            if let title = chapter {
                chapter = nil
                if letters(line) == letters(title) { out.append(String(BookCodec.chapterMark) + line); return }
                // Named differently in the table of contents: keep that name, and don't
                // count the heading under it as a second chapter.
                out.append(String(BookCodec.chapterMark) + title)
                out.append(line)
                return
            }
            let isHeading = (heading && line.count <= 80) || BookCodec.isChapter(line, markdown: false)
            out.append(isHeading ? String(BookCodec.chapterMark) + line : line)
        }

        var i = page.startIndex
        while i < page.endIndex {
            guard page[i] == "<" else {
                let next = page[i...].firstIndex(of: "<") ?? page.endIndex
                if hiddenDepth == 0 { text += decodeEntities(page[i..<next]) }
                i = next
                continue
            }
            if page[i...].hasPrefix("<!--") {
                i = page.range(of: "-->", range: i..<page.endIndex)?.upperBound ?? page.endIndex
                continue
            }
            guard let end = page[i...].firstIndex(of: ">") else { break }
            let tag = page[page.index(after: i)..<end]
            i = page.index(after: end)

            let closing = tag.hasPrefix("/")
            let name = tag.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }.lowercased()
            if hidden.contains(name) {
                if !tag.hasSuffix("/") { hiddenDepth = max(0, hiddenDepth + (closing ? -1 : 1)) }
                continue
            }
            if hiddenDepth > 0 { continue }
            if blocks.contains(name) { flush() }
            if ["h1", "h2", "h3", "h4"].contains(name) { heading = !closing }
            if !closing, let id = attribute("id", in: String(tag)), let title = chapters[id], !id.isEmpty {
                flush()
                chapter = title
            }
        }
        flush()
        if let title = chapter { out.append(String(BookCodec.chapterMark) + title) }
    }

    // MARK: Text helpers

    private static func letters(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Markup-free text: tags dropped, entities decoded, whitespace collapsed.
    private static func plain(_ html: String) -> String {
        let text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeEntities(Substring(text)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ensp": " ", "emsp": " ",
        "thinsp": " ", "shy": "", "zwnj": "", "zwj": "", "mdash": "—", "ndash": "–", "hellip": "…",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«",
        "raquo": "»", "middot": "·", "bull": "•", "copy": "©", "reg": "®", "trade": "™", "deg": "°", "times": "×",
    ]
    private static let entity = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);")

    private static func decodeEntities(_ text: Substring) -> String {
        let s = String(text)
        guard s.contains("&") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in entity.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            var value: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                value = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if name.hasPrefix("#") {
                value = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                value = entities[name]
            }
            out += value ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// A path inside the zip from an href relative to `folder`.
    private static func resolve(_ href: String, in folder: String) -> String {
        var parts = folder.split(separator: "/")
        for part in (href.removingPercentEncoding ?? href).split(separator: "/") {
            if part == ".." { _ = parts.popLast() } else if part != "." { parts.append(part) }
        }
        return parts.joined(separator: "/")
    }

    // MARK: Regular expressions

    /// Each match as [whole match, group 1, group 2, …].
    private static func matches(_ pattern: String, in s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
    private static func all(_ pattern: String, in s: String) -> [String] { matches(pattern, in: s).map { $0[0] } }
    private static func first(_ pattern: String, in s: String) -> String? { matches(pattern, in: s).first?[1] }
    private static func attribute(_ name: String, in tag: String) -> String? {
        matches(#"(?:^|\s)\#(name)\s*=\s*(["'])(.*?)\1"#, in: tag).first?[2]
    }
}

/// Just enough of the ZIP format to read an EPUB: stored and deflated files.
private struct Zip {
    private let bytes: [UInt8]
    private var entries: [String: (offset: Int, method: Int, size: Int)] = [:]

    init?(_ data: Data) {
        bytes = [UInt8](data)
        // The central directory, which lists every file, is found from the record at the end.
        guard bytes.count >= 22,
              let end = stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1)
                .first(where: { u32($0) == 0x0605_4b50 })
        else { return nil }
        var p = u32(end + 16)
        for _ in 0..<u16(end + 10) {
            guard u32(p) == 0x0201_4b50 else { return nil }
            let nameLength = u16(p + 28)
            guard p + 46 + nameLength <= bytes.count else { return nil }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries[name] = (offset: u32(p + 42), method: u16(p + 10), size: u32(p + 20))
            p += 46 + nameLength + u16(p + 30) + u16(p + 32)
        }
    }

    func text(_ name: String) -> String? { data(name).flatMap(BookCodec.decode) }

    func data(_ name: String) -> Data? {
        guard let entry = entries[name] ?? entries.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value,
              u32(entry.offset) == 0x0403_4b50
        else { return nil }
        let start = entry.offset + 30 + u16(entry.offset + 26) + u16(entry.offset + 28)
        guard start + entry.size <= bytes.count else { return nil }
        let stored = Data(bytes[start..<(start + entry.size)])
        switch entry.method {
        case 0: return stored
        case 8: return try? (stored as NSData).decompressed(using: .zlib) as Data   // raw DEFLATE
        default: return nil
        }
    }

    private func u16(_ at: Int) -> Int { at >= 0 && at + 2 <= bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : 0 }
    private func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
}
