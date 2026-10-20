import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarDragPayload: Codable {
    static let fileType = UTType(exportedAs: "com.laceditor.sidebar-file")
    static let groupType = UTType(exportedAs: "com.laceditor.sidebar-group")
    static let supportedTypes: [UTType] = [fileType, groupType, .fileURL]
    enum Kind: String, Codable {
        case file
        case group
    }

    let kind: Kind
    let path: String?
    let groupID: UUID?
    let sourceGroupID: UUID?
    let isFavorite: Bool

    static func file(_ url: URL, location: SidebarFileLocation) -> Self {
        let groupID: UUID?
        let isFavorite: Bool
        switch location {
        case .favorites:
            groupID = nil
            isFavorite = true
        case let .group(id):
            groupID = id
            isFavorite = false
        case .recent:
            groupID = nil
            isFavorite = false
        }
        return Self(
            kind: .file,
            path: url.path,
            groupID: nil,
            sourceGroupID: groupID,
            isFavorite: isFavorite
        )
    }

    static func group(_ id: UUID) -> Self {
        Self(
            kind: .group,
            path: nil,
            groupID: id,
            sourceGroupID: nil,
            isFavorite: false
        )
    }

    func itemProvider() -> NSItemProvider {
        let provider = path.map { NSItemProvider(object: URL(fileURLWithPath: $0) as NSURL) } ?? NSItemProvider()
        let type = kind == .group ? Self.groupType : Self.fileType
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(try? JSONEncoder().encode(self), nil)
            return nil
        }
        return provider
    }

    static func load(from info: DropInfo, completion: @escaping (Self) -> Void) -> Bool {
        load(providers: info.itemProviders(for: supportedTypes), completion: completion)
    }

    @discardableResult
    static func load(providers: [NSItemProvider], completion: @escaping (Self) -> Void) -> Bool {
        let valid = providers.filter { provider in
            supportedTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }
        // Load sequentially to preserve Finder's provider order even when its
        // asynchronous callbacks complete at different speeds.
        func next(_ index: Int) {
            guard index < valid.count else { return }
            let provider = valid[index]
            if let type = [fileType, groupType].first(where: {
                provider.hasItemConformingToTypeIdentifier($0.identifier)
            }) {
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    let payload = data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
                    DispatchQueue.main.async {
                        if let payload { completion(payload) }
                        next(index + 1)
                    }
                }
            } else {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let value = item as? NSURL { url = value as URL }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = nil }
                    let accepted = url.flatMap { isSupportedFile($0) ? $0 : nil }
                    DispatchQueue.main.async {
                        if let accepted { completion(.file(accepted, location: .recent)) }
                        next(index + 1)
                    }
                }
            }
        }
        next(0)
        return !valid.isEmpty
    }

    private static func isSupportedFile(_ url: URL) -> Bool {
        guard FileService.supportedExtensions.contains(
            url.pathExtension.lowercased()
        ) else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }
}

enum SidebarDropPlacement: Equatable { case before, after, inside }

enum SidebarDropTarget: Equatable {
    case file(URL, SidebarFileLocation), filesEnd(SidebarFileLocation)
    case group(UUID), groupsEnd, favoritesHeader, unavailable

    func accepts(isGroup: Bool) -> Bool {
        switch self {
        case .group: true
        case .groupsEnd: isGroup
        case .file(_, .recent), .filesEnd(.recent), .unavailable: false
        default: !isGroup
        }
    }

    func placement(y: CGFloat, height: CGFloat, isGroup: Bool) -> SidebarDropPlacement {
        switch self {
        case .file: y < height / 2 ? .before : .after
        case .group: isGroup ? (y < height / 2 ? .before : .after) : .inside
        case .favoritesHeader: .inside
        default: .before
        }
    }

    @MainActor
    func apply(_ payload: SidebarDragPayload, placement: SidebarDropPlacement, library: SidebarLibraryStore) {
        guard accepts(isGroup: payload.kind == .group) else { return }
        if payload.kind == .group, let id = payload.groupID {
            if case let .group(target) = self { library.moveGroup(id, before: target, after: placement == .after) }
            else if self == .groupsEnd { library.moveGroup(id, before: nil) }
            return
        }
        guard let path = payload.path else { return }
        let url = URL(fileURLWithPath: path)
        switch self {
        case let .file(target, .favorites):
            library.placeFavorite(url, relativeTo: target, after: placement == .after)
        case .filesEnd(.favorites), .favoritesHeader:
            library.placeFavorite(url, relativeTo: nil, after: false)
        case let .file(target, .group(id)):
            library.placeFile(url, inGroup: id, relativeTo: target, after: placement == .after)
        case let .group(id), let .filesEnd(.group(id)):
            library.placeFile(url, inGroup: id, relativeTo: nil, after: false)
        default: break
        }
    }
}

/// Presentation state is local to this sidebar. It never reorders on hover.
@MainActor
final class SidebarDragState: ObservableObject {
    @Published private(set) var target: SidebarDropTarget?
    @Published private(set) var placement: SidebarDropPlacement = .before
    weak var scrollView: NSScrollView?
    private var timer: Timer?
    private var expandWork: DispatchWorkItem?
    private let mouseLocation: () -> NSPoint
    private let isDragging: () -> Bool

