import AppKit
import WebKit

/// Renders one flow or sequence diagram in a local, isolated WebKit page.
@MainActor
final class LegacyDiagramRenderService: NSObject, WKNavigationDelegate {
    enum Kind { case flow, sequence }
    enum Theme: String { case simple, hand }
    enum RenderError: Error { case cancelled, unavailable, rendering, image }

    private let code: String
    private let kind: Kind
    private let theme: Theme
    private let width: CGFloat
    private var completion: ((Result<NSImage, Error>) -> Void)?
    private var webView: WKWebView?
    private var navigation: WKNavigation?
    private var hostURL: URL?
    private(set) var renderedSVG: Data?

    init(code: String, kind: Kind, theme: Theme = .simple, width: CGFloat,
         completion: @escaping (Result<NSImage, Error>) -> Void) {
        self.code = code
        self.kind = kind
        self.theme = theme
        self.width = width
        self.completion = completion
    }

    func start() {
        guard completion != nil, webView == nil else { return }
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard width.isFinite, width > 0,
              let host = bundle.url(forResource: "host", withExtension: "html", subdirectory: "LegacyDiagrams") else {
            finish(.failure(RenderError.unavailable)); return
        }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: ceil(width), height: 1))
        view.navigationDelegate = self
        webView = view
        hostURL = host
        navigation = view.loadFileURL(host, allowingReadAccessTo: host.deletingLastPathComponent())
        if navigation == nil { finish(.failure(RenderError.rendering)) }
    }

    func cancel() {
        webView?.stopLoading()
        finish(.failure(RenderError.cancelled))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url == hostURL ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation, completion != nil else { return }
        self.navigation = nil
        let script = """
            const dimensions = await window.renderDiagram(source, kind, theme, width);
            const svg = document.querySelector('#diagram svg');
            if (!svg) throw new Error('Missing diagram');
            const copy = svg.cloneNode(true);
            copy.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
            if (theme === 'hand' && font) {
                const style = document.createElementNS('http://www.w3.org/2000/svg', 'style');
                style.textContent = "@font-face{font-family:danielbd;src:url(data:font/ttf;base64," + font + ") format('truetype')}";
                copy.prepend(style);
            }
            return [dimensions[0], dimensions[1], theme === 'hand' && !font ? null : new XMLSerializer().serializeToString(copy)];
            """
        let fontURL = hostURL?.deletingLastPathComponent().appendingPathComponent("danielbd-original.ttf")
        let font = theme == .hand ? fontURL.flatMap { try? Data(contentsOf: $0).base64EncodedString() } ?? "" : ""
        webView.callAsyncJavaScript(script, arguments: ["source": code, "kind": kind == .flow ? "flow" : "sequence",
                                                        "theme": theme.rawValue, "width": Double(width), "font": font], in: nil, in: .page) { [weak self, weak webView] result in
            guard let self, let webView, self.completion != nil else { return }
            guard case let .success(value) = result, let values = value as? [Any], values.count == 3,
                  let rightValue = values[0] as? NSNumber, let bottomValue = values[1] as? NSNumber else {
                self.finish(.failure(RenderError.rendering)); return
            }
            let right = rightValue.doubleValue, bottom = bottomValue.doubleValue
            guard right.isFinite, bottom.isFinite, right > 0, bottom > 0, right <= Double(webView.bounds.width) else {
                self.finish(.failure(RenderError.image)); return
            }
            self.renderedSVG = (values[2] as? String)?.data(using: .utf8)
            webView.setFrameSize(NSSize(width: webView.bounds.width, height: ceil(bottom)))
            self.snapshot(in: webView)
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

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(RenderError.rendering)) }

    private func snapshot(in webView: WKWebView) {
        let measurement = "(() => { const r = document.querySelector('#diagram svg').getBoundingClientRect(); return [r.right, r.bottom]; })()"
        webView.evaluateJavaScript(measurement) { [weak self, weak webView] value, error in
            guard let self, let webView, self.completion != nil else { return }
            guard error == nil, let dimensions = value as? [NSNumber], dimensions.count == 2,
                  dimensions[0].doubleValue.isFinite, dimensions[1].doubleValue.isFinite,
                  dimensions[0].doubleValue > 0, dimensions[1].doubleValue > 0,
                  dimensions[0].doubleValue <= Double(webView.bounds.width),
                  dimensions[1].doubleValue <= Double(webView.bounds.height) else { self.finish(.failure(RenderError.image)); return }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            webView.takeSnapshot(with: configuration) { [weak self, weak webView] image, error in
                guard let self, let webView, self.completion != nil else { return }
                guard error == nil, let image, image.size == webView.bounds.size,
                      let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
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
        hostURL = nil
        completion(result)
    }
}
