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
    static let canvas = adaptiveColor(light: (0.953, 0.957, 0.969), dark: (0.12, 0.125, 0.14))
    static let surface = adaptiveColor(light: (1, 1, 1), dark: (0.16, 0.165, 0.185))
    static let outline = Color(nsColor: .separatorColor).opacity(0.4)

    private static func adaptiveColor(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

/// Shared by settings and utility windows; the editor remains a flat canvas.
struct PreferenceGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 3)
            VStack(spacing: 0) { content() }
                .background(LacEditorDesign.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LacEditorDesign.outline, lineWidth: 0.5))
        }
    }
}

struct PreferenceRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var control: () -> Control
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            control().controlSize(.regular).fixedSize(horizontal: true, vertical: false)
        }.padding(16).frame(minHeight: 64)
    }
}

struct UtilityHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                .foregroundStyle(LacEditorDesign.accent).frame(width: 40, height: 40)
                .background(LacEditorDesign.selectionFill, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 19, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct UtilityWindowRoot<Content: View>: View {
    @ObservedObject var appState: AppState
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().environmentObject(appState)
            .preferredColorScheme(appState.preferredColorScheme)
            .tint(LacEditorDesign.accent)
            .background(WindowThemeCoordinator(theme: appState.theme,
                                               systemAppearanceDidChange: appState.refreshSystemAppearance))
    }
}

struct SoftRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? LacEditorDesign.accent.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .animation(reduceMotion || configuration.isPressed ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
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
