import AppKit

@main
enum EditorInteractionVerification {
    static func main() {
        _ = NSApplication.shared
        let textView = LacTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        textView.string = "first\nsecond\nthird"

        var trackingUpdates = 0
        var observedTrackingRange: NSRange?
        textView.selectionTrackingHandler = {
            trackingUpdates += 1
            observedTrackingRange = textView.selectedRange()
        }
        let draggedRange = NSRange(location: 0, length: 12)
        textView.setSelectedRange(
            draggedRange,
            affinity: .downstream,
            stillSelecting: true
        )
        require(
            observedTrackingRange == draggedRange,
            "drag selection is applied before the tracking callback"
        )
        require(
            trackingUpdates == 1,
            "drag selection triggers an immediate tracking update"
        )

        textView.setSelectedRange(
            NSRange(location: 0, length: 0),
            affinity: .downstream,
            stillSelecting: false
        )
        require(
            trackingUpdates == 1,
            "completed or programmatic selections use the normal delegate path"
        )

        let window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = textView
        textView.allowsUndo = true
        window.makeFirstResponder(textView)
        textView.string = "plain"
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.doCommand(by: #selector(NSTextView.insertTab(_:)))
        require(textView.string == "plain    ", "Tab inserts the configured indentation")
        require(textView.undoManager?.canUndo == true, "Tab registers an undo action")
        textView.undoManager?.undo()
        require(textView.string == "plain", "undo removes only the Tab indentation")
        textView.undoManager?.redo()
        require(textView.string == "plain    ", "redo restores the Tab indentation")
        window.close()

        print("Editor interaction verification passed")
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("Verification failed: \(message)")
        }
    }
}
