import AppKit
import os
import SwiftUI
import WebKit

private let markdownPerformanceLog = OSLog(subsystem: "com.laceditor.LacEditor", category: "MarkdownPerformance")

actor MarkdownRenderActor {
    static let shared = MarkdownRenderActor()
    private let renderer: @Sendable (String, Bool) -> MarkdownRenderedPage

    init(renderer: @escaping @Sendable (String, Bool) -> MarkdownRenderedPage = {
        MarkdownRenderer.renderPage($0, darkMode: $1)
    }) {
        self.renderer = renderer
    }

    func render(_ markdown: String, darkMode: Bool, coordinator: DocumentTaskCoordinator,
                generation: UInt) -> MarkdownRenderedPage? {
        guard !Task.isCancelled, coordinator.isCurrent(generation, for: .preview) else { return nil }
        let signpost = OSSignpostID(log: markdownPerformanceLog)
        os_signpost(.begin, log: markdownPerformanceLog, name: "MarkdownRender", signpostID: signpost)
        let page = renderer(markdown, darkMode)
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
    private var pageDarkMode: Bool?

    func configurePageAppearance(darkMode: Bool) {
        guard pageDarkMode != darkMode else { return }
        pageDarkMode = darkMode
        appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua)
        underPageBackgroundColor = NSColor(calibratedWhite: darkMode ? 0.105 : 251.0 / 255.0, alpha: 1)
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

struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    let revision: UInt
    let darkMode: Bool
    @ObservedObject var document: EditorDocument
    @Environment(\.markdownPreviewActive) private var isActive

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = MarkdownWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        // Native WebKit scrolling still underlaps the native titlebar (NT2).
        view.configurePageAppearance(darkMode: darkMode)
        view.setAccessibilityLabel(L10n.tr("Markdown 预览"))
        context.coordinator.webView = view
        view.reloadRenderedContent = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.reloadLastRenderedHTML(in: view)
        }
        context.coordinator.setActive(isActive)
        if isActive {
            context.coordinator.render(markdown: markdown, revision: revision, darkMode: darkMode, immediately: true)
        }
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        (nsView as? MarkdownWebView)?.configurePageAppearance(darkMode: darkMode)
        context.coordinator.document = document
        context.coordinator.setActive(isActive)
        if isActive { context.coordinator.render(markdown: markdown, revision: revision, darkMode: darkMode) }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        (nsView as? MarkdownWebView)?.reloadRenderedContent = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        weak var document: EditorDocument?
        private var debounce: DispatchWorkItem?
        private var renderTask: Task<Void, Never>?
        private var taskGeneration: UInt?
        private var lastRequestedRevision: UInt?
        private var lastDarkMode: Bool?
        private var renderedRevision: UInt?
        private var page: MarkdownRenderedPage?
        private var generation = 0
        private var latestNavigation: WKNavigation?
        private var pageIsReady = false
        private var isActive = true
        private var pendingScrollRatio = 0.0
        private var usesReloadFallback = false

        init(document: EditorDocument) { self.document = document }

        deinit {
            debounce?.cancel()
            renderTask?.cancel()
        }

        func setActive(_ active: Bool) {
            guard isActive != active else { return }
            isActive = active
            if !active { stop() }
        }

        func stop() {
            generation &+= 1
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

        func render(markdown: String, revision: UInt, darkMode: Bool, immediately: Bool = false) {
            guard isActive,
                  revision != lastRequestedRevision || darkMode != lastDarkMode else { return }
            stop()
            lastRequestedRevision = revision
            lastDarkMode = darkMode
            let requestedGeneration = generation
            if renderedRevision == revision, var page {
                page.darkMode = darkMode
                self.page = page
                if pageIsReady { patchPage(includingBody: false) }
                else if latestNavigation == nil, let webView { loadPage(in: webView) }
                return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isActive, requestedGeneration == self.generation else { return }
                self.beginRender(markdown: markdown, revision: revision, darkMode: darkMode,
                                 generation: requestedGeneration)
            }
            debounce = work
            if immediately { work.perform() }
            else {
                DispatchQueue.main.asyncAfter(deadline: .now() + (document?.isLargeFileMode == true ? 0.5 : 0.18),
                                              execute: work)
            }
        }

        private func beginRender(markdown: String, revision: UInt, darkMode: Bool, generation requestedGeneration: Int) {
            guard let document else { return }
            let coordinator = document.taskCoordinator
            let taskGeneration = coordinator.begin(.preview)
            self.taskGeneration = taskGeneration
            let task = Task.detached(priority: .userInitiated) { [weak self, weak document] in
                guard !Task.isCancelled, coordinator.isCurrent(taskGeneration, for: .preview) else { return }
                guard let page = await MarkdownRenderActor.shared.render(
                    markdown, darkMode: darkMode, coordinator: coordinator, generation: taskGeneration
                ) else { return }
                guard !Task.isCancelled, coordinator.isCurrent(taskGeneration, for: .preview) else { return }
                await MainActor.run { [weak self, weak document] in
                    guard !Task.isCancelled, let self, let document, self.document === document, self.isActive,
                          self.generation == requestedGeneration,
                          coordinator.isCurrent(taskGeneration, for: .preview),
                          let webView = self.webView else { return }
                    coordinator.finish(.preview, generation: taskGeneration)
                    self.renderTask = nil
                    self.taskGeneration = nil
                    self.page = page
                    self.renderedRevision = revision
                    if self.pageIsReady && !self.usesReloadFallback { self.patchPage(includingBody: true) }
                    else if self.latestNavigation == nil { self.loadPage(in: webView) }
                }
            }
            renderTask = task
            coordinator.attachTask(task, kind: .preview, generation: taskGeneration)
        }

        private func loadPage(in webView: WKWebView) {
            guard let page else { return }
            pageIsReady = false
            webView.stopLoading()
            latestNavigation = webView.loadHTMLString(page.html, baseURL: nil)
        }

        private func patchPage(includingBody: Bool, restoringScroll: Bool = false) {
            guard let webView, let page, let renderedRevision, pageIsReady else { return }
            let requestedGeneration = generation
            let signpost = OSSignpostID(log: markdownPerformanceLog)
            os_signpost(.begin, log: markdownPerformanceLog, name: "MarkdownPageUpdate", signpostID: signpost)
            // Run only app-owned code in an isolated world. Page JavaScript
            // stays disabled; source content is passed as data, never as code.
            webView.callAsyncJavaScript(Self.updateScript,
                arguments: ["body": includingBody ? page.body as Any : NSNull(),
                            "dark": page.darkMode, "revision": String(renderedRevision),
                            "generation": requestedGeneration, "fallbackRatio": pendingScrollRatio,
                            "restore": restoringScroll],
                in: nil, in: .defaultClient) { [weak self, weak webView] result in
                os_signpost(.end, log: markdownPerformanceLog, name: "MarkdownPageUpdate", signpostID: signpost)
                guard let self, let webView, requestedGeneration == self.generation else { return }
                switch result {
                case let .success(value):
                    if let ratio = value as? Double, ratio.isFinite {
                        self.pendingScrollRatio = min(1, max(0, ratio))
                    }
                case .failure:
                    // A web-process/navigation failure can invalidate the DOM.
                    // Recover with the latest completed page, never old HTML.
                    self.usesReloadFallback = true
                    self.loadPage(in: webView)
                }
            }
        }

        private static let updateScript = """
            const root = document.documentElement;
            if (Number(root.dataset.generation || -1) > generation) return null;
            const article = document.querySelector('article');
            if (!article) throw new Error('Missing preview article');
            const maximum = Math.max(0, root.scrollHeight - window.innerHeight);
            const ratio = restore ? fallbackRatio : (maximum > 0 ? window.scrollY / maximum : fallbackRatio);
            const horizontal = Array.from(document.querySelectorAll('pre, .table-scroll'), el => el.scrollLeft);
            root.dataset.theme = dark ? 'dark' : 'light';
            if (body !== null) article.innerHTML = body;
            root.dataset.generation = String(generation);
            root.dataset.revision = revision;
            Array.from(document.querySelectorAll('pre, .table-scroll')).forEach((el, index) => {
                el.scrollLeft = horizontal[index] || 0;
            });
            window.scrollTo(0, Math.max(0, Math.min(1, ratio)) * Math.max(0, root.scrollHeight - window.innerHeight));
            return ratio;
            """

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === latestNavigation else { return }
            latestNavigation = nil
            pageIsReady = true
            if usesReloadFallback {
                webView.evaluateJavaScript("window.scrollTo(0, \(pendingScrollRatio) * Math.max(0, document.documentElement.scrollHeight - innerHeight))",
                                           in: nil, in: .defaultClient, completionHandler: nil)
            } else {
                patchPage(includingBody: true, restoringScroll: true)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard navigation === latestNavigation else { return }
            latestNavigation = nil
            pageIsReady = false
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
            webView.evaluateJavaScript("window.scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight)",
                                       in: nil, in: .defaultClient) { [weak self, weak webView] result in
                guard let self, let webView, requestedGeneration == self.generation else { return }
                if case let .success(value) = result, let ratio = value as? Double, ratio.isFinite {
                    self.pendingScrollRatio = min(1, max(0, ratio))
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
                if let url = navigationAction.request.url,
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
    }
}
