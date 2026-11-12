import Foundation

/// The on-watch book format: one paragraph per line, UTF-8, LZMA-compressed. A paragraph
/// that starts with `chapterMark` begins a chapter. The phone packs, the watch unpacks.
enum BookCodec {
    static let chapterMark: Character = "\u{1}"

    /// A .txt or .md file as paragraphs, with chapters marked.
    static func paragraphs(fromText raw: Data, markdown: Bool) -> [String]? {
        guard let text = decode(raw) else { return nil }
        return withoutPrintedContents(paragraphs(from: text, markdown: markdown)).flatMap(split)
    }

    static func pack(_ paragraphs: [String]) -> Data? {
        try? (Data(paragraphs.joined(separator: "\n").utf8) as NSData).compressed(using: .lzma) as Data
    }

    static func unpack(_ packed: Data) -> [String] {
        guard let data = try? (packed as NSData).decompressed(using: .lzma) as Data else { return [] }
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
    }

    /// The title of a paragraph that begins a chapter; nil for any other paragraph.
    static func chapterTitle(_ paragraph: String) -> String? {
        guard paragraph.first == chapterMark else { return nil }
        return String(paragraph.dropFirst().drop { $0 == "#" || $0 == " " })
    }

    /// Many books print their own table of contents: a run of chapter titles, each of
    /// which appears again later at the real chapter. Those copies are not chapters.
    static func withoutPrintedContents(_ paragraphs: [String]) -> [String] {
        func key(_ p: String) -> String { String(p.filter { $0.isLetter || $0.isNumber }) }
        func marked(_ i: Int) -> Bool { paragraphs.indices.contains(i) && paragraphs[i].first == chapterMark }
        var out = paragraphs
        var later = Set<String>()   // titles of chapters after the current paragraph
        for i in paragraphs.indices.reversed() where marked(i) {
            let title = key(paragraphs[i])
            if (marked(i - 1) || marked(i + 1)) && later.contains(title) { out[i].removeFirst() }
            later.insert(title)
        }
        return out
    }

    /// UTF-8 first, then let Foundation guess (GBK, Big5, Shift-JIS, Latin-1…).
    static func decode(_ raw: Data) -> String? {
        if let text = String(data: raw, encoding: .utf8) { return text }
        // Guessing reads the data many times over (half a minute for a 13 MB novel), so
        // guess from the start, cut at a line break so no character is split in half.
        let start = raw.prefix(64 * 1024)
        let sample = start.lastIndex(of: 0x0A).map { start[...$0] } ?? start
        let guess = NSString.stringEncoding(for: sample, encodingOptions: nil, convertedString: nil, usedLossyConversion: nil)
        if guess != 0, let text = String(data: raw, encoding: String.Encoding(rawValue: guess)) { return text }
        var guessed: NSString?
        NSString.stringEncoding(for: raw, encodingOptions: nil, convertedString: &guessed, usedLossyConversion: nil)
        return guessed as String?
    }

    // Plain text has no real chapter markup, so these are guesses from how chapter
    // headings are usually written: a short line like "第十二章 …", "Chapter 12", "PART II".
    private static let chineseChapter = try! NSRegularExpression(
        pattern: "^(第[0-9０-９零〇一二三四五六七八九十百千万两]+[章回节節卷集部篇]|序章|序言|楔子|引子|前言|尾声|尾聲|后记|後記|番外)")
    private static let englishChapter = try! NSRegularExpression(
        pattern: "^(chapter\\s+\\S+|(part|book|volume)\\s+([0-9]+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten)\\b|prologue|epilogue)",
        options: .caseInsensitive)

    static func isChapter(_ line: String, markdown: Bool) -> Bool {
        if markdown { return line.hasPrefix("# ") || line.hasPrefix("## ") }
        guard line.count <= 50 else { return false }
        let range = NSRange(line.startIndex..., in: line)
        return chineseChapter.firstMatch(in: line, range: range) != nil
            || englishChapter.firstMatch(in: line, range: range) != nil
    }

    /// Drops blank lines and indentation, re-flows hard-wrapped text so the watch can
    /// wrap each paragraph to its own width, and marks chapter headings.
    static func paragraphs(from text: String, markdown: Bool = false) -> [String] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let filled = lines.filter { !$0.isEmpty }

        // Hard-wrapped (Project Gutenberg, 80-column Markdown): paragraphs are separated
        // by blank lines, long lines stop at a typical wrap column, and at least a quarter
        // of the lines end close to it. Otherwise every line is a paragraph.
        // (95th percentile, not the maximum: a single stray long line shouldn't decide.)
        let lengths = filled.map(\.count).sorted()
        let column = lengths.isEmpty ? 0 : lengths[lengths.count * 95 / 100]
        let hardWrapped = filled.count < lines.count
            && (60...100).contains(column)
            && lengths.filter { $0 >= column - 15 }.count * 4 >= lengths.count

        var out: [String] = []
        var joinable = false   // may the next line be appended to the last paragraph?
        var fenced = false     // inside a ``` code block, whose marker lines are dropped
        for line in lines {
            if line.hasPrefix("```") {
                fenced.toggle()
                joinable = false
            } else if line.isEmpty {
                joinable = false
            } else if hardWrapped && joinable && !fenced && !startsBlock(line) {
                out[out.count - 1] += " " + line
            } else if !fenced && isChapter(line, markdown: markdown) {
                out.append(String(chapterMark) + line)
                joinable = false
            } else {
                out.append(line)
                joinable = !fenced && !line.hasPrefix("#")
            }
        }
        return out
    }

    /// Breaks a paragraph longer than a screen or two at sentence ends. The reading
    /// position is saved per paragraph, so this keeps it close to where you stopped.
    static func split(_ paragraph: String) -> [String] {
        let limit = 400
        guard paragraph.count > limit else { return [paragraph] }
        var pieces: [String] = []
        var current = ""
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            if !current.isEmpty && current.count + sentence.count > limit && !endsWithAbbreviation(current) {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
            current += sentence
        }
        if !current.isEmpty { pieces.append(current.trimmingCharacters(in: .whitespaces)) }
        return pieces
    }

    /// The sentence finder ends a sentence at "Mr." or "J."; breaking there would leave
    /// "Bennet said…" at the start of the next piece.
    private static let abbreviations: Set = ["mr.", "mrs.", "ms.", "dr.", "st.", "mt.", "jr.", "sr.", "prof.", "rev.",
                                             "gen.", "col.", "capt.", "vs.", "etc.", "e.g.", "i.e.", "no.", "vol.", "ch."]

    private static func endsWithAbbreviation(_ text: String) -> Bool {
        guard let word = text.split(whereSeparator: \.isWhitespace).last else { return false }
        if abbreviations.contains(word.lowercased()) { return true }
        return word.count == 2 && word.first!.isUppercase && word.last == "."   // an initial, as in "J. Smith"
    }

    /// Markdown lines that must stay on their own: headings, lists, quotes, tables.
    private static func startsBlock(_ line: String) -> Bool {
        if let first = line.first, "#>|".contains(first) { return true }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
        let digits = line.prefix { $0.isNumber }
        return !digits.isEmpty && line.dropFirst(digits.count).hasPrefix(". ")
    }
}
