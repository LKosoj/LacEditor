import AppKit
import WebKit

/// Renders selected expressions from one document in an isolated MathJax page.
@MainActor
final class MathJaxRenderService: NSObject, WKNavigationDelegate {
    enum RenderError: Error { case cancelled, unavailable, rendering }
    struct Options: Equatable {
        var physics = true
        var numbering: MarkdownMathNumbering = .none
    }

    struct Expression {
        let source: String
        let display: Bool
    }

    struct Reference {
        let targetIndex: Int
        let rect: CGRect
        let pixelSize: CGSize
        let latex: String?
    }

    private let expressions: [Expression]
    private var outputIndices: [Int]
    private let retainForRequests: Bool
    private var ready = false
    private let width: CGFloat
    private let fontSize: CGFloat
    private let dark: Bool
    private let options: Options
    private var completion: ((Result<[NSImage?], Error>) -> Void)?
    private var webView: WKWebView?
    private var navigation: WKNavigation?
    private(set) var references: [Int: [Reference]] = [:]
    private(set) var mathML: [Int: String] = [:]

    convenience init(source: String, display: Bool, width: CGFloat, dark: Bool, fontSize: CGFloat = 16, options: Options = Options(), completion: @escaping (Result<NSImage, Error>) -> Void) {
        self.init(expressions: [Expression(source: source, display: display)], outputIndices: [0], width: width, dark: dark, fontSize: fontSize, options: options) { result in
            switch result {
            case let .success(images):
                if let image = images.first ?? nil { completion(.success(image)) }
                else { completion(.failure(RenderError.rendering)) }
            case let .failure(error): completion(.failure(error))
            }
        }
    }

    init(expressions: [Expression], outputIndices: [Int], width: CGFloat, dark: Bool,
         fontSize: CGFloat = 16, options: Options = Options(), retainForRequests: Bool = false, completion: @escaping (Result<[NSImage?], Error>) -> Void) {
        self.retainForRequests = retainForRequests
        self.expressions = expressions
        self.outputIndices = outputIndices
        self.width = width
        self.fontSize = fontSize
        self.dark = dark
        self.options = options
        self.completion = completion
    }

