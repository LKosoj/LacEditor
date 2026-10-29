import AppKit
import os
import SwiftUI
import WebKit

private let markdownPerformanceLog = OSLog(subsystem: "com.laceditor.LacEditor", category: "MarkdownPerformance")

actor MarkdownRenderActor {
    static let shared = MarkdownRenderActor()
    private let renderer: @Sendable (String, Bool, URL?, MarkdownSyntaxOptions) -> MarkdownRenderedPage

    init(renderer: @escaping @Sendable (String, Bool, URL?, MarkdownSyntaxOptions) -> MarkdownRenderedPage = {
        MarkdownRenderer.renderPage($0, darkMode: $1, renderEmoji: true, resolveLocalImages: true, documentURL: $2, prepareRemoteImages: true, syntax: $3, includeHeadingNumbers: true, includeListStyles: true, includeSourcePositions: true, isPreview: true, highlightCode: true)
    }) {
        self.renderer = renderer
    }

    func render(_ markdown: String, darkMode: Bool, documentURL: URL? = nil, syntax: MarkdownSyntaxOptions = .init(), coordinator: DocumentTaskCoordinator,
                generation: UInt) async -> MarkdownRenderedPage? {
        guard !Task.isCancelled, coordinator.isCurrent(generation, for: .preview) else { return nil }
        let signpost = OSSignpostID(log: markdownPerformanceLog)
        os_signpost(.begin, log: markdownPerformanceLog, name: "MarkdownRender", signpostID: signpost)
        let page = renderer(markdown, darkMode, documentURL, syntax)
        os_signpost(.end, log: markdownPerformanceLog, name: "MarkdownRender", signpostID: signpost)
        guard !Task.isCancelled, coordinator.isCurrent(generation, for: .preview) else { return nil }
        return page
    }
}

private struct MarkdownPreviewActiveKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var markdownPreviewActive: Bool {
        get { self[MarkdownPreviewActiveKey.self] }
        set { self[MarkdownPreviewActiveKey.self] = newValue }
    }
}

final class MarkdownWebView: WKWebView {
    var reloadRenderedContent: (() -> Void)?
    var mathGeometryChanged: (() -> Void)?
    var magnificationDidChange: ((CGFloat) -> Void)?
    private var pageDarkMode: Bool?
    var retryLoad: (() -> Void)?
    private lazy var statusOverlay: MarkdownPreviewStatusOverlay = {
        let overlay = MarkdownPreviewStatusOverlay()
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.retry = { [weak self] in self?.retryLoad?() }
        addSubview(overlay)
        return overlay
    }()
    private var loadingWork: DispatchWorkItem?
    var isShowingLoadError: Bool { statusOverlay.isErrorVisible }
    var isShowingLoadingIndicator: Bool { statusOverlay.isSpinnerVisible }

    func showLoadError(_ detail: String) {
        setLoading(false)
        statusOverlay.showError(detail)
    }

    func hideLoadError() { statusOverlay.hideError() }

    /// Индикатор появляется, только если страница не готова дольше 0,3 с.
    func setLoading(_ loading: Bool) {
        if loading {
            guard loadingWork == nil, !statusOverlay.isSpinnerVisible, !statusOverlay.isErrorVisible else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.loadingWork = nil
                self?.statusOverlay.setSpinner(true)
            }
            loadingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else {
            loadingWork?.cancel()
            loadingWork = nil
            statusOverlay.setSpinner(false)
        }
    }

    func configurePageAppearance(darkMode: Bool) {
        guard pageDarkMode != darkMode else { return }
        pageDarkMode = darkMode
        appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua)
        underPageBackgroundColor = NSColor(calibratedWhite: darkMode ? 0.105 : 251.0 / 255.0, alpha: 1)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { mathGeometryChanged?() }
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        let value = magnification
        DispatchQueue.main.async { [weak self] in
            guard let self, abs(self.magnification - value) < 0.0001 else { return }
            self.magnificationDidChange?(value)
        }
    }

    override func reload() -> WKNavigation? {
        reloadRenderedContent?()
        return nil
    }

    override func reloadFromOrigin() -> WKNavigation? {
        reloadRenderedContent?()
        return nil
    }
}

/// Сообщение об ошибке загрузки и индикатор загрузки поверх предпросмотра; без них события мыши проходят к странице.
private final class MarkdownPreviewStatusOverlay: NSView {
    var retry: (() -> Void)?
    private(set) var isErrorVisible = false
    private(set) var isSpinnerVisible = false
    private let backdrop = NSVisualEffectView()
    private let messageStack = NSStackView()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backdrop.material = .contentBackground
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.isHidden = true
        addSubview(backdrop)

