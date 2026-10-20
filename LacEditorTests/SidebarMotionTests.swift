import AppKit
import SwiftUI
import XCTest
@testable import LacEditor

@MainActor
final class SidebarMotionTests: XCTestCase {
    func testNestedGroupDisclosureReflowsFollowingGroupDuringAnimation() async throws {
        _ = NSApplication.shared
        let model = MotionModel()
        let host = NSHostingView(rootView: NestedMotionFixture(model: model))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let first = try XCTUnwrap(probe("header", in: host))
        let second = try XCTUnwrap(probe("following", in: host))
        func top(_ view: NSView) -> CGFloat {
            let frame = view.convert(view.bounds, to: host)
            return host.isFlipped ? frame.minY : host.bounds.maxY - frame.maxY
        }
        let original = top(second)
        let header = top(first)
        var positions: [CGFloat] = []
        model.expanded = false
        for _ in 0..<16 {
            try await Task.sleep(for: .milliseconds(16))
            host.layoutSubtreeIfNeeded()
            positions.append(top(second))
            XCTAssertEqual(top(first), header, accuracy: 1)
        }
        print("SIDEBAR_NESTED initial=\(original) samples=\(positions)")
        XCTAssertGreaterThan(Set(positions.map { Int($0.rounded()) }).count, 4)
    }

    func testDisclosureMovesFollowingHeaderContinuouslyAndReversesWithoutReplay() async throws {
        _ = NSApplication.shared
        let model = MotionModel()
        let host = NSHostingView(rootView: MotionFixture(model: model))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let header = try XCTUnwrap(probe("header", in: host))
        let first = try XCTUnwrap(probe("first", in: host))
        let following = try XCTUnwrap(probe("following", in: host))
        func top(_ view: NSView) -> CGFloat {
            let frame = view.convert(view.bounds, to: host)
            return host.isFlipped ? frame.minY : host.bounds.maxY - frame.maxY
        }
        let initialHeader = top(header)
        let initialRow = top(first)
        let initialFollowing = top(following)
        var samples: [CGFloat] = []
        model.expanded = false
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(16))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(top(header), initialHeader, accuracy: 0.5)
            XCTAssertEqual(top(first), initialRow, accuracy: 0.5)
            samples.append(top(following))
        }
        let reversal = samples.last!
        model.expanded = true
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(16))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(top(header), initialHeader, accuracy: 0.5)
            XCTAssertEqual(top(first), initialRow, accuracy: 0.5)
            samples.append(top(following))
        }
        print("SIDEBAR_MOTION initial=\(initialFollowing) reversal=\(reversal) samples=\(samples)")
        XCTAssertLessThan(reversal, initialFollowing - 10)
        XCTAssertEqual(samples.last!, initialFollowing, accuracy: 1)
        XCTAssertGreaterThan(Set(samples.map { Int($0.rounded()) }).count, 5,
                             "Following content must reflow throughout the reveal, not jump at its endpoints")
        XCTAssertLessThan(abs(samples[0] - initialFollowing), 50)
        for pair in zip(samples.dropFirst(6), samples.dropFirst(7)) {
            XCTAssertGreaterThanOrEqual(pair.1 + 0.5, pair.0, "A reversed reveal must not replay the old collapse")
        }
    }

    private func probe(_ name: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "motion.\(name)" { return view }
        return view.subviews.lazy.compactMap { self.probe(name, in: $0) }.first
    }

}

@MainActor
private final class MotionModel: ObservableObject {
    @Published var expanded = true
}

private struct MotionFixture: View {
    @ObservedObject var model: MotionModel
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                VStack(spacing: 4) {
                    MotionProbe(name: "header").frame(height: 28)
                    SidebarDisclosure(isExpanded: model.expanded) {
                        MotionProbe(name: "first").frame(height: 46)
                        Color.clear.frame(height: 46)
                        Color.clear.frame(height: 46)
                    }
                }
                MotionProbe(name: "following").frame(height: 28)
            }.padding(10)
        }
    }
}

private struct NestedMotionFixture: View {
    @ObservedObject var model: MotionModel
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                Text("分组").frame(height: 28)
                SidebarDisclosure(isExpanded: true) {
                    VStack(spacing: 2) {
                        MotionProbe(name: "header").frame(height: 32)
                        SidebarDisclosure(isExpanded: model.expanded) {
                            MotionProbe(name: "first").frame(height: 46)
                            Color.clear.frame(height: 46)
                            Color.clear.frame(height: 46)
                        }
                    }
                    MotionProbe(name: "following").frame(height: 32)
                }
            }.padding(10)
        }
    }
}

private struct MotionProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("motion.\(name)")
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
