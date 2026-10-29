import AppKit

/// Temporary native editor for one raw Markdown cell. The document remains in
/// the parent text storage; this view only owns the current input composition.
final class MarkdownTableCellEditor: NSTextView, NSTextViewDelegate {
    var beginTextChecking: (([NSSpellChecker.OptionKey: Any]) -> [NSSpellChecker.OptionKey: Any])?
    var filterTextCheckingResults: (([NSTextCheckingResult], [NSSpellChecker.OptionKey: Any]) -> [NSTextCheckingResult])?

    func textView(_ view: NSTextView, willCheckTextIn range: NSRange, options: [NSSpellChecker.OptionKey: Any],
                  types checkingTypes: UnsafeMutablePointer<NSTextCheckingTypes>) -> [NSSpellChecker.OptionKey: Any] {
        beginTextChecking?(options) ?? options
    }

    func textView(_ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes,
                  options: [NSSpellChecker.OptionKey: Any], results: [NSTextCheckingResult],
                  orthography: NSOrthography, wordCount: Int) -> [NSTextCheckingResult] {
        filterTextCheckingResults?(results, options) ?? results
    }
    static func projection(_ raw: String) -> MarkdownPresentationParser.Projection {
        MarkdownPresentationParser.projection(raw)
    }

    static func sourceText(raw: String, display: String) -> String? {
        let old = projection(raw), before = old.text as NSString, after = display as NSString
        var prefix = 0, suffix = 0
        while prefix < min(before.length, after.length), before.character(at: prefix) == after.character(at: prefix) { prefix += 1 }
        while suffix < before.length - prefix && suffix < after.length - prefix &&
                before.character(at: before.length - suffix - 1) == after.character(at: after.length - suffix - 1) { suffix += 1 }
        func boundary(_ text: NSString, _ offset: Int) -> Bool {
            offset == 0 || offset == text.length ||
                !(0xd800...0xdbff).contains(text.character(at: offset - 1)) || !(0xdc00...0xdfff).contains(text.character(at: offset))
        }
        while prefix > 0 && (!boundary(before, prefix) || !boundary(after, prefix)) { prefix -= 1 }
        while suffix > 0 && (!boundary(before, before.length - suffix) || !boundary(after, after.length - suffix)) { suffix -= 1 }
        let rawStart = old.rawBoundaries[prefix], rawEnd = old.rawBoundaries[before.length - suffix]
        let input = after.substring(with: NSRange(location: prefix, length: after.length - prefix - suffix))
        let source = raw as NSString
        var output = Array(source.substring(to: rawStart).utf16)
        func trailingSlashes() -> Int {
            var count = 0
            for value in output.reversed() {
                if value != 92 { break }
                count += 1
            }
            return count
        }
        for unit in input.utf16 {
            if unit == 10 {
                if trailingSlashes() % 2 == 1 { output.append(92) }
                output.append(contentsOf: "<br>".utf16)
            } else if unit == 124 {
                let slashes = trailingSlashes()
                output.append(contentsOf: repeatElement(92, count: slashes % 2 == 0 ? 1 : 2))
                output.append(unit)
            } else { output.append(unit) }
        }
        if suffix > 0, before.character(at: before.length - suffix) == 10, trailingSlashes() % 2 == 1 {
            output.append(92)
        }
        output.append(contentsOf: source.substring(from: rawEnd).utf16)
        let result = String(decoding: output, as: UTF16.self)
        let projected = projection(result)
        if projected.text == display { return result }
        let actual = projected.text as NSString
        var actualIndex = 0, desiredIndex = 0, escapes: [Int] = []
        while actualIndex < actual.length && desiredIndex < after.length {
            if actual.character(at: actualIndex) == after.character(at: desiredIndex) {
                actualIndex += 1
                desiredIndex += 1
                continue
            }
            guard actual.character(at: actualIndex) == 10 else { return nil }
            let lengths = [4, 5, 6]
            guard let length = lengths.first(where: { length in
                desiredIndex + length <= after.length &&
                    ["<br>", "<br/>", "<br />"].contains(after.substring(with: NSRange(location: desiredIndex, length: length)).lowercased())
            }) else { return nil }
            escapes.append(projected.rawBoundaries[actualIndex])
            actualIndex += 1
            desiredIndex += length
        }
        guard actualIndex == actual.length, desiredIndex == after.length, !escapes.isEmpty else { return nil }
        let originalUnits = Array(result.utf16)
        var corrected: [UInt16] = [], escapeIndex = 0
        corrected.reserveCapacity(originalUnits.count + escapes.count)
        for (position, unit) in originalUnits.enumerated() {
            if escapeIndex < escapes.count && escapes[escapeIndex] == position {
                corrected.append(92)
                escapeIndex += 1
            }
            corrected.append(unit)
        }
        let value = String(decoding: corrected, as: UTF16.self)
        return projection(value).text == display ? value : nil
    }
    var contentDidChange: (() -> Void)?
    var compositionStartHandler: ((Bool) -> Void)?
    var navigate: ((Bool) -> Bool)?
    var undoAction: ((Bool) -> Bool)?
    var rowCommand: ((Bool) -> Bool)?
    var validateChange: ((NSRange, String) -> Bool)?
    var imageTransfer: ((NSPasteboard, Bool) -> Bool)?
    var canTransferImage: ((NSPasteboard, Bool) -> Bool)?
    var richPaste: ((NSPasteboard) -> Bool)?
    var richCopy: ((NSPasteboard) -> Bool)?
    var markdownLinkHandler: ((NSPoint) -> Bool)?
    var mathReferenceHandler: ((NSPoint) -> Bool)?
    var emojiCompletionRange: NSRange?
    var emojiCompletionSpelling = ""
    var emojiCompletionValues: [String] = []
    var acceptEmojiCompletion: ((String, NSRange) -> Bool)?
    var dismissEmojiCompletion: (() -> Void)?
    var emojiTyped: ((String) -> Void)?
    var mathPairAllowed: ((NSRange) -> Bool)?
    var mathPairEnabled: (() -> Bool)?
    private var emojiKeyCharacter: String?
    private var mathPair: MarkdownAutoPairService.Pair?
    private var isMathPairInput = false