        let title = NSTextField(labelWithString: L10n.tr("无法显示预览"))
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isSelectable = true
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 3
        let button = NSButton(title: L10n.tr("重试"), target: self, action: #selector(retryTapped))
        button.bezelStyle = .rounded
        button.keyEquivalent = ""
        messageStack.orientation = .vertical
        messageStack.spacing = 8
        messageStack.alignment = .centerX
        messageStack.translatesAutoresizingMaskIntoConstraints = false
        messageStack.isHidden = true
        for view in [title, detailLabel, button] { messageStack.addArrangedSubview(view) }
        addSubview(messageStack)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel(L10n.tr("正在加载预览"))
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            messageStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { isErrorVisible ? super.hitTest(point) : nil }

    func showError(_ detail: String) {
        setSpinner(false)
        detailLabel.stringValue = detail
        isErrorVisible = true
        backdrop.isHidden = false
        messageStack.isHidden = false
    }

    func hideError() {
        isErrorVisible = false
        backdrop.isHidden = true
        messageStack.isHidden = true
    }

    func setSpinner(_ visible: Bool) {
        guard isSpinnerVisible != visible else { return }
        isSpinnerVisible = visible
        if visible { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func retryTapped() { retry?() }
}

struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    let revision: UInt
    let darkMode: Bool
    var typography: MarkdownTypography? = nil
    var mathOptions = MathJaxRenderService.Options()
    var syntax = MarkdownSyntaxOptions()
    var viewMagnification: CGFloat = 1
    var magnificationDidChange: ((CGFloat) -> Void)? = nil
    @ObservedObject var document: EditorDocument
    @Environment(\.markdownPreviewActive) private var isActive

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        Self.configureLinkRouting(configuration, coordinator: context.coordinator)
        let view = MarkdownWebView(frame: .zero, configuration: configuration)
        view.allowsMagnification = true
        view.magnification = viewMagnification
        view.magnificationDidChange = magnificationDidChange
        view.navigationDelegate = context.coordinator
        // Native WebKit scrolling still underlaps the native titlebar (NT2).
        view.configurePageAppearance(darkMode: darkMode)
        view.setAccessibilityLabel(L10n.tr("Markdown 预览"))
        context.coordinator.webView = view
        // setActive ниже выходит рано, если состояние не изменилось, поэтому связь с редактором подключается явно.
        context.coordinator.attachScrollRelay()
        view.reloadRenderedContent = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.reloadLastRenderedHTML(in: view)
        }
        view.retryLoad = { [weak coordinator = context.coordinator] in coordinator?.retryLoadingPage() }
        context.coordinator.setActive(isActive)
        context.coordinator.setMathOptions(mathOptions)
        if isActive {
            context.coordinator.render(markdown: markdown, revision: revision, darkMode: darkMode, typography: typography, syntax: syntax, immediately: true)
        }
        return view
    }

