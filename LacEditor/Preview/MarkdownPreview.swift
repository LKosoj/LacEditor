import AppKit
import os
import SwiftUI
import WebKit

private let markdownPerformanceLog = OSLog(
    subsystem: "com.laceditor.LacEditor",
    category: "MarkdownPerformance"
)

private final class MarkdownWebView: WKWebView {
    var reloadRenderedContent: (() -> Void)?
    private var pageDarkMode: Bool?

    func configurePageAppearance(darkMode: Bool) {
        guard pageDarkMode != darkMode else { return }
        pageDarkMode = darkMode
        appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua)
        underPageBackgroundColor = NSColor(calibratedWhite: darkMode ? 0.105 : 251.0 / 255.0, alpha: 1)
        needsLayout = true
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
    /// The document revision is used for change detection so SwiftUI updates
    /// never need to concatenate or copy the complete Markdown source.
    let revision: UInt
    let darkMode: Bool
    @ObservedObject var document: EditorDocument

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = MarkdownWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        // WebKit owns its native top inset and scroll pocket. Do not disable
        // these without a replacement: page text would overlap toolbar items.
        view.configurePageAppearance(darkMode: darkMode)
        context.coordinator.webView = view
        context.coordinator.document = document
        view.reloadRenderedContent = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.reloadLastRenderedHTML(in: view)
        }
        context.coordinator.render(
            markdown: markdown,
            revision: revision,
            darkMode: darkMode,
            immediately: true
        )
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        (nsView as? MarkdownWebView)?.configurePageAppearance(darkMode: darkMode)
        context.coordinator.document = document
        context.coordinator.render(markdown: markdown, revision: revision, darkMode: darkMode)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        weak var document: EditorDocument?
        private var workItem: DispatchWorkItem?
        private var renderTask: Task<Void, Never>?
        private var lastRevision: UInt?
        private var lastDarkMode: Bool?
        private var lastRenderedHTML = ""
        private var generation = 0
        private var loadGeneration = 0
        private var latestNavigation: WKNavigation?
        private var pendingScrollRatio: CGFloat = 0

        init(document: EditorDocument) {
            self.document = document
        }

        deinit {
            workItem?.cancel()
            renderTask?.cancel()
        }

        func render(
            markdown: String,
            revision: UInt,
            darkMode: Bool,
            immediately: Bool = false
        ) {
            guard revision != lastRevision || darkMode != lastDarkMode else { return }
            lastRevision = revision
            lastDarkMode = darkMode
            workItem?.cancel()
            generation += 1
            let requestedGeneration = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, requestedGeneration == generation else { return }
                beginRender(
                    markdown: markdown,
                    darkMode: darkMode,
                    generation: requestedGeneration
                )
            }
            workItem = work
            if immediately {
                work.perform()
            } else {
                let delay = document?.isLargeFileMode == true ? 0.5 : 0.18
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }

        private func beginRender(
            markdown: String,
            darkMode: Bool,
            generation requestedGeneration: Int
        ) {
            guard let document else { return }
            renderTask?.cancel()
            var task: Task<Void, Never>?
            let taskGeneration = document.taskCoordinator.beginTask(.preview) {
                task?.cancel()
            }
            let taskCoordinator = document.taskCoordinator
            task = Task.detached(priority: .userInitiated) { [weak self, weak document] in
                guard let self, !Task.isCancelled else { return }
                let signpostID = OSSignpostID(log: markdownPerformanceLog)
                os_signpost(
                    .begin,
                    log: markdownPerformanceLog,
                    name: "MarkdownRender",
                    signpostID: signpostID
                )
                let html = MarkdownRenderer.render(markdown, darkMode: darkMode)
                os_signpost(
                    .end,
                    log: markdownPerformanceLog,
                    name: "MarkdownRender",
                    signpostID: signpostID
                )
                guard !Task.isCancelled,
                      taskCoordinator.isCurrent(taskGeneration, for: .preview) else { return }
                await MainActor.run { [weak self, weak document] in
                    guard let self, let document,
                          !Task.isCancelled,
                          requestedGeneration == generation,
                          document.taskCoordinator.isCurrent(taskGeneration, for: .preview),
                          let webView else { return }
                    document.taskCoordinator.finish(.preview, generation: taskGeneration)
                    lastRenderedHTML = html
                    loadPreservingScroll(html, in: webView)
                }
            }
            renderTask = task
        }

        private func loadPreservingScroll(_ html: String, in webView: WKWebView) {
            loadGeneration += 1
            let requestedLoad = loadGeneration
            let requestedRender = generation
            // WebKit's native scroll-view bounds need not track the page's
            // compositor scroll position. Query the page only when reloading.
            webView.evaluateJavaScript("window.scrollY / Math.max(1, document.documentElement.scrollHeight - window.innerHeight)") { [weak self, weak webView] value, _ in
                guard let self, let webView,
                      requestedLoad == self.loadGeneration,
                      requestedRender == self.generation else { return }
                if let number = value as? NSNumber, number.doubleValue.isFinite {
                    self.pendingScrollRatio = min(1, max(0, number.doubleValue))
                }
                webView.stopLoading()
                self.latestNavigation = webView.loadHTMLString(html, baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === latestNavigation else { return }
            let ratio = pendingScrollRatio
            let requestedLoad = loadGeneration
            guard requestedLoad == loadGeneration else { return }
            webView.evaluateJavaScript("window.scrollTo(0, \(ratio) * Math.max(0, document.documentElement.scrollHeight - window.innerHeight))", completionHandler: nil)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            reloadLastRenderedHTML(in: webView)
        }

        fileprivate func reloadLastRenderedHTML(in webView: WKWebView) {
            guard !lastRenderedHTML.isEmpty else { return }
            loadPreservingScroll(lastRenderedHTML, in: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .reload {
                decisionHandler(.cancel)
                DispatchQueue.main.async { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.reloadLastRenderedHTML(in: webView)
                }
            } else if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url,
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
