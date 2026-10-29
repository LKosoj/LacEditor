import AppKit
import WebKit

/// Renders one Mermaid source into a native image. The owner retains the service
/// until completion and cancels it when the requesting block becomes stale.
@MainActor
final class MermaidRenderService: NSObject, WKNavigationDelegate {
    enum RenderError: Error { case cancelled, unavailable, rendering, image }

    private let code: String
    private let width: CGFloat
    private let dark: Bool
    private var completion: ((Result<NSImage, Error>) -> Void)?
    private var webView: WKWebView?
    private var navigation: WKNavigation?
    private(set) var renderedSVG: Data?

    init(code: String, width: CGFloat, dark: Bool, completion: @escaping (Result<NSImage, Error>) -> Void) {
        self.code = code
        self.width = width
        self.dark = dark
        self.completion = completion
    }

    func start() {
        guard completion != nil, webView == nil else { return }
        guard width.isFinite, width > 0, MarkdownPreview.Coordinator.mermaidScript != nil else {
            finish(.failure(RenderError.unavailable))
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: ceil(width), height: 1), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        let page = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
            <style>html,body { margin:0; padding:0 } pre[hidden] { display:none }
            .mermaid-diagram svg { max-width:100%; height:auto; display:block }</style>
            </head><body><article><pre><code class="language-mermaid"></code></pre></article></body></html>
            """
        navigation = view.loadHTMLString(page, baseURL: nil)
        if navigation == nil { finish(.failure(RenderError.rendering)); return }
    }

    func cancel() {
        webView?.stopLoading()
        finish(.failure(RenderError.cancelled))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation, completion != nil else { return }
        self.navigation = nil
        guard let script = MarkdownPreview.Coordinator.mermaidScript else { finish(.failure(RenderError.unavailable)); return }
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self, weak webView] result in
            guard let self, let webView, self.completion != nil else { return }
            guard case .success = result else { self.finish(.failure(RenderError.rendering)); return }
            self.render(in: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === self.navigation else { return }
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === self.navigation else { return }
        finish(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(RenderError.rendering))
    }

    private func render(in webView: WKWebView) {
        let script = """
            document.querySelector('code').textContent = source;
            await globalThis.lacMermaid.render(1, dark, 'Mermaid error');
            if (document.querySelector('.mermaid-diagram[role="alert"]')) throw new Error('Mermaid failed');
            if (document.fonts) await document.fonts.ready;
            const svg = document.querySelector('.mermaid-diagram svg');
            if (!svg) throw new Error('Missing diagram');
            const rect = svg.getBoundingClientRect();
            const copy = svg.cloneNode(true);
            copy.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
            copy.setAttribute('width', String(rect.width));
            copy.setAttribute('height', String(rect.height));
            return [rect.right, rect.bottom, new XMLSerializer().serializeToString(copy)];
            """
        webView.callAsyncJavaScript(script, arguments: ["source": code, "dark": dark], in: nil, in: .defaultClient) { [weak self, weak webView] result in
            guard let self, let webView, self.completion != nil else { return }
            guard case let .success(value) = result, let values = value as? [Any], values.count == 3,
                  let rightValue = values[0] as? NSNumber, let bottomValue = values[1] as? NSNumber,
                  let svg = values[2] as? String else {
                self.finish(.failure(RenderError.rendering)); return
            }
            let right = rightValue.doubleValue, bottom = bottomValue.doubleValue
            guard right.isFinite, bottom.isFinite, right > 0, bottom > 0,
                  right <= Double(webView.bounds.width) else { self.finish(.failure(RenderError.image)); return }
            self.renderedSVG = svg.data(using: .utf8)
            webView.setFrameSize(NSSize(width: webView.bounds.width, height: ceil(bottom)))
            self.snapshot(in: webView)
        }
    }

    private func snapshot(in webView: WKWebView) {
        let measurement = "(() => { const r = document.querySelector('.mermaid-diagram svg').getBoundingClientRect(); return [r.right, r.bottom]; })()"
        webView.evaluateJavaScript(measurement) { [weak self, weak webView] value, error in
            guard let self, let webView, self.completion != nil else { return }
            guard error == nil, let dimensions = value as? [NSNumber], dimensions.count == 2,
                  dimensions[0].doubleValue.isFinite, dimensions[1].doubleValue.isFinite,
                  dimensions[0].doubleValue > 0, dimensions[1].doubleValue > 0,
                  dimensions[0].doubleValue <= Double(webView.bounds.width),
                  dimensions[1].doubleValue <= Double(webView.bounds.height) else {
                self.finish(.failure(RenderError.image)); return
            }
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            webView.takeSnapshot(with: config) { [weak self, weak webView] image, error in
                guard let self, let webView, self.completion != nil else { return }
                guard error == nil, let image, image.size == webView.bounds.size,
                      let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      Double(bitmap.pixelsWide) >= Double(webView.bounds.width),
                      Double(bitmap.pixelsHigh) >= Double(webView.bounds.height),
                      abs(Double(bitmap.pixelsHigh) - Double(bitmap.pixelsWide) * Double(webView.bounds.height) / Double(webView.bounds.width)) <= 1 else {
                    self.finish(.failure(RenderError.image)); return
                }
                self.finish(.success(image))
            }
        }
    }

    private func finish(_ result: Result<NSImage, Error>) {
        guard let completion else { return }
        self.completion = nil
        webView?.navigationDelegate = nil
        webView = nil
        navigation = nil
        completion(result)
    }
}
