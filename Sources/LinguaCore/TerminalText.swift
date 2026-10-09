import Foundation

/// Script detection for routing: CJK text gets translated to the second language, Latin text gets corrected.
public enum Script {
    public static func isCJK(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return false }
        let cjk = letters.filter { isWide($0) }.count
        return cjk * 10 >= letters.count * 3
    }
    /// East Asian wide / fullwidth code points (the ones a terminal renders in two cells).
    public static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F,
             0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}

/// Makes sense of a terminal's accessibility value, which is the whole screen as text: one line per row,
/// wide characters padded with a space, panes separated by box-drawing verticals.
public enum TerminalText {
    static let verticals: Set<Character> = ["│", "┃", "║", "┆", "┇", "┊", "┋"]

    /// "還 有 一 個" → "還有一個": the space after a wide character is cell padding, not content.
    public static func collapseWide(_ line: String) -> String {
        var output = ""
        var skipSpace = false
        for character in line.replacingOccurrences(of: "\u{00A0}", with: " ") {
            if skipSpace, character == " " { skipSpace = false; continue }
            skipSpace = character.unicodeScalars.first.map(Script.isWide) ?? false
            output.append(character)
        }
        return output
    }

    /// Column range of the pane that contains `column`, bounded by vertical pane borders.
    public static func segment(of line: String, column: Int) -> Range<Int> {
        let characters = Array(line)
        let column = max(0, min(column, characters.count))
        var start = 0
        var end = characters.count
        for index in stride(from: column - 1, through: 0, by: -1) where verticals.contains(characters[index]) { start = index + 1; break }
        for index in column..<characters.count where verticals.contains(characters[index]) { end = index; break }
        return start..<max(start, end)
    }

    public static func slice(_ line: String, _ range: Range<Int>) -> String {
        let characters = Array(line)
        guard range.lowerBound < characters.count else { return "" }
        return String(characters[range.lowerBound..<min(range.upperBound, characters.count)])
    }

    /// A row that is only a rule or blank: the edge of an input box or a section.
    public static func isBoundary(_ text: String) -> Bool {
        let trimmed = text.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        return trimmed.unicodeScalars.allSatisfy { (0x2500...0x257F).contains($0.value) || $0 == " " }
    }

    /// What is being typed at the prompt: the cursor row after the prompt marker, plus wrapped rows down to the next rule or blank row.
    public static func inputText(lines: [String], cursorLine: Int, cursorColumn: Int, prompts: [String] = ["❯", ">", "$", "%", "›"]) -> String? {
        guard lines.indices.contains(cursorLine) else { return nil }
        let range = segment(of: lines[cursorLine], column: cursorColumn)
        var first = slice(lines[cursorLine], range).replacingOccurrences(of: "\u{00A0}", with: " ")
        // The prompt marker is the first visible glyph of the row; whatever follows it (padding included) is the draft.
        // Only a row that starts with a prompt marker is an input box; a cursor parked in output (an agent working, say) is not typing.
        let leading = first.drop { $0 == " " }
        guard let marker = prompts.first(where: { leading.hasPrefix($0) }) else { return nil }
        first = String(leading.dropFirst(marker.count))
        // Nothing on the prompt row means nothing typed; rows below it are the box's frame or a status line, not a wrapped draft.
        guard !first.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var rows = [first]
        for index in (cursorLine + 1)..<lines.count {
            let row = slice(lines[index], range)
            if isBoundary(row) { break }
            rows.append(row)
        }
        let text = rows.map { collapseWide($0).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Live status rows such as an agent spinner ("· Ruminating… (10m 5s · ↓ 17.1k tokens)") change every second and are never content.
    public static func isStatus(_ row: String) -> Bool {
        row.range(of: #"\(\d+(m|s)( \d+s)?( · [^)]*)?\)|esc to interrupt|ctrl\+[a-z] to "#, options: .regularExpression) != nil
    }
    /// Rows above the cursor (in the cursor's pane) that were not on screen last time: the agent's new output, never the user's own input box.
    /// Returns nil when the screen changed wholesale, which means a different pane or session, not new output.
    public static func newLines(previous: [String], current: [String], cursorLine: Int, cursorColumn: Int) -> [String]? {
        guard current.indices.contains(cursorLine) else { return [] }
        let range = segment(of: current[cursorLine], column: cursorColumn)
        func rows(_ lines: [String], upTo limit: Int) -> [String] {
            lines.prefix(limit).map { collapseWide(slice($0, range)).trimmingCharacters(in: .whitespaces) }.filter { !isBoundary($0) && !isStatus($0) }
        }
        let before = Set(rows(previous, upTo: previous.count))
        let now = rows(current, upTo: cursorLine)
        let fresh = now.filter { !before.contains($0) }
        if !previous.isEmpty, now.count >= 8, fresh.count * 10 > now.count * 6 { return nil }
        return fresh
    }
}