    func start() {
        guard completion != nil, webView == nil else { return }
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard width.isFinite, width > 0, fontSize.isFinite, fontSize > 0, !expressions.isEmpty, !outputIndices.isEmpty,
              outputIndices.allSatisfy({ expressions.indices.contains($0) }),
              let host = bundle.url(forResource: "host", withExtension: "html", subdirectory: "MathJax") else {
            finish(.failure(RenderError.unavailable)); return
        }
        let configuration = WKWebViewConfiguration()
        let script = "window.lacMathOptions = { physics: \(options.physics), tags: '\(options.numbering.rawValue)' };"
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: ceil(width), height: 1), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        navigation = view.loadFileURL(host, allowingReadAccessTo: host.deletingLastPathComponent())
        if navigation == nil { finish(.failure(RenderError.rendering)) }
    }

    func cancel() {
        webView?.stopLoading()
        if completion != nil { finish(.failure(RenderError.cancelled)) }
        else { close() }
    }

    func requestImages(_ indices: [Int], completion: @escaping (Result<[NSImage?], Error>) -> Void) {
        guard ready, self.completion == nil, let webView, !indices.isEmpty,
              indices.allSatisfy({ expressions.indices.contains($0) }) else {
            completion(.failure(RenderError.unavailable)); return
        }
        self.completion = completion
        outputIndices = indices
        let script = """
            const images = [];
            for (const index of outputIndices) {
                try { images.push(await window.lacMathRasterize(window.lacMathWrappers[index])); }
                catch (_) { images.push(null); }
            }
            return images;
            """
        webView.callAsyncJavaScript(script, arguments: ["outputIndices": indices], in: nil, in: .page) { [weak self] result in
            self?.receive(result)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation, completion != nil else { return }
        self.navigation = nil
        let script = """
            await MathJax.startup.promise;
            const container = document.getElementById('math');
            container.style.width = `${width}px`;
            container.style.fontSize = `${fontSize}px`;
            let marker = 'LACMATH' + nonce.replaceAll('-', '');
            while (expressions.some(item => item.source.includes(marker))) marker += 'X';
            const finder = MathJax.startup.document.inputJax.tex.findTeX;
            finder.options.inlineMath = [[marker + 'I', marker + 'J']];
            finder.options.displayMath = [[marker + 'D', marker + 'E']];
            finder.options.processEnvironments = false;
            finder.options.processRefs = false;
            finder.getPatterns();
            const wrappers = expressions.map(item => {
                const element = document.createElement('div');
                element.textContent = marker + (item.display ? 'D' : 'I') + item.source + marker + (item.display ? 'E' : 'J');
                container.append(element);
                return element;
            });
            await MathJax.typesetPromise([container]);
            if (document.fonts) await document.fonts.ready;
            const wrapperSet = new Set(wrappers), mathItems = new Map();
            for (const item of MathJax.startup.document.math) {
                const wrapper = item.typesetRoot?.parentElement;
                if (wrapperSet.has(wrapper)) mathItems.set(wrapper, mathItems.has(wrapper) ? null : item);
            }
            const targets = new Map();
            wrappers.forEach((wrapper, index) => {
                for (const element of wrapper.querySelectorAll('[id]')) {
                    if (!element.id.startsWith('mjx-eqn:')) continue;
                    targets.set(element.id, targets.has(element.id) ? null : index);
                }
            });
            async function rasterize(output) {
            if (output.querySelector('mjx-merror, [data-mml-node="merror"]')) return null;
            const svg = output.querySelector('svg');
            if (!svg || svg.querySelector('foreignObject')) return null;
            const rect = svg.getBoundingClientRect(), vb = svg.viewBox.baseVal;
            const rootMatrix = svg.getScreenCTM();
            if (!rootMatrix || !rect.width || !rect.height) throw new Error('Invalid bounds');
            const hasViewBox = vb.width > 0 && vb.height > 0;
            const vx = hasViewBox ? vb.x : 0, vy = hasViewBox ? vb.y : 0;
            const vw = hasViewBox ? vb.width : rect.width, vh = hasViewBox ? vb.height : rect.height;
            const rootInverse = rootMatrix.inverse();
            let left = vx, top = vy, right = vx + vw, bottom = vy + vh;
            for (const element of svg.querySelectorAll('path,rect,circle,ellipse,line,polyline,polygon,text,use')) {
                if (element.closest('defs')) continue;
                const matrix = element.getScreenCTM();
                if (!matrix) throw new Error('Missing transform');
                const transform = rootInverse.multiply(matrix), box = element.getBBox();
                const points = [[box.x,box.y],[box.x+box.width,box.y],[box.x,box.y+box.height],[box.x+box.width,box.y+box.height]]
                    .map(([x,y]) => new DOMPoint(x,y).matrixTransform(transform));
                const style = getComputedStyle(element);
                const stroke = style.stroke === 'none' ? 0 : Number.parseFloat(style.strokeWidth);
                const miter = style.strokeLinejoin === 'miter' ? Math.max(1, Number.parseFloat(style.strokeMiterlimit) || 1) : 1;
                const radius = stroke * miter / 2;
                const padX = radius * Math.hypot(transform.a, transform.c);
                const padY = radius * Math.hypot(transform.b, transform.d);
                left = Math.min(left, ...points.map(p => p.x - padX));
                top = Math.min(top, ...points.map(p => p.y - padY));
                right = Math.max(right, ...points.map(p => p.x + padX));
                bottom = Math.max(bottom, ...points.map(p => p.y + padY));
            }
            const scaleX = rect.width / vw, scaleY = rect.height / vh;
            left -= 2 / scaleX; right += 2 / scaleX; top -= 2 / scaleY; bottom += 2 / scaleY;
            const pixelWidth = Math.ceil((right - left) * scaleX), pixelHeight = Math.ceil((bottom - top) * scaleY);
            if (![left,top,right,bottom,pixelWidth,pixelHeight].every(Number.isFinite) || pixelWidth <= 0 || pixelHeight <= 0) throw new Error('Invalid size');
            const clone = svg.cloneNode(true);
            clone.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
            clone.setAttribute('viewBox', `${left} ${top} ${right-left} ${bottom-top}`);
            clone.setAttribute('width', String(pixelWidth));
            clone.setAttribute('height', String(pixelHeight));
            clone.setAttribute('preserveAspectRatio', 'none');
            clone.style.color = dark ? 'white' : 'black';
            // MathJax's documented standalone SVG rules; these are required
            // for frames and dashed/dotted strokes outside the host document.
            let defs = clone.querySelector('defs');
            if (!defs) { defs = document.createElementNS('http://www.w3.org/2000/svg', 'defs'); clone.prepend(defs); }
            const style = document.createElementNS('http://www.w3.org/2000/svg', 'style');
            style.textContent = '[data-frame],[data-line]{stroke-width:70px;fill:none}.mjx-dashed{stroke-dasharray:140}.mjx-dotted{stroke-linecap:round;stroke-dasharray:0,140}use[data-c]{stroke-width:3px}';
            defs.appendChild(style);
            const image = new Image();
            image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(new XMLSerializer().serializeToString(clone));
            await image.decode();
            const canvas = document.createElement('canvas');
            canvas.width = pixelWidth; canvas.height = pixelHeight;
            if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) throw new Error('Canvas size unavailable');
            const context = canvas.getContext('2d');
            if (!context) throw new Error('Canvas unavailable');
            context.drawImage(image, 0, 0);
            const data = canvas.toDataURL('image/png');
            if (!data.startsWith('data:image/png;base64,')) throw new Error('PNG unavailable');
            const links = [];
            for (const anchor of svg.querySelectorAll('a[href]')) {
                const ref = anchor.querySelector('.MathJax_ref');
                if (!ref) continue;
                const href = anchor.getAttribute('href');
                if (!href || !href.startsWith('#')) continue;
                let id;
                try { id = decodeURIComponent(href.slice(1)); } catch (_) { continue; }
                const target = targets.get(id);
                if (!id.startsWith('mjx-eqn:') || !Number.isInteger(target)) continue;
                const matrix = anchor.getScreenCTM();
                if (!matrix) continue;
                const transform = rootInverse.multiply(matrix), box = anchor.getBBox();
                const points = [[box.x,box.y],[box.x+box.width,box.y],[box.x,box.y+box.height],[box.x+box.width,box.y+box.height]]
                    .map(([x,y]) => new DOMPoint(x,y).matrixTransform(transform));
                const xs = points.map(p => p.x), ys = points.map(p => p.y);
                const x = (Math.min(...xs) - left) * pixelWidth / (right-left);
                const y = (Math.min(...ys) - top) * pixelHeight / (bottom-top);
                const w = (Math.max(...xs) - Math.min(...xs)) * pixelWidth / (right-left);
                const h = (Math.max(...ys) - Math.min(...ys)) * pixelHeight / (bottom-top);
                if ([x,y,w,h].every(Number.isFinite) && w > 0 && h > 0) links.push({target, x, y, w, h, latex: ref.getAttribute('data-latex')});
            }
            let mathml = null;
            try {
                const item = mathItems.get(output);
                if (item?.root) mathml = MathJax.startup.visitor.visitTree(item.root);
            } catch (_) {}
            return {png: data.slice('data:image/png;base64,'.length), links, mathml};
            }
            window.lacMathRasterize = rasterize;
            window.lacMathWrappers = wrappers;
            const images = [];
            for (const index of outputIndices) {
                try { images.push(await rasterize(wrappers[index])); }
                catch (_) { images.push(null); }
            }
            return images;
            """
        let items: [[String: Any]] = expressions.map { ["source": $0.source, "display": $0.display] }
        webView.callAsyncJavaScript(script, arguments: ["expressions": items, "outputIndices": outputIndices,
                "nonce": UUID().uuidString, "width": width, "fontSize": fontSize, "dark": dark], in: nil, in: .page) { [weak self] result in
            self?.receive(result)
        }
    }

    private func receive(_ result: Result<Any, Error>) {
        guard completion != nil else { return }
        guard case let .success(value) = result, let values = value as? [Any], values.count == outputIndices.count else {
            finish(.failure(RenderError.rendering)); return
        }
        var newReferences: [Int: [Reference]] = [:]
        var newMathML: [Int: String] = [:]
        let images: [NSImage?] = values.enumerated().map { offset, value in
            guard let item = value as? [String: Any], let encoded = item["png"] as? String, let data = Data(base64Encoded: encoded),
                  let image = NSImage(data: data), let bitmap = NSBitmapImageRep(data: data),
                  bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return nil }
            let links = (item["links"] as? [[String: Any]] ?? []).compactMap { link -> Reference? in
                guard let target = link["target"] as? Int, expressions.indices.contains(target),
                      let x = link["x"] as? Double, let y = link["y"] as? Double,
                      let width = link["w"] as? Double, let height = link["h"] as? Double,
                      [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
                let rect = CGRect(x: x, y: y, width: width, height: height)
                guard rect.minX >= 0, rect.minY >= 0, rect.maxX <= CGFloat(bitmap.pixelsWide), rect.maxY <= CGFloat(bitmap.pixelsHigh) else { return nil }
                return Reference(targetIndex: target, rect: rect,
                                 pixelSize: CGSize(width: CGFloat(bitmap.pixelsWide), height: CGFloat(bitmap.pixelsHigh)),
                                 latex: link["latex"] as? String)
            }
            newReferences[outputIndices[offset]] = links
            if let value = item["mathml"] as? String { newMathML[outputIndices[offset]] = value }
            return image
        }
        references = newReferences
        mathML = newMathML
        ready = true
        finish(.success(images))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigation == nil ? .cancel : .allow)
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
        if completion != nil { finish(.failure(RenderError.rendering)) }
        else { close() }
    }

    private func finish(_ result: Result<[NSImage?], Error>) {
        guard let completion else { return }
        self.completion = nil
        if !retainForRequests || (try? result.get()) == nil { close() }
        completion(result)
    }

    private func close() {
        ready = false
        webView?.navigationDelegate = nil
        webView = nil
        navigation = nil
    }
}
