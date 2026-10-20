import AppKit
import SwiftUI

enum LacEditorDesign {
    static let sidebarWidth: CGFloat = 250
    static let sidebarRowHeight: CGFloat = 34
    static let tabBarHeight: CGFloat = 34
    static let tabHeight: CGFloat = 28
    static let statusBarHeight: CGFloat = 24
    static let compactCornerRadius: CGFloat = 6
    static let edgeFadeWidth: CGFloat = 24

    static let structuralAnimation = Animation.easeOut(duration: 0.18)
    static let chromeAnimation = Animation.easeInOut(duration: 0.16)
    static let hoverAnimation = Animation.easeOut(duration: 0.09)
    static let sidebarDisclosureAnimation = Animation.easeInOut(duration: 0.22)

    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.63, green: 0.65, blue: 0.95, alpha: 1)
            : NSColor(red: 0.36, green: 0.38, blue: 0.73, alpha: 1)
    })
    static let hoverFill = Color.primary.opacity(0.045)
    static let selectionFill = accent.opacity(0.12)
}

/// Animate only the clipped body. Headers never participate in the reveal's
/// placement, and children keep their natural size throughout the animation.
struct SidebarDisclosure<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        SidebarRevealLayout(progress: isExpanded ? 1 : 0) {
            VStack(spacing: 2) { content() }
                .transaction { $0.animation = nil }
        }
        .clipped()
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
        .animation(reduceMotion ? nil : (isExpanded
            ? .timingCurve(0.22, 1, 0.36, 1, duration: 0.22)
            : .easeInOut(duration: 0.18)), value: isExpanded)
    }
}

struct SidebarRevealLayout: Layout {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? size.width, height: size.height * min(max(progress, 0), 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// The same native material used by Finder's sidebar. AppKit follows the
/// window active state automatically, including the dimmed inactive variant.
struct SidebarMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
        nsView.blendingMode = .behindWindow
        nsView.state = .followsWindowActiveState
    }
}

/// Keeps SwiftUI List's underlying scroll view on the native overlay style,
/// which follows the window's active appearance instead of drawing a dark
/// legacy track.
struct NativeScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguratorView {
        ConfiguratorView()
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.configureScrollViews()
    }

    final class ConfiguratorView: NSView {
        private weak var configuredScrollView: NSScrollView?
        private var pendingConfiguration: DispatchWorkItem?

        deinit { pendingConfiguration?.cancel() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureScrollViews()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureScrollViews()
        }

        func configureScrollViews() {
            pendingConfiguration?.cancel()
            if let scrollView = enclosingScrollView {
                guard configuredScrollView !== scrollView else { return }
                configuredScrollView = scrollView
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
            } else if window != nil {
                // SwiftUI attaches this bridge inside the scroll content. One
                // deferred attempt handles attachment without walking a window.
                let work = DispatchWorkItem { [weak self] in
                    guard let self, let scrollView = self.enclosingScrollView,
                          self.configuredScrollView !== scrollView else { return }
                    self.configuredScrollView = scrollView
                    scrollView.scrollerStyle = .overlay
                    scrollView.autohidesScrollers = true
                }
                pendingConfiguration = work
                DispatchQueue.main.async(execute: work)
            }
        }
    }
}