    override var rangeForUserCompletion: NSRange { emojiCompletionRange ?? super.rangeForUserCompletion }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard emojiCompletionRange == charRange else { return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index) }
        return emojiCompletionValues
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal: Bool) {
        guard emojiCompletionRange == charRange else {
            super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: isFinal)
            return
        }
        if isFinal { _ = acceptEmojiCompletion?(word, charRange); dismissEmojiCompletion?() }
    }
    private var changingMarkedText = false

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            if hasMarkedText() { return }
            if mathReferenceHandler?(convert(event.locationInWindow, from: nil)) == true { return }
            if markdownLinkHandler?(convert(event.locationInWindow, from: nil)) == true { return }
        }
        super.mouseDown(with: event)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let replacementString, validateChange?(affectedCharRange, replacementString) == false { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String)
        let wasMarked = hasMarkedText()
        let selection = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if !wasMarked, isEditable, selectedRanges.count == 1, mathPairEnabled?() == true, text == "$", text == emojiKeyCharacter,
           let storage = textStorage,
           let action = MarkdownAutoPairService.action(in: storage.mutableString, selection: selection, character: "$",
                                                        brackets: false, markdown: true, pairs: mathPair.map { [$0] } ?? []) {
            switch action {
            case let .skip(location): setSelectedRange(NSRange(location: location, length: 0)); return
            case let .replace(range, replacement, finalSelection, pair):
                if mathPairAllowed?(range) == true {
                    mathPair = pair
                    isMathPairInput = true
                    super.insertText(replacement, replacementRange: range)
                    isMathPairInput = false
                    if NSMaxRange(finalSelection) <= storage.length,
                       range.location + (replacement as NSString).length <= storage.length,
                       storage.mutableString.substring(with: NSRange(location: range.location, length: (replacement as NSString).length)) == replacement {
                        setSelectedRange(finalSelection)
                    } else { mathPair = nil }
                    return
                }
            }
        }
        if !wasMarked, let text, text == emojiKeyCharacter, var pair = mathPair,
           selection.location >= pair.open + pair.count, NSMaxRange(selection) <= pair.close {
            pair.close += (text as NSString).length - selection.length
            mathPair = pair
            isMathPairInput = true
        } else { mathPair = nil }
        if let text, text.contains("\r") {
            super.insertText(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"), replacementRange: replacementRange)
        } else { super.insertText(insertString, replacementRange: replacementRange) }
        isMathPairInput = false
        if !wasMarked, let text, text == emojiKeyCharacter { emojiTyped?(text) }
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if !hasMarkedText(), isEditable, selectedRanges.count == 1, selection.length == 0, mathPairEnabled?() == true,
           let pair = mathPair, pair.close == selection.location, pair.close == pair.open + 1,
           let storage = textStorage, pair.close < storage.length,
           storage.mutableString.substring(with: NSRange(location: pair.open, length: 2)) == "$$" {
            mathPair = nil
            super.insertText("", replacementRange: NSRange(location: pair.open, length: 2))
            return
        }
        mathPair = nil
        super.deleteBackward(sender)
    }

    override func paste(_ sender: Any?) {
        if richPaste?(.general) == true { return }
        if imageTransfer?(.general, true) == true { return }
        super.paste(sender)
    }

    override func copy(_ sender: Any?) {
        if richCopy?(.general) == true { return }
        super.copy(sender)
    }

    override func updateDragTypeRegistration() {
        super.updateDragTypeRegistration()
        if isEditable { registerForDraggedTypes(Array(Set(readablePasteboardTypes + [.fileURL, .URL, .png, .tiff]))) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if isEditable && canTransferImage?(sender.draggingPasteboard, false) == true {
            return hasMarkedText() ? [] : .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let imageTransfer, isEditable, canTransferImage?(sender.draggingPasteboard, false) == true else {
            return super.performDragOperation(sender)
        }
        guard !hasMarkedText() else { return false }
        let previous = selectedRange()
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        if imageTransfer(sender.draggingPasteboard, false) { return true }
        setSelectedRange(previous)
        return super.performDragOperation(sender)
    }

    override func keyDown(with event: NSEvent) {
        let previous = emojiKeyCharacter
        let inputModifiers = event.modifierFlags.intersection([.command, .control, .option])
        emojiKeyCharacter = inputModifiers.isEmpty && event.characters?.utf16.count == 1 ? event.characters : nil
        defer { emojiKeyCharacter = previous }
        if !hasMarkedText(), event.keyCode == 53, emojiCompletionRange != nil {
            super.keyDown(with: event); dismissEmojiCompletion?(); return
        }
        if !hasMarkedText(), event.keyCode == 48, emojiCompletionRange != nil { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if isEditable, !hasMarkedText(), (event.keyCode == 36 || event.keyCode == 76), modifiers == [.command],
           rowCommand?(false) == true { return }
        if isEditable, !hasMarkedText(), event.keyCode == 51, modifiers == [.command, .shift],
           rowCommand?(true) == true { return }
        if !hasMarkedText(), event.keyCode == 48,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           navigate?(event.modifierFlags.contains(.shift)) == true { return }
        if !hasMarkedText(), event.charactersIgnoringModifiers?.lowercased() == "z",
           event.modifierFlags.contains(.command),
           event.modifierFlags.intersection([.control, .option]).isEmpty,
           undoAction?(event.modifierFlags.contains(.shift)) == true { return }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if emojiCompletionRange != nil && (selector == #selector(insertTab(_:)) || selector == #selector(insertBacktab(_:))) {
            super.doCommand(by: selector); return
        }
        if !hasMarkedText(), selector == #selector(insertTab(_:)), navigate?(false) == true { return }
        if !hasMarkedText(), selector == #selector(insertBacktab(_:)), navigate?(true) == true { return }
        super.doCommand(by: selector)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        mathPair = nil
        dismissEmojiCompletion?()
        changingMarkedText = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        compositionStartHandler?(hasMarkedText())
        changingMarkedText = false
        contentDidChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        if !changingMarkedText { contentDidChange?() }
    }

    override func didChangeText() {
        if !isMathPairInput { mathPair = nil }
        super.didChangeText()
        if !changingMarkedText { contentDidChange?() }
    }
}