    static func configureLinkRouting(_ configuration: WKWebViewConfiguration, coordinator: Coordinator) {
        let script = """
        document.addEventListener('click', function(event) {
          const element = event.target instanceof Element ? event.target.closest('a[href]') : null;
          if (!element || event.defaultPrevented || event.button !== 0) return;
          const href = element.getAttribute('href');
          if (!href || href.startsWith('#')) return;
          event.preventDefault();
          window.webkit.messageHandlers.lacLink.postMessage({href: href, domID: document.documentElement.dataset.mathDOMID});
        }, true);
        """
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "lacLink")
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        (nsView as? MarkdownWebView)?.configurePageAppearance(darkMode: darkMode)
        (nsView as? MarkdownWebView)?.magnificationDidChange = magnificationDidChange
        if abs(nsView.magnification - viewMagnification) > 0.0001 {
            nsView.setMagnification(viewMagnification, centeredAt: NSPoint(x: nsView.bounds.midX, y: nsView.bounds.midY))
        }
        context.coordinator.document = document
        context.coordinator.setActive(isActive)
        context.coordinator.setMathOptions(mathOptions)
        if isActive { context.coordinator.render(markdown: markdown, revision: revision, darkMode: darkMode, typography: typography, syntax: syntax) }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: NSColor.systemColorsDidChangeNotification, object: nil)
        coordinator.detachScrollRelay()
        coordinator.stop()
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "lacLink", contentWorld: .defaultClient)
        (nsView as? MarkdownWebView)?.reloadRenderedContent = nil
        (nsView as? MarkdownWebView)?.retryLoad = nil
        (nsView as? MarkdownWebView)?.setLoading(false)
        (nsView as? MarkdownWebView)?.magnificationDidChange = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView? {
            didSet {
                (oldValue as? MarkdownWebView)?.mathGeometryChanged = nil
                (webView as? MarkdownWebView)?.mathGeometryChanged = { [weak self] in
                    self?.refreshMathGeometry()
                    self?.refreshDiagramGeometry()
                }
            }
        }
        weak var document: EditorDocument? {
            didSet {
                guard oldValue !== document else { return }
                if let relay = oldValue?.previewScrollRelay, relay.positionHandlerOwner === self {
                    relay.positionHandler = nil
                }
                needsInitialEditorSync = true
                pendingEditorPosition = nil
                attachScrollRelay()
            }
        }
        private var pendingEditorPosition: MarkdownPreviewScrollRelay.Position?
        private var editorSyncInFlight = false
        private var needsInitialEditorSync = true
        private let imageSession: URLSession
        private var debounce: DispatchWorkItem?
        private var renderTask: Task<Void, Never>?
        private var taskGeneration: UInt?
        private var lastRequestedRevision: UInt?
        private var lastDarkMode: Bool?
        private var lastTypography: MarkdownTypography?
        private var lastSyntax = MarkdownSyntaxOptions()
        private var renderedSyntax: MarkdownSyntaxOptions?
        private var renderedRevision: UInt?
        private(set) var visibleRevision: UInt?
        private var visibleDocumentURL: URL?
        private var loadingRevision: UInt?
        private var loadingDocumentURL: URL?
        private var lastDocumentURL: URL?
        private var renderedDocumentURL: URL?
        private var page: MarkdownRenderedPage?
        private var visibleHeadingIDs: Set<String> = []
        private var loadingHeadingIDs: Set<String> = []
        private var generation = 0
        private var latestNavigation: WKNavigation?
        private var pageIsReady = false
        private var isActive = true
        private var pendingScrollRatio = 0.0
        private var pendingArticleScrollRatio = 0.0
        private var usesReloadFallback = false

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "lacLink", message.frameInfo.isMainFrame, let view = webView,
                  message.webView === view, view.window?.isKeyWindow == true, isActive, pageIsReady,
                  let document, document.language == .markdown, document.ioState == .idle,
                  let body = message.body as? [String: String], let address = body["href"],
                  let domID = body["domID"], domID == mathDOMID,
                  !address.isEmpty, !address.hasPrefix("#"),
                  let revision = renderedRevision, visibleRevision == revision, document.textRevision == revision,
                  lastRequestedRevision == revision, document.url == renderedDocumentURL, document.url == visibleDocumentURL,
                  !document.hasPendingLiveEdits else { return }
            let snapshot = document.synchronizedSnapshot()
            guard snapshot.revision == revision, !document.hasPendingLiveEdits else { return }
            let requestGeneration = generation, sourceURL = document.url
            let request = MarkdownLinkNavigationRequest(snapshot: snapshot, link: MarkdownLink(range: NSRange(location: 0, length: 0), url: address), headings: []) { [weak self, weak document, weak view] in
                guard let self, let document, let view else { return false }
                return self.webView === view && self.document === document && self.isActive && self.pageIsReady &&
                    self.generation == requestGeneration && self.mathDOMID == domID && self.renderedRevision == revision && self.visibleRevision == revision &&
                    document.url == sourceURL && document.textRevision == revision && !document.hasPendingLiveEdits
            }
            NotificationCenter.default.post(name: EditorCommandNotification.navigateMarkdownLink, object: request)
        }
        private var mathService: MathJaxRenderService?
        private var legacyService: LegacyDiagramRenderService?
        private var legacyToken: UUID?
        private var legacyWidth: CGFloat?
        private var legacyGeometryToken: UUID?
        private var mathGeneration: Int?
        private var mathToken: UUID?
        private var mathDOMID = UUID().uuidString
        private var mathWidth: CGFloat?
        private var mathFontSize: CGFloat?
        private var mathGeometryToken: UUID?
        private var mathOptions = MathJaxRenderService.Options()
        static let mermaidScript: String? = {
            #if SWIFT_PACKAGE
            let bundle = Bundle.module
            #else
            let bundle = Bundle.main
            #endif
            guard let libraryURL = bundle.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Mermaid"),
                  let clientURL = bundle.url(forResource: "render", withExtension: "js", subdirectory: "Mermaid"),
                  let library = try? String(contentsOf: libraryURL, encoding: .utf8),
                  let client = try? String(contentsOf: clientURL, encoding: .utf8) else { return nil }
            return library + "\n" + client + "\nvoid 0;"
        }()

        init(document: EditorDocument, imageSession: URLSession = .shared) {
            self.document = document
            self.imageSession = imageSession
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(accentDidChange), name: NSColor.systemColorsDidChangeNotification, object: nil)
        }

        // Системный акцент меняет только декор страницы: обновляем её без пересборки текста.
        @objc private func accentDidChange() {
            guard isActive, pageIsReady, page != nil else { return }
            patchPage(includingBody: false)
        }

        private static func systemAccentCSS(darkMode: Bool) -> String? {
            var result: MarkdownSRGBColor?
            NSAppearance(named: darkMode ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                result = MarkdownSRGBColor(NSColor.controlAccentColor)
            }
            return result?.css
        }

        deinit {
            debounce?.cancel()
            renderTask?.cancel()
        }

        func setActive(_ active: Bool) {
            guard isActive != active else { return }
            isActive = active
            if active {
                needsInitialEditorSync = true
                attachScrollRelay()
            } else {
                detachScrollRelay()
                pendingEditorPosition = nil
                stop()
                (webView as? MarkdownWebView)?.setLoading(false)
                (webView as? MarkdownWebView)?.hideLoadError()
            }
        }

        func attachScrollRelay() {
            guard isActive, let relay = document?.previewScrollRelay else { return }
            relay.positionHandler = { [weak self] position in self?.scrollToEditorPosition(position) }
            relay.positionHandlerOwner = self
        }

        func detachScrollRelay() {
            guard let relay = document?.previewScrollRelay, relay.positionHandlerOwner === self else { return }
            relay.positionHandler = nil
        }

        func scrollToEditorPosition(_ position: MarkdownPreviewScrollRelay.Position) {
            pendingEditorPosition = position
            flushEditorSync()
        }

        private func flushEditorSync() {
            // Пока страница обновляется (visibleRevision == nil), позиция ждёт: её применит конец patchPage.
            guard isActive, pageIsReady, visibleRevision != nil, !editorSyncInFlight,
                  let webView, let position = pendingEditorPosition else { return }
            pendingEditorPosition = nil
            editorSyncInFlight = true
            webView.callAsyncJavaScript(Self.scrollToLineScript,
                arguments: ["line": position.line, "atBottom": position.atBottom],
                in: nil, in: .defaultClient) { [weak self] _ in
                guard let self else { return }
                self.editorSyncInFlight = false
                self.flushEditorSync()
            }
        }

        func stop() {
            generation &+= 1
            cancelLegacyDiagrams()
            let previousMath = mathService
            mathService = nil
            mathGeneration = nil
            mathToken = nil
            mathWidth = nil
            mathFontSize = nil
            mathGeometryToken = nil
            previousMath?.cancel()
            if pageIsReady, let webView {
                webView.evaluateJavaScript("globalThis.lacMermaid?.invalidate(\(generation))",
                                           in: nil, in: .defaultClient, completionHandler: nil)
            }
            debounce?.cancel()
            debounce = nil
            if let taskGeneration, let document,
               document.taskCoordinator.isCurrent(taskGeneration, for: .preview) {
                document.taskCoordinator.cancel(.preview)
            }
            renderTask?.cancel()
            renderTask = nil
            taskGeneration = nil
            lastRequestedRevision = nil
        }

        func render(markdown: String, revision: UInt, darkMode: Bool, typography: MarkdownTypography? = nil, syntax: MarkdownSyntaxOptions = .init(), immediately: Bool = false) {
            guard isActive else { return }
            let sourceURL = document?.url
            if revision == lastRequestedRevision, darkMode == lastDarkMode, sourceURL == lastDocumentURL, syntax == lastSyntax {
                guard typography != lastTypography else { return }
                lastTypography = typography
                if renderedRevision == revision, var page {
                    page.typography = typography
                    self.page = page
                    if pageIsReady { patchPage(includingBody: false) }
                    else if latestNavigation == nil, let webView { loadPage(in: webView) }
                }
                return
            }
            stop()
            lastRequestedRevision = revision
            lastDarkMode = darkMode
            lastDocumentURL = sourceURL
            lastTypography = typography
            lastSyntax = syntax
            let requestedGeneration = generation
            if renderedRevision == revision, renderedDocumentURL == sourceURL, renderedSyntax == syntax, var page {
                page.darkMode = darkMode
                page.typography = typography
                self.page = page
                if pageIsReady { patchPage(includingBody: false) }
                else if latestNavigation == nil, let webView { loadPage(in: webView) }
                return
            }
            if page == nil, latestNavigation == nil { (webView as? MarkdownWebView)?.setLoading(true) }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isActive, requestedGeneration == self.generation else { return }
                self.beginRender(markdown: markdown, revision: revision, darkMode: darkMode, syntax: syntax,
                                 generation: requestedGeneration)
            }
            debounce = work
            if immediately { work.perform() }
            else {
                DispatchQueue.main.asyncAfter(deadline: .now() + (document?.isLargeFileMode == true ? 0.5 : 0.18),
                                              execute: work)
            }
        }

        private func beginRender(markdown: String, revision: UInt, darkMode: Bool, syntax: MarkdownSyntaxOptions, generation requestedGeneration: Int) {
            guard let document else { return }
            let sourceURL = document.url
            let imageSession = self.imageSession
            let coordinator = document.taskCoordinator
            let taskGeneration = coordinator.begin(.preview)
            self.taskGeneration = taskGeneration
            let task = Task.detached(priority: .userInitiated) { [weak self, weak document] in
                // Индикатор первого показа снимается, если результат не будет применён и новый render его не перехватил.
                @MainActor func clearLoading() {
                    guard let self, self.generation == requestedGeneration, self.latestNavigation == nil else { return }
                    (self.webView as? MarkdownWebView)?.setLoading(false)
                }
                guard !Task.isCancelled, coordinator.isCurrent(taskGeneration, for: .preview) else { await clearLoading(); return }
                guard var page = await MarkdownRenderActor.shared.render(
                    markdown, darkMode: darkMode, documentURL: sourceURL, syntax: syntax, coordinator: coordinator, generation: taskGeneration
                ) else { await clearLoading(); return }
                guard !Task.isCancelled, coordinator.isCurrent(taskGeneration, for: .preview) else { await clearLoading(); return }
                @MainActor func apply(_ page: MarkdownRenderedPage, finished: Bool) -> Bool {
                    guard !Task.isCancelled, let self, let document, self.document === document, document.url == sourceURL, self.isActive,
                          self.generation == requestedGeneration,
                          coordinator.isCurrent(taskGeneration, for: .preview),
                          let webView = self.webView else { return false }
                    if finished {
                        coordinator.finish(.preview, generation: taskGeneration)
                        self.renderTask = nil
                        self.taskGeneration = nil
                    }
                    var page = page
                    page.typography = self.lastTypography
                    self.page = page
                    self.renderedRevision = revision
                    self.renderedSyntax = syntax
                    self.renderedDocumentURL = sourceURL
                    if self.pageIsReady && !self.usesReloadFallback { self.patchPage(includingBody: true) }
                    else if self.latestNavigation == nil || (finished && self.usesReloadFallback) { self.loadPage(in: webView) }
                    return true
                }
                if !page.remoteImageMarkers.isEmpty || !page.localMediaMarkers.isEmpty {
                    var placeholder = page
                    try? placeholder.hideRemoteImages()
                    try? placeholder.prepareLocalMedia(load: false)
                    guard await apply(placeholder, finished: false) else { await clearLoading(); return }
                    try? await page.resolveRemoteImages(session: imageSession)
                    try? page.prepareLocalMedia(load: true)
                }
                guard !Task.isCancelled, coordinator.isCurrent(taskGeneration, for: .preview) else { await clearLoading(); return }
                if await !apply(page, finished: true) { await clearLoading() }
            }
            renderTask = task
            coordinator.attachTask(task, kind: .preview, generation: taskGeneration)
        }

        private func loadPage(in webView: WKWebView) {
            self.page?.previewAccent = Self.systemAccentCSS(darkMode: self.page?.darkMode ?? false)
            guard let page else { return }
            cancelLegacyDiagrams()
            let previousMath = mathService
            mathService = nil
            mathGeneration = nil
            mathToken = nil
            mathWidth = nil
            mathFontSize = nil
            mathGeometryToken = nil
            previousMath?.cancel()
            mathDOMID = UUID().uuidString
            pageIsReady = false
            visibleRevision = nil
            loadingRevision = renderedRevision
            loadingDocumentURL = renderedDocumentURL
            visibleHeadingIDs = []
            loadingHeadingIDs = page.headingIDs
            webView.stopLoading()
            latestNavigation = webView.loadHTMLString(page.html, baseURL: nil)
            (webView as? MarkdownWebView)?.setLoading(true)
        }

        private func patchPage(includingBody: Bool, restoringScroll: Bool = false) {
            self.page?.previewAccent = Self.systemAccentCSS(darkMode: self.page?.darkMode ?? false)
            guard let webView, let page, let renderedRevision, pageIsReady else { return }
            if includingBody {
                visibleRevision = nil
                cancelLegacyDiagrams()
                mathDOMID = UUID().uuidString
                visibleHeadingIDs = []
                let previousMath = mathService
                mathService = nil
                mathGeneration = nil
                mathToken = nil
                mathWidth = nil
                mathFontSize = nil
                mathGeometryToken = nil
                previousMath?.cancel()
            }
            let requestedGeneration = generation, requestedDOMID = mathDOMID, requestedURL = renderedDocumentURL
            let signpost = OSSignpostID(log: markdownPerformanceLog)
            os_signpost(.begin, log: markdownPerformanceLog, name: "MarkdownPageUpdate", signpostID: signpost)
            // Run only app-owned code in an isolated world. Page JavaScript
            // stays disabled; source content is passed as data, never as code.
            webView.callAsyncJavaScript(Self.updateScript,
                arguments: ["body": includingBody ? page.body as Any : NSNull(),
                            "dark": page.darkMode, "revision": String(renderedRevision),
                            "preserveWhitespace": page.preserveWhitespace,
                            "fontSize": page.typography.flatMap { $0.usesCustomFontMetrics ? $0.fontSize : nil } as Any? ?? NSNull(),
                            "lineHeight": page.typography.flatMap { $0.usesCustomFontMetrics ? $0.lineHeight : nil } as Any? ?? NSNull(),
                            "textFamily": page.typography.flatMap { $0.usesCustomFontMetrics ? $0.textFamily : nil } as Any? ?? NSNull(),
                            "codeFamily": page.typography.flatMap { $0.usesCustomFontMetrics ? $0.codeFamily : nil } as Any? ?? NSNull(),
                            "contentWidth": page.typography?.maximumWidth as Any? ?? NSNull(),
                            "ligatures": page.typography?.ligatureCSS as Any? ?? NSNull(),
                            "smallCapsCSS": page.typography?.smallCapsCSS ?? "",
                            "paragraphCSS": page.paragraphCSS,
                            "tocMaxLevel": page.typography?.tocMaxLevel ?? 6,
                            "colors": page.rootColorVariables,
                            "generation": requestedGeneration, "mathDOMID": requestedDOMID, "fallbackRatio": pendingScrollRatio,
                            "fallbackArticleRatio": pendingArticleScrollRatio,
                            "restore": restoringScroll,
                            "mermaidError": L10n.tr("无法显示 Mermaid 图表")],
                in: nil, in: .defaultClient) { [weak self, weak webView] result in
                os_signpost(.end, log: markdownPerformanceLog, name: "MarkdownPageUpdate", signpostID: signpost)
                guard let self, let webView, requestedGeneration == self.generation,
                      requestedDOMID == self.mathDOMID else { return }
                switch result {
                case let .success(value):
                    if includingBody {
                        self.visibleHeadingIDs = page.headingIDs
                        self.visibleRevision = renderedRevision
                        self.visibleDocumentURL = requestedURL
                    }
                    self.refreshMathGeometry()
                    self.refreshDiagramGeometry()
                    if let ratios = value as? [String: Double] {
                        if let ratio = ratios["window"], ratio.isFinite { self.pendingScrollRatio = min(1, max(0, ratio)) }
                        if let ratio = ratios["article"], ratio.isFinite { self.pendingArticleScrollRatio = min(1, max(-1, ratio)) }
                    }
                    // Позиция редактора применяется после собственного восстановления прокрутки страницы.
                    if self.needsInitialEditorSync, let position = self.document?.previewScrollRelay.positionProvider?() {
                        self.needsInitialEditorSync = false
                        self.pendingEditorPosition = position
                    }
                    self.flushEditorSync()
                case .failure:
                    // A web-process/navigation failure can invalidate the DOM.
                    // Recover with the latest completed page, never old HTML.
                    self.usesReloadFallback = true
                    self.loadPage(in: webView)
                }
            }
        }

        func setMathOptions(_ options: MathJaxRenderService.Options) {
            guard options != mathOptions else { return }
            mathOptions = options
            let previous = mathService
            mathService = nil
            mathToken = nil
            mathGeneration = nil
            mathGeometryToken = nil
            previous?.cancel()
            refreshMathGeometry()
        }

        private func cancelLegacyDiagrams() {
            let service = legacyService
            legacyService = nil
            legacyToken = nil
            legacyWidth = nil
            legacyGeometryToken = nil
            service?.cancel()
        }

        private func refreshDiagramGeometry() {
            guard isActive, pageIsReady, let page, !page.diagrams.isEmpty, let webView else { return }
            let requestedGeneration = generation, domID = mathDOMID, geometryToken = UUID()
            legacyGeometryToken = geometryToken
            webView.callAsyncJavaScript("return document.querySelector('article').clientWidth;", arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
                guard let self, self.isActive, self.pageIsReady, self.generation == requestedGeneration,
                      self.mathDOMID == domID, self.legacyGeometryToken == geometryToken,
                      case let .success(value) = result, let width = (value as? NSNumber)?.doubleValue,
                      width.isFinite, width > 0 else { return }
                if self.legacyWidth == CGFloat(width) { return }
                self.cancelLegacyDiagrams()
                self.legacyWidth = CGFloat(width)
                let token = UUID()
                self.legacyToken = token
                self.renderLegacyDiagram(at: 0, page: page, width: CGFloat(width), generation: requestedGeneration, domID: domID, token: token)
            }
        }

        private func renderLegacyDiagram(at index: Int, page: MarkdownRenderedPage, width: CGFloat, generation: Int, domID: String, token: UUID) {
            guard isActive, self.generation == generation, mathDOMID == domID, legacyToken == token,
                  page.diagrams.indices.contains(index), let webView else { return }
            let item = page.diagrams[index]
            let kind: LegacyDiagramRenderService.Kind = item.kind == .flow ? .flow : .sequence
            let service = LegacyDiagramRenderService(code: item.source, kind: kind, width: width) { [weak self, weak webView] result in
                guard let self, let webView, self.isActive, self.generation == generation,
                      self.mathDOMID == domID, self.legacyToken == token else { return }
                self.legacyService = nil
                var encoded: String?
                if case let .success(image) = result, let data = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
                    encoded = png.base64EncodedString()
                }
                let script = """
                    if (Number(document.documentElement.dataset.generation) !== generation || document.documentElement.dataset.mathDOMID !== domID) return;
                    if (document.querySelector('article')?.clientWidth !== width) return;
                    const target = document.querySelector(`[data-lac-diagram="${index}"]`);
                    if (!target) return;
                    if (png === null) {
                        const article = document.querySelector('article');
                        const maximum = Math.max(0, article.scrollWidth - article.clientWidth);
                        const ratio = maximum > 0 ? article.scrollLeft / maximum : 0;
                        target.textContent = source;
                        article.scrollLeft = ratio * Math.max(0, article.scrollWidth - article.clientWidth);
                        return;
                    }
                    const image = document.createElement('img');
                    image.alt = source;
                    image.src = 'data:image/png;base64,' + png;
                    image.style.maxWidth = '100%';
                    if (image.decode) await image.decode();
                    if (Number(document.documentElement.dataset.generation) !== generation || document.documentElement.dataset.mathDOMID !== domID || document.querySelector('article')?.clientWidth !== width) return;
                    const maximum = Math.max(0, document.documentElement.scrollHeight - innerHeight);
                    const ratio = maximum > 0 ? scrollY / maximum : 0;
                    const article = document.querySelector('article');
                    const articleMaximum = Math.max(0, article.scrollWidth - article.clientWidth);
                    const articleRatio = articleMaximum > 0 ? article.scrollLeft / articleMaximum : 0;
                    target.replaceChildren(image);
                    window.scrollTo(0, ratio * Math.max(0, document.documentElement.scrollHeight - innerHeight));
                    article.scrollLeft = articleRatio * Math.max(0, article.scrollWidth - article.clientWidth);
                    """
                webView.callAsyncJavaScript(script, arguments: ["generation": generation, "domID": domID, "index": index,
                    "source": item.source, "png": encoded as Any? ?? NSNull(), "width": Double(width)], in: nil, in: .defaultClient) { [weak self] _ in
                    self?.renderLegacyDiagram(at: index + 1, page: page, width: width, generation: generation, domID: domID, token: token)
                }
            }
            legacyService = service
            service.start()
        }

        private func refreshMathGeometry() {
            guard isActive, pageIsReady, let page, !page.formulas.isEmpty, let webView else { return }
            let requestedGeneration = generation, domID = mathDOMID, geometryToken = UUID()
            mathGeometryToken = geometryToken
            webView.callAsyncJavaScript("return [document.querySelector('article').clientWidth, parseFloat(getComputedStyle(document.body).fontSize)];",
                                        arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
                guard let self, self.isActive, self.pageIsReady, self.generation == requestedGeneration,
                      self.mathDOMID == domID, self.mathGeometryToken == geometryToken, case let .success(value) = result,
                      let dimensions = value as? [Double], dimensions.count == 2,
                      dimensions.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
                let width = CGFloat(dimensions[0]), fontSize = CGFloat(dimensions[1])
                if self.mathWidth != width || self.mathFontSize != fontSize {
                    let previous = self.mathService
                    self.mathService = nil
                    self.mathToken = nil
                    self.mathGeneration = nil
                    self.mathWidth = width
                    self.mathFontSize = fontSize
                    previous?.cancel()
                }
                self.renderMath(page, generation: requestedGeneration, width: width, fontSize: fontSize)
            }
        }

        private func renderMath(_ page: MarkdownRenderedPage, generation requestedGeneration: Int, width: CGFloat, fontSize: CGFloat) {
            guard isActive, pageIsReady, mathService == nil, mathGeneration != requestedGeneration,
                  !page.formulas.isEmpty, let webView else { return }
            let expressions = page.formulas.map { MathJaxRenderService.Expression(source: $0.source, display: $0.display) }
            let token = UUID(), domID = mathDOMID
            let service = MathJaxRenderService(expressions: expressions, outputIndices: Array(expressions.indices),
                                               width: width, dark: page.darkMode, fontSize: fontSize, options: mathOptions) { [weak self, weak webView] result in
                guard let self, let webView, self.isActive, self.generation == requestedGeneration,
                      self.mathToken == token else { return }
                let references = self.mathService?.references ?? [:]
                let mathML = self.mathService?.mathML ?? [:]
                self.mathService = nil
                self.mathToken = nil
                self.mathGeneration = requestedGeneration
                let images: [NSImage?]
                if case let .success(value) = result, value.count == expressions.count { images = value }
                else { images = Array(repeating: nil, count: expressions.count) }
                let payload: [Any] = images.map { image in
                    guard let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                          let png = bitmap.representation(using: .png, properties: [:]) else { return NSNull() }
                    return png.base64EncodedString()
                }
                let links: [[[String: Any]]] = expressions.indices.map { index in
                    (references[index] ?? []).compactMap { reference in
                        guard expressions.indices.contains(reference.targetIndex), reference.pixelSize.width > 0, reference.pixelSize.height > 0 else { return nil }
                        return ["target": reference.targetIndex, "label": expressions[reference.targetIndex].source,
                                "x": reference.rect.minX / reference.pixelSize.width, "y": reference.rect.minY / reference.pixelSize.height,
                                "w": reference.rect.width / reference.pixelSize.width, "h": reference.rect.height / reference.pixelSize.height]
                    }
                }
                let script = """
                    const root = document.documentElement;
                    if (Number(root.dataset.generation) !== generation || root.dataset.mathDOMID !== domID) return;
                    const article = document.querySelector('article');
                    if (!article || article.clientWidth !== width || parseFloat(getComputedStyle(document.body).fontSize) !== fontSize) return;
                    const namespace = 'http://www.w3.org/1998/Math/MathML';
                    const names = new Set(['math','mrow','mi','mn','mo','mtext','mspace','ms','mfrac','msqrt','mroot','mstyle','merror','mpadded','mphantom','mfenced','menclose','msub','msup','msubsup','munder','mover','munderover','mmultiscripts','mprescripts','none','mtable','mtr','mtd','mlabeledtr','semantics']);
                    const attributes = new Set(['display','mathvariant','displaystyle','scriptlevel','stretchy','symmetric','fence','separator','accent','accentunder','movablelimits','largeop','form','lspace','rspace','width','height','depth','rowspan','columnspan','rowalign','columnalign','linethickness']);
                    function safeMath(value) {
                        if (typeof value !== 'string') return null;
                        const parsed = new DOMParser().parseFromString(value, 'application/xml');
                        if (parsed.querySelector('parsererror') || parsed.documentElement.localName !== 'math') return null;
                        function copy(node) {
                            if (node.nodeType === Node.TEXT_NODE) return document.createTextNode(node.nodeValue);
                            if (node.nodeType !== Node.ELEMENT_NODE || node.namespaceURI !== namespace || !names.has(node.localName)) return null;
                            const result = document.createElementNS(namespace, node.localName);
                            for (const attribute of node.attributes) {
                                if (attributes.has(attribute.name) && /^[a-zA-Z0-9 .,%+\\-]+$/.test(attribute.value)) result.setAttribute(attribute.name, attribute.value);
                            }
                            for (const child of node.childNodes) {
                                const copied = copy(child);
                                if (!copied) return null;
                                result.appendChild(copied);
                            }
                            return result;
                        }
                        return copy(parsed.documentElement);
                    }
                    for (let i = 0; i < images.length; i++) {
                        const target = document.querySelector(`[data-lac-math="${i}"]`);
                        if (!target) continue;
                        if (images[i] === null) {
                            target.textContent = target.querySelector('img')?.alt ?? target.textContent;
                            continue;
                        }
                        const image = document.createElement('img');
                        image.alt = target.querySelector('img')?.alt ?? target.textContent;
                        image.src = 'data:image/png;base64,' + images[i];
                        const wrapper = document.createElement('span');
                        Object.assign(wrapper.style, {position:'relative', display:'inline-block', maxWidth:'100%', verticalAlign:'baseline'});
                        Object.assign(image.style, {display:'block', maxWidth:'100%'});
                        wrapper.appendChild(image);
                        const accessibleMath = safeMath(mathml[i]);
                        if (accessibleMath) {
                            const accessibilityContainer = document.createElement('span');
                            Object.assign(accessibilityContainer.style, {position:'absolute', width:'1px', height:'1px', overflow:'hidden', clipPath:'inset(50%)', whiteSpace:'nowrap'});
                            accessibilityContainer.appendChild(accessibleMath);
                            wrapper.appendChild(accessibilityContainer);
                        }
                        for (const link of links[i]) {
                            const button = document.createElement('button');
                            button.type = 'button';
                            button.setAttribute('aria-label', link.label);
                            Object.assign(button.style, {position:'absolute', left:`${link.x * 100}%`, top:`${link.y * 100}%`,
                                width:`${link.w * 100}%`, height:`${link.h * 100}%`, padding:'0', border:'0', background:'transparent', cursor:'pointer'});
                            button.addEventListener('click', event => {
                                event.preventDefault();
                                event.stopPropagation();
                                document.querySelector(`[data-lac-math="${link.target}"]`)?.scrollIntoView({block:'center'});
                            });
                            wrapper.appendChild(button);
                        }
                        const articleMaximum = Math.max(0, article.scrollWidth - article.clientWidth);
                        const articleRatio = articleMaximum > 0 ? article.scrollLeft / articleMaximum : 0;
                        target.replaceChildren(wrapper);
                        article.scrollLeft = articleRatio * Math.max(0, article.scrollWidth - article.clientWidth);
                    }
                    """
                let accessible: [Any] = expressions.indices.map { mathML[$0] as Any? ?? NSNull() }
                webView.callAsyncJavaScript(script, arguments: ["generation": requestedGeneration, "domID": domID, "width": width, "fontSize": fontSize, "images": payload, "links": links, "mathml": accessible],
                                            in: nil, in: .defaultClient, completionHandler: nil)
            }
            mathToken = token
            mathService = service
            service.start()
        }

        // Прокрутка всегда мгновенная (behavior: 'instant'), поэтому «уменьшение движения» учитывается само.
        private static let scrollToLineScript = """
            const root = document.documentElement;
            const article = document.querySelector('article');
            if (!article) return null;
            const maximum = Math.max(0, root.scrollHeight - window.innerHeight);
            let target = 0;
            if (atBottom) {
                target = maximum;
            } else if (line > 1) {
                let cache = globalThis.lacSourceLines;
                const anchor = article.firstElementChild;
                if (!cache || cache.anchor !== anchor || (anchor && !anchor.isConnected)) {
                    const items = [];
                    let last = 0;
                    for (const el of article.querySelectorAll('[data-sourcepos]')) {
                        if (el.closest('.footnotes')) continue;
                        const m = /^(\\d+):\\d+-(\\d+):\\d+$/.exec(el.getAttribute('data-sourcepos'));
                        if (!m) continue;
                        const start = Number(m[1]), end = Number(m[2]);
                        if (start < last) continue;
                        last = start;
                        items.push({el, start, end});
                    }
                    cache = globalThis.lacSourceLines = {anchor, items};
                }
                const items = cache.items;
                let low = 0, high = items.length;
                while (low < high) {
                    const mid = (low + high) >> 1;
                    if (items[mid].start <= line) low = mid + 1; else high = mid;
                }
                const previous = items[low - 1], next = items[low];
                const y = window.scrollY;
                if (previous) {
                    const rect = previous.el.getBoundingClientRect();
                    const top = rect.top + y;
                    if (line <= previous.end) {
                        target = top + (line - previous.start) / (previous.end - previous.start + 1) * rect.height;
                    } else if (next) {
                        const bottom = top + rect.height;
                        const nextTop = next.el.getBoundingClientRect().top + y;
                        target = bottom + (line - previous.end) / (next.start - previous.end) * (nextTop - bottom);
                    } else {
                        target = top + rect.height;
                    }
                }
            }
            window.scrollTo({top: Math.max(0, Math.min(maximum, target)), left: window.scrollX, behavior: 'instant'});
            return null;
            """

        private static let updateScript = """
            const root = document.documentElement;
            if (Number(root.dataset.generation || -1) > generation) return null;
            const article = document.querySelector('article');
            if (!article) throw new Error('Missing preview article');
            const maximum = Math.max(0, root.scrollHeight - window.innerHeight);
            const ratio = restore ? fallbackRatio : (maximum > 0 ? window.scrollY / maximum : fallbackRatio);
            const articleMaximum = Math.max(0, article.scrollWidth - article.clientWidth);
            const articleRatio = restore ? fallbackArticleRatio : (articleMaximum > 0 ? article.scrollLeft / articleMaximum : fallbackArticleRatio);
            const horizontal = Array.from(document.querySelectorAll('pre, .table-scroll'), el => el.scrollLeft);
            root.dataset.theme = dark ? 'dark' : 'light';
            document.body.style.fontSize = fontSize === null ? '' : `${fontSize}px`;
            document.body.style.lineHeight = lineHeight === null ? '' : `${lineHeight}px`;
            document.body.style.fontFamily = textFamily === null ? '' : CSS.escape(textFamily);
            document.body.style.fontVariantLigatures = ligatures === null ? '' : ligatures;
            document.getElementById('lac-heading-small-caps').textContent = smallCapsCSS;
            document.getElementById('lac-paragraph-settings').textContent = paragraphCSS;
            document.getElementById('lac-whitespace').textContent = preserveWhitespace ? 'article span[data-lac-whitespace]{white-space:break-spaces}' : '';
            if (codeFamily === null) document.body.style.removeProperty('--lac-code-font');
            else document.body.style.setProperty('--lac-code-font', CSS.escape(codeFamily));
            if (contentWidth === null) {
                document.body.style.removeProperty('--lac-content-width');
                document.body.style.removeProperty('--lac-print-width');
            } else {
                document.body.style.setProperty('--lac-content-width', `${contentWidth}px`);
                document.body.style.setProperty('--lac-print-width', `min(100%, ${contentWidth}px)`);
            }
            for (const key of ['--text', '--page', '--accent', '--code', '--quote', '--lac-accent']) {
                if (colors[key] === undefined) root.style.removeProperty(key);
                else root.style.setProperty(key, colors[key]);
            }
            if (body !== null) article.innerHTML = body;
            article.querySelectorAll('nav[data-lac-toc] li[data-level]').forEach(item => {
                item.hidden = Number(item.dataset.level) > tocMaxLevel;
            });
            root.dataset.generation = String(generation);
            root.dataset.mathDOMID = mathDOMID;
            root.dataset.revision = revision;
            if (globalThis.lacMermaid) {
                await globalThis.lacMermaid.render(generation, dark, mermaidError);
            } else {
                article.querySelectorAll('pre > code.language-mermaid').forEach(code => {
                    if (code.parentElement.nextElementSibling?.classList.contains('mermaid-diagram')) return;
                    const error = document.createElement('div');
                    error.className = 'mermaid-diagram';
                    error.setAttribute('role', 'alert');
                    error.textContent = mermaidError;
                    code.parentElement.after(error);
                });
            }
            if (Number(root.dataset.generation) !== generation) return null;
            Array.from(document.querySelectorAll('pre, .table-scroll')).forEach((el, index) => {
                el.scrollLeft = horizontal[index] || 0;
            });
            window.scrollTo(0, Math.max(0, Math.min(1, ratio)) * Math.max(0, root.scrollHeight - window.innerHeight));
            article.scrollLeft = Math.max(-1, Math.min(1, articleRatio)) * Math.max(0, article.scrollWidth - article.clientWidth);
            return {window: ratio, article: articleRatio};
            """

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === latestNavigation else { return }
            func finish() {
                guard navigation === self.latestNavigation else { return }
                self.latestNavigation = nil
                guard self.isActive else { return }
                self.pageIsReady = true
                (webView as? MarkdownWebView)?.hideLoadError()
                (webView as? MarkdownWebView)?.setLoading(false)
                self.visibleHeadingIDs = self.loadingHeadingIDs
                self.visibleRevision = self.loadingRevision
                self.visibleDocumentURL = self.loadingDocumentURL
                if self.usesReloadFallback {
                    webView.evaluateJavaScript("(() => { window.scrollTo(0, \(self.pendingScrollRatio) * Math.max(0, document.documentElement.scrollHeight - innerHeight)); const a = document.querySelector('article'); if (a) a.scrollLeft = \(self.pendingArticleScrollRatio) * Math.max(0, a.scrollWidth - a.clientWidth); })()",
                                               in: nil, in: .defaultClient, completionHandler: nil)
                }
                self.patchPage(includingBody: !self.usesReloadFallback, restoringScroll: true)
            }
            guard let script = Self.mermaidScript else { finish(); return }
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in finish() }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard navigation === latestNavigation else { return }
            latestNavigation = nil
            pageIsReady = false
            presentLoadFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard navigation === latestNavigation else { return }
            latestNavigation = nil
            pageIsReady = false
            presentLoadFailure(error)
        }

        func presentLoadFailure(_ error: Error) {
            guard let view = webView as? MarkdownWebView else { return }
            view.setLoading(false)
            let nsError = error as NSError
            guard isActive, !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
            view.showLoadError(error.localizedDescription)
        }

        func retryLoadingPage() {
            guard isActive, let webView, page != nil else { return }
            (webView as? MarkdownWebView)?.hideLoadError()
            usesReloadFallback = false
            loadPage(in: webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            latestNavigation = nil
            pageIsReady = false
            usesReloadFallback = false
            loadPage(in: webView)
        }

        func reloadLastRenderedHTML(in webView: WKWebView) {
            guard page != nil else { return }
            let requestedGeneration = generation
            webView.evaluateJavaScript("(() => { const a = document.querySelector('article'); return {window: window.scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight), article: a ? a.scrollLeft / Math.max(1, a.scrollWidth - a.clientWidth) : 0}; })()",
                                       in: nil, in: .defaultClient) { [weak self, weak webView] result in
                guard let self, let webView, requestedGeneration == self.generation else { return }
                if case let .success(value) = result, let ratios = value as? [String: Double] {
                    if let ratio = ratios["window"], ratio.isFinite { self.pendingScrollRatio = min(1, max(0, ratio)) }
                    if let ratio = ratios["article"], ratio.isFinite { self.pendingArticleScrollRatio = min(1, max(-1, ratio)) }
                }
                self.usesReloadFallback = false
                self.loadPage(in: webView)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .reload {
                decisionHandler(.cancel)
                reloadLastRenderedHTML(in: webView)
            } else if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, url.scheme == "about", url.path == "blank",
                   let fragment = url.fragment,
                   fragment.hasPrefix("fn-") || fragment.hasPrefix("fnref-") ||
                       visibleHeadingIDs.contains(fragment.removingPercentEncoding ?? fragment) {
                    decisionHandler(.allow)
                    return
                }
                if let url = navigationAction.request.url,
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
    }
}
