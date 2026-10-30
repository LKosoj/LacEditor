import Foundation

enum FocusScope: String {
    case paragraph, sentence
}

enum FocusSentenceService {
    /// Диапазон (UTF-16) всех предложений, которые затрагивает выделение; nil для неверного выделения.
    static func activeRange(in text: NSString, selection: NSRange) -> NSRange? {
        guard selection.location != NSNotFound, selection.location <= text.length,
              selection.length <= text.length - selection.location else { return nil }
        if text.length == 0 { return NSRange(location: 0, length: 0) }
        let startProbe = selection.location
        let endProbe = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        guard let first = sentence(at: startProbe, in: text),
              let last = endProbe == startProbe ? first : sentence(at: endProbe, in: text) else { return nil }
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    private static func sentence(at position: Int, in text: NSString) -> NSRange? {
        let paragraph = text.paragraphRange(for: NSRange(location: position, length: 0))
        var start = 0, end = 0, contentsEnd = 0
        text.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: paragraph)
        let content = NSRange(location: start, length: contentsEnd - start)
        // Пустой абзац (и позиция после последнего \n): поведение как у режима абзаца.
        guard content.length > 0 else { return paragraph }
        let probe = min(position, contentsEnd)   // позиция на переводе строки относится к последнему предложению
        var found: NSRange?
        var lastSeen = content
        text.enumerateSubstrings(in: content, options: [.bySentences, .substringNotRequired]) { _, range, _, stop in
            lastSeen = range
            if probe >= range.location && probe < NSMaxRange(range) {
                found = range
                stop.pointee = true
            }
        }
        return found ?? lastSeen
    }
}