    init(mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         isDragging: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }) {
        self.mouseLocation = mouseLocation
        self.isDragging = isDragging
    }

    deinit { timer?.invalidate(); expandWork?.cancel() }

    func hover(_ target: SidebarDropTarget, placement: SidebarDropPlacement, library: SidebarLibraryStore) {
        let changed = self.target != target || self.placement != placement
        if changed {
            expandWork?.cancel()
            self.target = target
            self.placement = placement
            if case let .group(id) = target, placement == .inside,
               library.groups.first(where: { $0.id == id })?.isExpanded == false {
                let work = DispatchWorkItem { [weak self, weak library] in
                    guard self?.target == target, self?.placement == .inside else { return }
                    library?.setExpanded(true, for: id)
                }
                expandWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
            }
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func leave(_ target: SidebarDropTarget) {
        guard self.target == target else { return }
        finish()
    }

    func finish() {
        timer?.invalidate(); timer = nil
        expandWork?.cancel(); expandWork = nil
        target = nil
    }

    /// Pure geometry shared by real scrolling and boundary tests.
    static func scrollDelta(y: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let edge = min(36, viewportHeight / 3)
        guard edge > 0, y >= 0, y <= viewportHeight else { return 0 }
        if y < edge { return -14 * (1 - y / edge) }
        if y > viewportHeight - edge { return 14 * (1 - (viewportHeight - y) / edge) }
        return 0
    }

    private func tick() {
        guard isDragging(), let scrollView, let window = scrollView.window,
              window.isVisible, !scrollView.isHiddenOrHasHiddenAncestor else {
            finish(); return
        }
        let point = scrollView.contentView.convert(window.convertPoint(fromScreen: mouseLocation()), from: nil)
        let clip = scrollView.contentView
        guard point.x >= clip.bounds.minX, point.x <= clip.bounds.maxX,
              point.y >= clip.bounds.minY, point.y <= clip.bounds.maxY else {
            finish(); return
        }
        let delta = Self.scrollDelta(y: point.y - clip.bounds.minY, viewportHeight: clip.bounds.height)
        guard delta != 0, let document = scrollView.documentView else { return }
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(maximum, max(0, clip.bounds.minY + delta))))
        scrollView.reflectScrolledClipView(clip)
    }
}

private struct SidebarDropArea: ViewModifier {
    @EnvironmentObject private var state: SidebarDragState
    let target: SidebarDropTarget
    let height: CGFloat
    let library: SidebarLibraryStore
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled, state.target == target {
                    if state.placement == .inside {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(LacEditorDesign.accent.opacity(0.7), lineWidth: 1)
                            .background(LacEditorDesign.selectionFill, in: RoundedRectangle(cornerRadius: 6))
                            .allowsHitTesting(false)
                    } else {
                        VStack(spacing: 0) {
                            if state.placement == .after { Spacer(minLength: 0) }
                            Capsule().fill(LacEditorDesign.accent).frame(height: 2)
                            if state.placement != .after { Spacer(minLength: 0) }
                        }.allowsHitTesting(false)
                    }
                }
            }
            .onDrop(of: SidebarDragPayload.supportedTypes, delegate: SidebarDropDelegate(
                target: target, height: height, library: library, state: state, enabled: enabled
            ))
    }
}

extension View {
    func sidebarDropArea(_ target: SidebarDropTarget, height: CGFloat, library: SidebarLibraryStore, enabled: Bool) -> some View {
        modifier(SidebarDropArea(target: target, height: height, library: library, enabled: enabled))
    }
}

private struct SidebarDropDelegate: DropDelegate {
    let target: SidebarDropTarget
    let height: CGFloat
    let library: SidebarLibraryStore
    let state: SidebarDragState
    let enabled: Bool

    func validateDrop(info: DropInfo) -> Bool {
        enabled && target.accepts(isGroup: info.hasItemsConforming(to: [SidebarDragPayload.groupType]))
            && info.hasItemsConforming(to: SidebarDragPayload.supportedTypes)
    }

    func dropEntered(info: DropInfo) { update(info) }
    func dropExited(info: DropInfo) { state.leave(target) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        update(info)
        return DropProposal(operation: info.hasItemsConforming(to: [SidebarDragPayload.groupType]) ? .move : .copy)
    }

    private func update(_ info: DropInfo) {
        guard validateDrop(info: info) else { return }
        state.hover(target, placement: target.placement(y: info.location.y, height: height,
                    isGroup: info.hasItemsConforming(to: [SidebarDragPayload.groupType])), library: library)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { state.finish(); return false }
        let placement = target.placement(y: info.location.y, height: height,
                                        isGroup: info.hasItemsConforming(to: [SidebarDragPayload.groupType]))
        state.finish()
        var previous: URL?
        return SidebarDragPayload.load(from: info) { payload in
            // Subsequent files follow the preceding one, preserving a multi-
            // file drop's order for both the upper and lower half of a row.
            if let previous, case let .file(_, location) = target {
                SidebarDropTarget.file(previous, location).apply(payload, placement: .after, library: library)
            } else { target.apply(payload, placement: placement, library: library) }
            if let path = payload.path { previous = URL(fileURLWithPath: path) }
        }
    }
}

struct SidebarDragScrollAttachment: NSViewRepresentable {
    let state: SidebarDragState
    func makeNSView(context: Context) -> Attachment { Attachment(state: state) }
    func updateNSView(_ nsView: Attachment, context: Context) { nsView.attach() }

    final class Attachment: NSView {
        weak var state: SidebarDragState?
        init(state: SidebarDragState) { self.state = state; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        func attach() {
            if let enclosingScrollView { state?.scrollView = enclosingScrollView }
            else if window != nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    state?.scrollView = enclosingScrollView
                }
            }
        }
    }
}
