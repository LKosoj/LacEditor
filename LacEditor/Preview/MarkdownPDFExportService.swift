import AppKit
import PDFKit
import WebKit
import Yams

struct MarkdownPDFMetadata {
    var attributes: [PDFDocumentAttribute: Any] = [:]
    var variables: [String: String] = [:]
}

enum MarkdownPDFMetadataReader {
    static func read(_ text: String, includeHTMLFragments: Bool = false, executable: URL? = nil, isCancelled: () -> Bool) throws -> MarkdownPDFMetadata {
        guard let block = MarkdownPresentationParser.frontMatter(text) else { return MarkdownPDFMetadata() }
        guard let executable = executable ?? PandocExportService.findPandoc() else { throw PandocExportError.missingPandoc }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.md")
        let output = directory.appendingPathComponent("output.json")
        try Data(((text as NSString).substring(with: block.range) + "\n").utf8).write(to: input)
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.arguments = ["--from=gfm+yaml_metadata_block", "--to=json", "--output", output.path, "--", input.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try CustomMarkdownExportService.run(process, isCancelled: isCancelled)
        guard process.terminationStatus == 0,
              let root = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any],
              let meta = root["meta"] as? [String: Any] else { throw MarkdownPDFExportService.ExportError.invalidMetadata }
        func inlineText(_ values: [[String: Any]]) -> String? {
            var output = ""
            for node in values {
                switch node["t"] as? String {
                case "Str":
                    guard let value = node["c"] as? String else { return nil }
                    output += value
                case "Space", "SoftBreak", "LineBreak": output += " "
                case "Emph", "Strong", "Strikeout", "Superscript", "Subscript", "SmallCaps", "Underline":
                    guard let content = node["c"] as? [[String: Any]], let text = inlineText(content) else { return nil }
                    output += text
                case "Code", "Math":
                    guard let parts = node["c"] as? [Any], parts.count == 2, let text = parts[1] as? String else { return nil }
                    output += text
                case "Span", "Quoted", "Link", "Image":
                    guard let parts = node["c"] as? [Any], parts.count >= 2,
                          let content = parts[1] as? [[String: Any]], let text = inlineText(content) else { return nil }
                    output += text
                default: return nil
                }
            }
            return output
        }
        func plain(_ value: Any) -> String? {
            guard let node = value as? [String: Any], let type = node["t"] as? String else { return nil }
            if type == "MetaString" { return node["c"] as? String }
            if type == "MetaInlines", let inlines = node["c"] as? [[String: Any]] { return inlineText(inlines) }
            if type == "MetaBlocks", let blocks = node["c"] as? [[String: Any]] {
                var parts: [String] = []
                for block in blocks {
                    guard ["Para", "Plain"].contains(block["t"] as? String ?? ""),
                          let inlines = block["c"] as? [[String: Any]], let text = inlineText(inlines) else { return nil }
                    parts.append(text)
                }
                return parts.joined(separator: "\n")
            }
            return nil
        }
        var result = MarkdownPDFMetadata()
        func collect(_ value: Any, key: String) {
            guard let node = value as? [String: Any] else { return }
            if node["t"] as? String == "MetaMap", let children = node["c"] as? [String: Any] {
                for (name, child) in children { collect(child, key: key + "." + name) }
            } else if let text = plain(value) { result.variables[key] = text }
        }
        for (name, value) in meta { collect(value, key: name) }
        let literalMapping: Node.Mapping?
        do {
            literalMapping = try PandocExportService.yamlFrontMatter(text)
            if let literalMapping {
                for (name, value) in try PandocExportService.yamlScalarVariables(literalMapping, isCancelled: isCancelled) { result.variables[name] = value }
                for key in ["currentPath", "currentFolder", "currentFileName", "currentFileFullName"] { result.variables.removeValue(forKey: key) }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw MarkdownPDFExportService.ExportError.invalidMetadata }
        if includeHTMLFragments {
            for key in ["append-head", "typora-append-head", "append-body", "typora-append-body",
                        "append-head-extra", "typora-append-head-extra", "append-body-extra", "typora-append-body-extra"] {
                if let value = literalMapping?[key] {
                    guard value.tag == Tag(.str), let literal = value.scalar?.string else { throw MarkdownPDFExportService.ExportError.invalidMetadata }
                    result.variables[key] = literal
                }
            }
        }
        for (key, attribute) in [("title", PDFDocumentAttribute.titleAttribute), ("author", .authorAttribute),
                                 ("creator", .creatorAttribute), ("subject", .subjectAttribute)] {
            if let raw = meta[key] {
                if key == "author", let node = raw as? [String: Any], node["t"] as? String == "MetaList",
                   let authors = node["c"] as? [Any] {
                    let values = authors.compactMap(plain)
                    guard values.count == authors.count else { throw MarkdownPDFExportService.ExportError.invalidMetadata }
                    result.attributes[attribute] = values.joined(separator: ", ")
                    result.variables[key] = values.joined(separator: ", ")
                } else {
                    guard let value = plain(raw) else { throw MarkdownPDFExportService.ExportError.invalidMetadata }
                    result.attributes[attribute] = value
                }
            }
        }
        if let raw = meta["keywords"] ?? meta["tags"] {
            guard let node = raw as? [String: Any] else { throw MarkdownPDFExportService.ExportError.invalidMetadata }
            if node["t"] as? String == "MetaList", let items = node["c"] as? [Any] {
                let values = items.compactMap(plain)
                guard values.count == items.count else { throw MarkdownPDFExportService.ExportError.invalidMetadata }
                result.attributes[.keywordsAttribute] = values
            } else if let value = plain(raw) { result.attributes[.keywordsAttribute] = [value] }
            else { throw MarkdownPDFExportService.ExportError.invalidMetadata }
        }
        return result
    }
}

@MainActor
final class MarkdownPDFExportService: NSObject, WKNavigationDelegate {
    enum ExportError: LocalizedError {
        case cancelled, rendering, printFailed, imageFailed, unsupportedPrintDestination, bookmarksFailed, invalidOptions, invalidMetadata

        var errorDescription: String? {
            switch self {
            case .cancelled: L10n.tr("取消")
            case .rendering: L10n.tr("打印内容尚未完成加载")
            case .printFailed: L10n.tr("无法生成 PDF")
            case .imageFailed: L10n.tr("无法生成完整的 PNG 图像")
            case .unsupportedPrintDestination: L10n.tr("不支持此打印目标")
            case .invalidMetadata: L10n.tr("无法读取 PDF 元数据")
            case .invalidOptions: L10n.tr("导出页面或图像尺寸无效")
            case .bookmarksFailed: L10n.tr("无法确定 PDF 目录中的标题位置")
            }
        }
    }

    enum Output { case file(PandocExportResult), printed }
    enum Mode {
        case pdf, png, htmlPlain, printJob(NSPrintInfo)

        var requiresMetadata: Bool {
            switch self {
            case .pdf: return true
            case .htmlPlain: return true
            case .png: return false
            case let .printJob(info): return info.jobDisposition == .save
            }
        }
    }

    private let destination: URL?
    private let mode: Mode
    private weak var window: NSWindow?
    private let isCurrent: () -> Bool
    private let imageSession: URLSession?
    private var completion: ((Result<Output, Error>) -> Void)?
    private var webView: WKWebView?
    private var navigation: WKNavigation?
    private var printOperation: NSPrintOperation?
    private var spoolInfo: NSPrintInfo?
    private var spoolDocument: PDFDocument?
    private var printingProcessedPDF = false
    private var printLifetime: MarkdownPDFExportService?
    private var pendingPrintError: Error?
    private var temporaryDirectory: URL?
    private var renderTask: Task<Void, Never>?
    private var metadataTask: Task<MarkdownPDFMetadata, Error>?
    private var metadata = MarkdownPDFMetadata()
    private var headers = MarkdownPDFHeaderFooterOptions()
    private var htmlOptions = MarkdownHTMLExportOptions()
    private var printMargins = (top: 0.0, bottom: 0.0, left: 0.0, right: 0.0)
    private var sourceURL: URL?
    private var cancelled = false
    private var options = MarkdownNativeExportOptions()
    private var imageScale = 1.0
    private var darkMode = false
    private var formulas: [MarkdownRenderedMath] = []
    private var diagrams: [MarkdownRenderedDiagram] = []
    private var omittedHTML = false
    private var rawHTMLBlocks: [(marker: String, html: String)] = []
    private var legacyService: LegacyDiagramRenderService?
    private var legacyToken: UUID?
    private var mathService: MathJaxRenderService?
    private var mathToken: UUID?
    private var mathOptions = MathJaxRenderService.Options()
    private struct BookmarkHeading {
        let url: URL
        let title: String
        let level: Int
    }
    private var bookmarkHeadings: [BookmarkHeading] = []
    private struct MathLinkMarker {
        let source: URL
        let target: URL
    }
    private var mathLinkMarkers: [MathLinkMarker] = []
    private var requestedPages: ClosedRange<Int>?

    init(destination: URL?, mode: Mode = .pdf, window: NSWindow, isCurrent: @escaping () -> Bool, imageSession: URLSession? = nil,
         completion: @escaping (Result<Output, Error>) -> Void) {
        self.destination = destination
        self.mode = mode
        self.window = window
        self.isCurrent = isCurrent
        self.imageSession = imageSession
        self.completion = completion
    }

    func start(snapshot: DocumentTextSnapshot, darkMode: Bool, typography: MarkdownTypography? = nil,
               mathOptions: MathJaxRenderService.Options = .init(), options: MarkdownNativeExportOptions = .init(),
               headers: MarkdownPDFHeaderFooterOptions = .init(), sourceURL: URL? = nil,
               htmlOptions: MarkdownHTMLExportOptions = .init(), syntax: MarkdownSyntaxOptions = .init(),
               wiki: MarkdownWikiLinkSource? = nil, allowRemoteImages: Bool = false) {
        self.htmlOptions = htmlOptions
        self.options = options
        self.headers = headers
        self.sourceURL = sourceURL
        if case .png = mode {
            switch options.imageQuality ?? "auto" {
            case "auto", "medium": imageScale = 1
            case "high": imageScale = 2
            case "best": imageScale = 4
            default: finish(.failure(ExportError.invalidOptions)); return
            }
            guard options.imageWidth.isFinite, options.imageWidth > 0,
                  (options.imageWidth * imageScale).isFinite,
                  !options.customImageFontSize || (options.imageFontSize.isFinite && options.imageFontSize > 0) else {
                finish(.failure(ExportError.invalidOptions)); return
            }
        }
        self.darkMode = darkMode
        self.mathOptions = mathOptions
        let isImage: Bool
        if case .png = mode { isImage = true } else { isImage = false }
        let isHTML: Bool
        if case .htmlPlain = mode { isHTML = true } else { isHTML = false }
        let needsProcessedPrint: Bool
        if case let .printJob(info) = mode, info.jobDisposition == .spool {
            needsProcessedPrint = !headers.header.isEmpty || !headers.footer.isEmpty || headers.allowDocumentOverrides
        } else { needsProcessedPrint = false }
        let requiresMetadata = mode.requiresMetadata || needsProcessedPrint
        renderTask = Task { [weak self] in
            guard !Task.isCancelled, self?.completion != nil, self?.cancelled == false else { return }
            guard self?.isCurrent() == true else { self?.finish(.failure(ExportError.cancelled)); return }
            if requiresMetadata {
                let metadataTask = Task.detached(priority: .userInitiated) {
                    try MarkdownPDFMetadataReader.read(snapshot.text, includeHTMLFragments: isHTML && htmlOptions.allowDocumentOverrides,
                                                       isCancelled: { Task.isCancelled })
                }
                self?.metadataTask = metadataTask
                guard !Task.isCancelled, self?.completion != nil, self?.cancelled == false else {
                    metadataTask.cancel()
                    return
                }
                do {
                    let metadata = try await metadataTask.value
                    guard let self else { return }
                    guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
                    self.metadataTask = nil
                    self.metadata = metadata
                } catch {
                    guard let self else { return }
                    self.metadataTask = nil
                    self.finish(.failure(self.cancelled ? ExportError.cancelled : error))
                    return
                }
            }
            let imageSession = self?.imageSession
            let remoteImagesAllowed = allowRemoteImages
            let pageTask = Task.detached(priority: .userInitiated) {
                // Список файлов читается с диска заново; без него wiki-ссылки остаются обычным текстом.
                let wikiContext = (wiki != nil && snapshot.text.contains("[[")) ? wiki.flatMap {
                    try? MarkdownWikiLinkContext.load(root: $0.root, documentURL: $0.documentURL, isCancelled: { Task.isCancelled })
                } : nil
                var page = MarkdownRenderer.renderPage(snapshot.text, darkMode: darkMode, includeHTMLMedia: isHTML, renderEmoji: true,
                                                       resolveLocalImages: !isHTML, documentURL: sourceURL, prepareRemoteImages: !isHTML, syntax: syntax, forExport: true, includeHeadingNumbers: true, includeListStyles: true,
                                                       staticWidgetFallback: !isHTML, preserveRawHTMLBlocks: isHTML, highlightCode: !isHTML, wiki: wikiContext)
                if remoteImagesAllowed { try? await page.resolveRemoteImages(session: imageSession) }
                else { try? page.hideRemoteImages() }
                try? page.prepareLocalMedia(load: true)
                if isImage && options.customImageFontSize {
                    page.typography = MarkdownTypography(fontSize: options.imageFontSize,
                        lineHeight: typography.flatMap { $0.usesCustomFontMetrics ? $0.lineHeight * options.imageFontSize / $0.fontSize : nil } ?? options.imageFontSize * 1.5,
                        textFamily: typography.flatMap { $0.usesCustomFontMetrics ? $0.textFamily : nil },
                        codeFamily: typography.flatMap { $0.usesCustomFontMetrics ? $0.codeFamily : nil },
                        maximumWidth: typography?.maximumWidth, tocMaxLevel: typography?.tocMaxLevel ?? 6, ligatures: typography?.ligatures, smallCapsLevels: typography?.smallCapsLevels ?? [], centeredHeadingLevels: typography?.centeredHeadingLevels ?? [], textAlignment: typography?.textAlignment, rightToLeft: typography?.rightToLeft ?? false, verticalWriting: typography?.verticalWriting ?? false, strikeCompletedTasks: typography?.strikeCompletedTasks ?? false, numberHeadings: typography?.numberHeadings ?? false, paragraphSpacing: typography?.paragraphSpacing,
                        listStyles: typography?.listStyles ?? .init(), uppercaseHeadingLevels: typography?.uppercaseHeadingLevels ?? [], lightColors: typography?.lightColors ?? .init(), darkColors: typography?.darkColors ?? .init())
                } else { page.typography = typography }
                return page
            }
            let page = await withTaskCancellationHandler(operation: { await pageTask.value }, onCancel: { pageTask.cancel() })
            guard let self else { return }
            guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
            guard !page.rawHTMLBlockProofFailed else { self.finish(.failure(ExportError.rendering)); return }
            self.formulas = page.formulas
            self.diagrams = page.diagrams
            self.omittedHTML = page.omittedHTML
            self.rawHTMLBlocks = page.rawHTMLBlocks
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            let width = isImage ? options.imageWidth : 760.0
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 900), configuration: configuration)
            view.navigationDelegate = self
            self.webView = view
            self.navigation = view.loadHTMLString(page.html, baseURL: nil)
            if self.navigation == nil { self.finish(.failure(ExportError.rendering)) }
        }
    }

    func cancel() {
        cancelled = true
        renderTask?.cancel()
        metadataTask?.cancel()
        let previousLegacy = legacyService
        legacyService = nil
        legacyToken = nil
        previousLegacy?.cancel()
        let previousMath = mathService
        mathService = nil
        mathToken = nil
        previousMath?.cancel()
        webView?.stopLoading()
        if printOperation == nil { finish(.failure(ExportError.cancelled)) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation, !cancelled, isCurrent() else { finish(.failure(ExportError.cancelled)); return }
        self.navigation = nil
        if let script = MarkdownPreview.Coordinator.mermaidScript {
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self, weak webView] result in
                guard let self, let webView, self.completion != nil, self.webView === webView else { return }
                guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
                guard case .success = result else { self.finish(.failure(ExportError.rendering)); return }
                self.prepareDiagrams(in: webView)
            }
        } else {
            prepareDiagrams(in: webView)
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
        finish(.failure(ExportError.rendering))
    }

    private func prepareDiagrams(in webView: WKWebView) {
        guard !diagrams.isEmpty else { prepareMath(in: webView); return }
        webView.callAsyncJavaScript("return document.querySelector('article').clientWidth;", arguments: [:], in: nil, in: .defaultClient) { [weak self, weak webView] result in
            guard let self, let webView, self.completion != nil, self.webView === webView else { return }
            guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
            guard case let .success(value) = result, let width = (value as? NSNumber)?.doubleValue,
                  width.isFinite, width > 0 else { self.finish(.failure(ExportError.rendering)); return }
            let token = UUID()
            self.legacyToken = token
            self.prepareDiagram(at: 0, in: webView, width: CGFloat(width), token: token)
        }
    }

    private func prepareDiagram(at index: Int, in webView: WKWebView, width: CGFloat, token: UUID) {
        guard completion != nil, self.webView === webView, legacyToken == token else { return }
        guard !cancelled, isCurrent() else { finish(.failure(ExportError.cancelled)); return }
        guard diagrams.indices.contains(index) else { legacyToken = nil; prepareMath(in: webView); return }
        let item = diagrams[index]
        let kind: LegacyDiagramRenderService.Kind = item.kind == .flow ? .flow : .sequence
        let service = LegacyDiagramRenderService(code: item.source, kind: kind, width: width) { [weak self, weak webView] result in
            guard let self, let webView, self.completion != nil, self.webView === webView, self.legacyToken == token else { return }
            self.legacyService = nil
            guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
            var encoded: String?
            if case let .success(image) = result, let data = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
                encoded = png.base64EncodedString()
            }
            let script = """
                const target = document.querySelector(`[data-lac-diagram="${index}"]`);
                if (!target) throw new Error('Diagram placeholder missing');
                if (png !== null) {
                    const image = document.createElement('img');
                    image.alt = source;
                    image.src = 'data:image/png;base64,' + png;
                    image.style.maxWidth = '100%';
                    target.replaceChildren(image);
                }
                return true;
                """
            webView.callAsyncJavaScript(script, arguments: ["index": index, "source": item.source, "png": encoded as Any? ?? NSNull()], in: nil, in: .defaultClient) { [weak self, weak webView] result in
                guard let self, let webView, self.completion != nil, self.webView === webView, self.legacyToken == token else { return }
                guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
                guard case .success = result else { self.finish(.failure(ExportError.rendering)); return }
                self.prepareDiagram(at: index + 1, in: webView, width: width, token: token)
            }
        }
        legacyService = service
        service.start()
    }

    private func prepareMath(in webView: WKWebView) {
        guard !formulas.isEmpty else { waitForResources(in: webView); return }
        webView.callAsyncJavaScript("return [document.querySelector('article').clientWidth, parseFloat(getComputedStyle(document.body).fontSize)];",
                                    arguments: [:], in: nil, in: .defaultClient) { [weak self, weak webView] result in
            guard let self, let webView, self.completion != nil, self.webView === webView else { return }
            guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
            guard case let .success(value) = result, let dimensions = value as? [Double], dimensions.count == 2,
                  dimensions.allSatisfy({ $0.isFinite && $0 > 0 }) else { self.finish(.failure(ExportError.rendering)); return }
            let expressions = self.formulas.map { MathJaxRenderService.Expression(source: $0.source, display: $0.display) }
            let token = UUID()
            let service = MathJaxRenderService(expressions: expressions, outputIndices: Array(expressions.indices),
                                               width: CGFloat(dimensions[0]), dark: self.darkMode,
                                               fontSize: CGFloat(dimensions[1]), options: self.mathOptions) { [weak self, weak webView] result in
                guard let self, let webView, self.mathToken == token else { return }
                let references = self.mathService?.references ?? [:]
                self.mathToken = nil
                self.mathService = nil
                guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
                guard case let .success(images) = result, images.count == expressions.count else { self.finish(.failure(ExportError.rendering)); return }
                var payload: [String] = []
                for image in images {
                    guard let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                          let png = bitmap.representation(using: .png, properties: [:]) else { self.finish(.failure(ExportError.rendering)); return }
                    payload.append(png.base64EncodedString())
                }
                let nonce = UUID().uuidString.lowercased()
                var links = Array(repeating: [[String: Any]](), count: expressions.count)
                var targets = Array(repeating: [String](), count: expressions.count)
                self.mathLinkMarkers = []
                let needsLinks: Bool
                if case .png = self.mode { needsLinks = false }
                else if case .htmlPlain = self.mode { needsLinks = false }
                else if case let .printJob(info) = self.mode, info.jobDisposition == .spool,
                        self.headers.header.isEmpty, self.headers.footer.isEmpty, !self.headers.allowDocumentOverrides { needsLinks = false }
                else { needsLinks = true }
                if needsLinks {
                    for index in expressions.indices {
                        for reference in references[index] ?? [] {
                            guard expressions.indices.contains(reference.targetIndex), reference.pixelSize.width > 0,
                                  reference.pixelSize.height > 0 else { self.finish(.failure(ExportError.rendering)); return }
                            let number = self.mathLinkMarkers.count
                            guard let source = URL(string: "https://laceditor.invalid/\(nonce)/source/\(number)"),
                                  let target = URL(string: "https://laceditor.invalid/\(nonce)/target/\(number)") else {
                                self.finish(.failure(ExportError.rendering)); return
                            }
                            self.mathLinkMarkers.append(MathLinkMarker(source: source, target: target))
                            links[index].append(["url": source.absoluteString,
                                "x": reference.rect.minX / reference.pixelSize.width, "y": reference.rect.minY / reference.pixelSize.height,
                                "w": reference.rect.width / reference.pixelSize.width, "h": reference.rect.height / reference.pixelSize.height])
                            targets[reference.targetIndex].append(target.absoluteString)
                        }
                    }
                }
                let script = """
                    for (let i = 0; i < images.length; i++) {
                        const target = document.querySelector(`[data-lac-math="${i}"]`);
                        if (!target) throw new Error('Math placeholder missing');
                        const image = document.createElement('img');
                        image.alt = target.textContent;
                        image.src = 'data:image/png;base64,' + images[i];
                        if (!links[i].length && !targets[i].length) { target.replaceChildren(image); continue; }
                        const wrapper = document.createElement('span');
                        Object.assign(wrapper.style, {position:'relative', display:'inline-block', maxWidth:'100%', verticalAlign:'baseline'});
                        Object.assign(image.style, {display:'block', maxWidth:'100%'});
                        wrapper.appendChild(image);
                        function marker(url, x, y, w, h) {
                            const anchor = document.createElement('a');
                            anchor.href = url;
                            Object.assign(anchor.style, {position:'absolute', left:x, top:y, width:w, height:h, padding:'0', border:'0', margin:'0'});
                            const pixel = document.createElement('img');
                            pixel.src = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
                            Object.assign(pixel.style, {display:'block', width:'100%', height:'100%', maxWidth:'none'});
                            anchor.appendChild(pixel);
                            wrapper.appendChild(anchor);
                        }
                        for (const link of links[i]) marker(link.url, `${link.x * 100}%`, `${link.y * 100}%`, `${link.w * 100}%`, `${link.h * 100}%`);
                        for (const url of targets[i]) marker(url, '0', '0', '1pt', '1pt');
                        target.replaceChildren(wrapper);
                    }
                    return true;
                    """
                webView.callAsyncJavaScript(script, arguments: ["images": payload, "links": links, "targets": targets], in: nil, in: .defaultClient) { [weak self, weak webView] result in
                    guard let self, let webView, self.completion != nil, self.webView === webView else { return }
                    guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
                    guard case .success = result else { self.finish(.failure(ExportError.rendering)); return }
                    self.waitForResources(in: webView)
                }
            }
            self.mathToken = token
            self.mathService = service
            service.start()
        }
    }

    private func waitForResources(in webView: WKWebView) {
        let script = """
            const diagrams = document.querySelectorAll('pre > code.language-mermaid');
            if (diagrams.length && !globalThis.lacMermaid) throw new Error('Mermaid unavailable');
            if (globalThis.lacMermaid) await globalThis.lacMermaid.render(1, dark, errorText);
            if (document.querySelector('.mermaid-diagram[role="alert"]')) throw new Error('Mermaid failed');
            await Promise.all(Array.from(document.images, async image => {
                if (htmlPlain && !image.getAttribute('src')?.startsWith('data:')) return;
                if (!image.complete) await new Promise((resolve, reject) => {
                    image.addEventListener('load', resolve, {once:true});
                    image.addEventListener('error', reject, {once:true});
                });
                if (!image.naturalWidth) throw new Error('Image failed');
                if (image.decode) await image.decode();
            }));
            if (document.fonts) await document.fonts.ready;
            if (pageBreaks) {
                const headings = document.querySelectorAll('article h1');
                for (let i = 1; i < headings.length; i++) headings[i].style.breakBefore = 'page';
                document.querySelectorAll('article section[data-footnotes]').forEach(section => { section.style.breakBefore = 'page'; });
            }
            return true;
            """
        let pageBreaks: Bool
        let htmlPlain: Bool
        if case .htmlPlain = mode { htmlPlain = true } else { htmlPlain = false }
        if case .png = mode { pageBreaks = false }
        else if htmlPlain { pageBreaks = false }
        else { pageBreaks = options.pageBreakTopHeadings ?? false }
        webView.callAsyncJavaScript(script, arguments: ["dark": darkMode, "errorText": L10n.tr("无法显示 Mermaid 图表"), "pageBreaks": pageBreaks, "htmlPlain": htmlPlain], in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
            guard case .success = result else { self.finish(.failure(ExportError.rendering)); return }
            if case .png = self.mode { self.beginImage(in: webView) }
            else if case .htmlPlain = self.mode { self.beginHTML(in: webView) }
            else if case let .printJob(info) = self.mode, info.jobDisposition == .spool { self.schedulePrint() }
            else { self.prepareBookmarkMarkers(in: webView) }
        }
    }

    private func beginHTML(in webView: WKWebView) {
        let script = """
            const article = document.querySelector('article')?.cloneNode(true);
            if (!article) throw new Error('Missing article');
            article.querySelectorAll('span[data-lac-checked-task]').forEach(marker => marker.remove());
            article.querySelectorAll('span[data-lac-heading-number]').forEach(marker => marker.remove());
            article.querySelectorAll('span[data-lac-list-depth]').forEach(marker => marker.remove());
            article.querySelectorAll('pre > code.language-mermaid').forEach(code => {
                if (code.parentElement.nextElementSibling?.classList.contains('mermaid-diagram')) code.parentElement.remove();
            });
            return article.outerHTML;
            """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { [weak self, weak webView] result in
            guard let self, let webView, self.completion != nil, self.webView === webView else { return }
            guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
            guard case let .success(value) = result, let article = value as? String, let destination = self.destination else {
                self.finish(.failure(ExportError.rendering)); return
            }
            do {
                var variables = self.metadata.variables
                variables["outputPath"] = destination.path
                variables["outputFileName"] = destination.deletingPathExtension().lastPathComponent
                variables["outputFileFullName"] = destination.lastPathComponent
                if let source = self.sourceURL {
                    variables["currentPath"] = source.path
                    variables["currentFolder"] = source.deletingLastPathComponent().path
                    variables["currentFileName"] = source.deletingPathExtension().lastPathComponent
                    variables["currentFileFullName"] = source.lastPathComponent
                }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                variables["today"] = formatter.string(from: Date())
                let fragments = MarkdownHTMLMediaService.exportFragments(options: self.htmlOptions, variables: variables)
                let title = variables["title"].map { text in
                    "<title>" + text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") + "</title>"
                } ?? ""
                let rawArticle = article as NSString
                var replacements: [(NSRange, String)] = [], previousEnd = 0
                for block in self.rawHTMLBlocks {
                    guard !self.cancelled, self.isCurrent() else { throw ExportError.cancelled }
                    let range = rawArticle.range(of: block.marker)
                    guard range.location != NSNotFound, range.location >= previousEnd,
                          rawArticle.range(of: block.marker, options: .backwards) == range else { throw ExportError.rendering }
                    replacements.append((range, block.html))
                    previousEnd = NSMaxRange(range)
                }
                let restoredArticle = NSMutableString(string: article)
                for (range, original) in replacements.reversed() { restoredArticle.replaceCharacters(in: range, with: original) }
                let html = "<!doctype html><html><head><meta charset=\"utf-8\">" + title + fragments.head + "</head><body>" + (restoredArticle as String) + fragments.body + "</body></html>"
                let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                            appropriateFor: destination.deletingLastPathComponent(), create: true)
                self.temporaryDirectory = directory
                let output = directory.appendingPathComponent("output.html")
                try Data(html.utf8).write(to: output, options: .withoutOverwriting)
                let diagnostics = self.omittedHTML ? L10n.tr("部分 HTML 内容无法包含在导出中。") : ""
                self.finish(.success(.file(PandocExportResult(preparedURL: output, diagnostics: diagnostics))))
            } catch { self.finish(.failure(error)) }
        }
    }

    private func prepareBookmarkMarkers(in webView: WKWebView) {
        let nonce = UUID().uuidString.lowercased()
        let script = """
            const headings = Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6'));
            return headings.map((heading, index) => {
                const titleNode = heading.cloneNode(true);
                for (const image of titleNode.querySelectorAll('img')) image.replaceWith(document.createTextNode(image.alt || ''));
                const title = titleNode.textContent.trim();
                const walker = document.createTreeWalker(heading, NodeFilter.SHOW_TEXT);
                let text = null, candidate;
                while ((candidate = walker.nextNode())) {
                    if (candidate.nodeValue.trim() && !candidate.parentElement.closest('a')) { text = candidate; break; }
                }
                const anchor = document.createElement('a');
                anchor.href = 'https://laceditor.invalid/' + nonce + '/' + index;
                anchor.style.color = 'inherit';
                anchor.style.textDecoration = 'none';
                if (text) {
                    text.parentNode.insertBefore(anchor, text);
                    anchor.appendChild(text);
                } else {
                    const before = heading.getBoundingClientRect();
                    Object.assign(anchor.style, {position:'absolute', display:'block', width:'1pt', height:'1pt',
                        color:'transparent', background:'transparent', border:'0', padding:'0', margin:'0',
                        fontSize:'1pt', lineHeight:'1pt', overflow:'hidden'});
                    anchor.textContent = '.';
                    heading.prepend(anchor);
                    const after = heading.getBoundingClientRect(), marker = anchor.getBoundingClientRect();
                    if (before.x !== after.x || before.y !== after.y || before.width !== after.width || before.height !== after.height ||
                        marker.width <= 0 || marker.height <= 0) throw new Error('Marker changed heading layout');
                }
                return { title, level: Number(heading.tagName.slice(1)), index };
            });
            """
        webView.callAsyncJavaScript(script, arguments: ["nonce": nonce], in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
            guard case let .success(value) = result, let headings = value as? [[String: Any]] else {
                self.finish(.failure(ExportError.bookmarksFailed)); return
            }
            var parsed: [BookmarkHeading] = []
            for (index, heading) in headings.enumerated() {
                guard let title = heading["title"] as? String, let level = heading["level"] as? Int,
                      let actualIndex = heading["index"] as? Int, actualIndex == index,
                      (1...6).contains(level), let url = URL(string: "https://laceditor.invalid/\(nonce)/\(index)") else {
                    self.finish(.failure(ExportError.bookmarksFailed)); return
                }
                parsed.append(BookmarkHeading(url: url, title: title, level: level))
            }
            self.bookmarkHeadings = parsed
            self.schedulePrint()
        }
    }

    private func schedulePrint() {
        // Return from WebKit's JavaScript callback before entering AppKit's
        // modal print loop to avoid reentrant WKWebView rendering.
        DispatchQueue.main.async { [weak self] in
            self?.beginPrint()
        }
    }

    private func beginImage(in webView: WKWebView) {
        let measurement = "Math.ceil(Math.max(document.documentElement.scrollHeight, document.body.scrollHeight))"
        webView.evaluateJavaScript(measurement) { [weak self, weak webView] value, error in
            guard let self, let webView else { return }
            guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
            guard error == nil, let height = (value as? NSNumber)?.doubleValue,
                  height.isFinite, height > 0 else { self.finish(.failure(ExportError.imageFailed)); return }
            webView.setFrameSize(NSSize(width: self.options.imageWidth, height: height))
            webView.evaluateJavaScript(measurement) { [weak self, weak webView] value, error in
                guard let self, let webView else { return }
                guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
                guard error == nil, let measured = (value as? NSNumber)?.doubleValue,
                      measured.isFinite, measured > 0, measured <= Double(webView.bounds.height),
                      webView.bounds.width == self.options.imageWidth, let destination = self.destination else {
                    self.finish(.failure(ExportError.imageFailed)); return
                }
                let config = WKSnapshotConfiguration()
                config.rect = webView.bounds
                if self.options.imageQuality != nil && self.options.imageQuality != "auto" {
                    config.snapshotWidth = NSNumber(value: self.options.imageWidth * self.imageScale)
                }
                webView.takeSnapshot(with: config) { [weak self] image, error in
                    guard let self else { return }
                    guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
                    guard error == nil, let image, let tiff = image.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                          abs(Double(image.size.width) - self.options.imageWidth * self.imageScale) <= 1,
                          abs(Double(image.size.height) - Double(webView.bounds.height) * self.imageScale) <= 1,
                          Double(bitmap.pixelsWide) >= self.options.imageWidth * self.imageScale,
                          Double(bitmap.pixelsHigh) >= Double(webView.bounds.height) * self.imageScale,
                          abs(Double(bitmap.pixelsHigh) - Double(bitmap.pixelsWide) * Double(webView.bounds.height) / self.options.imageWidth) <= 1,
                          let png = bitmap.representation(using: .png, properties: [:]),
                          let check = NSBitmapImageRep(data: png), check.pixelsWide == bitmap.pixelsWide,
                          check.pixelsHigh == bitmap.pixelsHigh else { self.finish(.failure(ExportError.imageFailed)); return }
                    do {
                        let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                                    appropriateFor: destination.deletingLastPathComponent(), create: true)
                        self.temporaryDirectory = directory
                        let output = directory.appendingPathComponent("output.png")
                        try png.write(to: output, options: .withoutOverwriting)
                        self.finish(.success(.file(PandocExportResult(preparedURL: output, diagnostics: ""))))
                    } catch { self.finish(.failure(error)) }
                }
            }
        }
    }

    private func beginPrint() {
        guard let webView, !cancelled, isCurrent() else { finish(.failure(ExportError.cancelled)); return }
        do {
            let info: NSPrintInfo
            if case let .printJob(selected) = mode { info = selected.copy() as! NSPrintInfo }
            else { info = NSPrintInfo.shared.copy() as! NSPrintInfo; info.jobDisposition = .save }
            if case .pdf = mode {
                switch options.paper {
                case "system": break
                case "a4": info.paperSize = NSSize(width: 595.28, height: 841.89)
                case "a5": info.paperSize = NSSize(width: 419.53, height: 595.28)
                case "letter": info.paperSize = NSSize(width: 612, height: 792)
                case "custom":
                    guard options.paperWidth.isFinite, options.paperHeight.isFinite,
                          options.paperWidth > 0, options.paperHeight > 0 else { throw ExportError.invalidOptions }
                    info.paperSize = NSSize(width: options.paperWidth, height: options.paperHeight)
                default: throw ExportError.invalidOptions
                }
                if options.customMargins {
                    info.topMargin = options.marginTop
                    info.bottomMargin = options.marginBottom
                    info.leftMargin = options.marginLeft
                    info.rightMargin = options.marginRight
                }
                let size = info.paperSize
                let margins = [info.topMargin, info.bottomMargin, info.leftMargin, info.rightMargin]
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                      margins.allSatisfy({ $0.isFinite && $0 >= 0 }),
                      info.leftMargin + info.rightMargin < size.width,
                      info.topMargin + info.bottomMargin < size.height else { throw ExportError.invalidOptions }
            }
            printMargins = (info.topMargin, info.bottomMargin, info.leftMargin, info.rightMargin)
            if info.jobDisposition == .spool && (!headers.header.isEmpty || !headers.footer.isEmpty || headers.allowDocumentOverrides) {
                spoolInfo = info.copy() as? NSPrintInfo
                info.jobDisposition = .save
            }
            if info.jobDisposition == .save {
                if destination == nil && spoolInfo == nil { throw ExportError.unsupportedPrintDestination }
                let dictionary = info.dictionary()
                let allPages = (dictionary[NSPrintInfo.AttributeKey.allPages] as? NSNumber)?.boolValue ?? true
                if !allPages {
                    guard let first = (dictionary[NSPrintInfo.AttributeKey.firstPage] as? NSNumber)?.intValue,
                          let last = (dictionary[NSPrintInfo.AttributeKey.lastPage] as? NSNumber)?.intValue,
                          first > 0, last >= first else { throw ExportError.printFailed }
                    requestedPages = first...last
                    dictionary[NSPrintInfo.AttributeKey.allPages] = NSNumber(value: true)
                }
                let directory: URL
                if let destination {
                    directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                            appropriateFor: destination.deletingLastPathComponent(), create: true)
                } else {
                    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                }
                temporaryDirectory = directory
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = directory.appendingPathComponent("output.pdf") as NSURL
            } else if info.jobDisposition != .spool { throw ExportError.unsupportedPrintDestination }
            let printableHeight = info.paperSize.height - info.topMargin - info.bottomMargin
            guard printableHeight.isFinite, printableHeight > 0 else { throw ExportError.invalidOptions }
            webView.evaluateJavaScript("document.documentElement.style.setProperty('--lac-print-height', '\(printableHeight)pt')") { [weak self, weak webView] _, error in
                guard let self, let webView else { return }
                guard !self.cancelled, self.isCurrent() else { self.finish(.failure(ExportError.cancelled)); return }
                guard error == nil else { self.finish(.failure(ExportError.rendering)); return }
                self.runPrint(in: webView, with: info)
            }
        } catch {
            finish(.failure(error))
        }
    }

    private func runPrint(in webView: WKWebView, with info: NSPrintInfo) {
        guard let window, !cancelled, isCurrent() else { finish(.failure(ExportError.cancelled)); return }
        let operation = webView.printOperation(with: info)
        if info.jobDisposition == .save {
            guard let output = temporaryDirectory?.appendingPathComponent("output.pdf") else {
                finish(.failure(ExportError.printFailed))
                return
            }
            printOperation = operation
            printLifetime = self
            webView.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
                guard let self else { return }
                guard !self.cancelled, self.isCurrent() else {
                    self.printOperation = nil
                    self.finish(.failure(ExportError.cancelled))
                    return
                }
                do {
                    let data = try result.get()
                    guard !data.isEmpty else { throw ExportError.printFailed }
                    let paginated = try self.paginatePDF(data, printInfo: info)
                    try paginated.write(to: output, options: .withoutOverwriting)
                    self.printDidRun(operation, success: true, contextInfo: nil)
                } catch {
                    self.printOperation = nil
                    self.finish(.failure(error))
                }
            }
            return
        }
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.canSpawnSeparateThread = false
        printOperation = operation
        printLifetime = self
        operation.runModal(for: window, delegate: self, didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    private func paginatePDF(_ data: Data, printInfo: NSPrintInfo) throws -> Data {
        guard let provider = CGDataProvider(data: data as CFData), let source = CGPDFDocument(provider),
              source.numberOfPages > 0, let sourceDocument = PDFDocument(data: data) else {
            throw ExportError.printFailed
        }
        var paperSize = printInfo.paperSize
        if printInfo.orientation == .landscape, paperSize.width < paperSize.height {
            paperSize = NSSize(width: paperSize.height, height: paperSize.width)
        } else if printInfo.orientation == .portrait, paperSize.width > paperSize.height {
            paperSize = NSSize(width: paperSize.height, height: paperSize.width)
        }
        let printableWidth = paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let printableHeight = paperSize.height - printInfo.topMargin - printInfo.bottomMargin
        guard paperSize.width.isFinite, paperSize.height.isFinite, printableWidth.isFinite, printableHeight.isFinite,
              paperSize.width > 0, paperSize.height > 0, printableWidth > 0, printableHeight > 0 else {
            throw ExportError.invalidOptions
        }
        struct Slice {
            let sourcePage: Int
            let sourceBounds: CGRect
            let sourceRect: CGRect
            let destinationPage: Int
            let scale: CGFloat
        }
        var slices: [Slice] = []
        for sourceIndex in 0..<source.numberOfPages {
            guard let page = source.page(at: sourceIndex + 1) else { throw ExportError.printFailed }
            let bounds = page.getBoxRect(.mediaBox)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                throw ExportError.printFailed
            }
            let scale = printableWidth / bounds.width
            let sourceHeight = printableHeight / scale
            let count = max(1, Int(ceil(bounds.height / sourceHeight)))
            for index in 0..<count {
                let maximumY = bounds.maxY - CGFloat(index) * sourceHeight
                let minimumY = max(bounds.minY, maximumY - sourceHeight)
                slices.append(Slice(sourcePage: sourceIndex, sourceBounds: bounds,
                                    sourceRect: CGRect(x: bounds.minX, y: minimumY, width: bounds.width,
                                                       height: maximumY - minimumY),
                                    destinationPage: slices.count, scale: scale))
            }
        }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { throw ExportError.printFailed }
        var mediaBox = CGRect(origin: .zero, size: paperSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw ExportError.printFailed }
        let printableBounds = CGRect(x: printInfo.leftMargin, y: printInfo.bottomMargin,
                                     width: printableWidth, height: printableHeight)
        for slice in slices {
            guard let page = source.page(at: slice.sourcePage + 1) else { throw ExportError.printFailed }
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            context.saveGState()
            context.clip(to: printableBounds)
            context.translateBy(x: printableBounds.minX, y: printableBounds.minY)
            context.scaleBy(x: slice.scale, y: slice.scale)
            context.translateBy(x: -slice.sourceBounds.minX, y: -slice.sourceRect.minY)
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        guard let paginated = PDFDocument(data: output as Data), paginated.pageCount == slices.count else {
            throw ExportError.printFailed
        }
        func destination(for sourcePage: Int, point: CGPoint) -> PDFDestination? {
            guard let slice = slices.first(where: { $0.sourcePage == sourcePage && point.y >= $0.sourceRect.minY && point.y <= $0.sourceRect.maxY }),
                  let page = paginated.page(at: slice.destinationPage) else { return nil }
            let transformed = CGPoint(x: printableBounds.minX + (point.x - slice.sourceBounds.minX) * slice.scale,
                                      y: printableBounds.minY + (point.y - slice.sourceRect.minY) * slice.scale)
            return PDFDestination(page: page, at: transformed)
        }
        for slice in slices {
            guard let sourcePage = sourceDocument.page(at: slice.sourcePage),
                  let destinationPage = paginated.page(at: slice.destinationPage) else { throw ExportError.printFailed }
            for annotation in sourcePage.annotations {
                let intersection = annotation.bounds.intersection(slice.sourceRect)
                guard !intersection.isNull, !intersection.isEmpty else { continue }
                let bounds = CGRect(x: printableBounds.minX + (intersection.minX - slice.sourceBounds.minX) * slice.scale,
                                    y: printableBounds.minY + (intersection.minY - slice.sourceRect.minY) * slice.scale,
                                    width: intersection.width * slice.scale, height: intersection.height * slice.scale)
                let copy = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
                copy.url = annotation.url
                copy.contents = annotation.contents
                copy.shouldPrint = annotation.shouldPrint
                if let target = annotation.destination, let targetPage = target.page {
                    let targetIndex = sourceDocument.index(for: targetPage)
                    copy.destination = destination(for: targetIndex, point: target.point)
                }
                destinationPage.addAnnotation(copy)
            }
        }
        guard let result = paginated.dataRepresentation(), !result.isEmpty else { throw ExportError.printFailed }
        return result
    }

    @objc private func printDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printOperation = nil
        guard !cancelled, isCurrent() else { finish(.failure(ExportError.cancelled)); return }
        if let pendingPrintError { finish(.failure(pendingPrintError)); return }
        guard success else { finish(.failure(ExportError.printFailed)); return }
        if printingProcessedPDF {
            spoolDocument = nil
            if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
            temporaryDirectory = nil
            finish(.success(.printed))
            return
        }
        if case .printJob = mode, temporaryDirectory == nil { finish(.success(.printed)); return }
        guard let output = temporaryDirectory?.appendingPathComponent("output.pdf"),
              let pdf = PDFDocument(url: output), pdf.pageCount > 0 else {
            finish(.failure(ExportError.printFailed)); return
        }
        do {
            let bookmarked = try addBookmarks(to: pdf, original: output)
            let prepared: URL
            if metadata.attributes.isEmpty && headers.header.isEmpty && headers.footer.isEmpty && !headers.allowDocumentOverrides { prepared = bookmarked }
            else {
                guard let document = PDFDocument(url: bookmarked) else { throw ExportError.printFailed }
                var attributes = document.documentAttributes ?? [:]
                for (key, value) in metadata.attributes { attributes[key] = value }
                document.documentAttributes = attributes
                try addHeaders(to: document)
                prepared = output.deletingLastPathComponent().appendingPathComponent("metadata.pdf")
                guard document.write(to: prepared) else { throw ExportError.printFailed }
            }
            if let info = spoolInfo {
                guard let window, let document = PDFDocument(url: prepared) else { throw ExportError.printFailed }
                info.dictionary()[NSPrintInfo.AttributeKey.allPages] = NSNumber(value: true)
                guard let operation = document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false) else { throw ExportError.printFailed }
                operation.showsPrintPanel = false
                operation.showsProgressPanel = false
                operation.canSpawnSeparateThread = false
                spoolDocument = document
                printingProcessedPDF = true
                printOperation = operation
                printLifetime = self
                operation.runModal(for: window, delegate: self, didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
            } else {
                finish(.success(.file(PandocExportResult(preparedURL: prepared, diagnostics: ""))))
            }
        } catch { finish(.failure(error)) }
    }

    private func addHeaders(to pdf: PDFDocument) throws {
        let header = headers.allowDocumentOverrides ? metadata.variables["typora-header"] ?? metadata.variables["header"] ?? headers.header : headers.header
        let footer = headers.allowDocumentOverrides ? metadata.variables["typora-footer"] ?? metadata.variables["footer"] ?? headers.footer : headers.footer
        guard !header.isEmpty || !footer.isEmpty else { return }
        var variables = metadata.variables
        if let destination {
            variables["outputPath"] = destination.path
            variables["outputFileName"] = destination.deletingPathExtension().lastPathComponent
            variables["outputFileFullName"] = destination.lastPathComponent
        }
        if let sourceURL {
            variables["currentPath"] = sourceURL.path
            variables["currentFolder"] = sourceURL.deletingLastPathComponent().path
            variables["currentFileName"] = sourceURL.deletingPathExtension().lastPathComponent
            variables["currentFileFullName"] = sourceURL.lastPathComponent
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        variables["today"] = formatter.string(from: Date())
        let pattern = try NSRegularExpression(pattern: "\\$\\{([^}]+)\\}")
        func expand(_ template: String, page: Int) throws -> String {
            var values = variables
            values["pageNo"] = String(page)
            values["pageCount"] = String(pdf.pageCount)
            values["totalPages"] = String(pdf.pageCount)
            let result = NSMutableString(string: template)
            for match in pattern.matches(in: template, range: NSRange(location: 0, length: (template as NSString).length)).reversed() {
                let key = (template as NSString).substring(with: match.range(at: 1))
                guard let value = values[key] else { throw ExportError.invalidMetadata }
                result.replaceCharacters(in: match.range, with: value)
            }
            return result as String
        }
        let font = NSFont.systemFont(ofSize: 10)
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index), page.rotation == 0 else { throw ExportError.printFailed }
            let bounds = page.bounds(for: .mediaBox)
            for (template, y, height) in [(header, bounds.maxY - printMargins.top, printMargins.top),
                                          (footer, bounds.minY, printMargins.bottom)] where !template.isEmpty {
                let text = try expand(template, page: index + 1)
                let available = NSRect(x: bounds.minX + printMargins.left, y: y,
                                       width: bounds.width - printMargins.left - printMargins.right, height: height)
                let required = (text as NSString).size(withAttributes: [.font: font])
                guard available.width > 0, available.height > 0,
                      required.width <= available.width, required.height <= available.height else { throw ExportError.invalidOptions }
                let annotation = PDFAnnotation(bounds: available, forType: .freeText, withProperties: nil)
                annotation.contents = text
                annotation.font = font
                annotation.fontColor = .black
                annotation.color = .clear
                annotation.shouldPrint = true
                page.addAnnotation(annotation)
            }
        }
    }

    private func addBookmarks(to pdf: PDFDocument, original: URL) throws -> URL {
        guard !bookmarkHeadings.isEmpty || !mathLinkMarkers.isEmpty || requestedPages != nil else { return original }
        let originalCount = pdf.pageCount
        let first = requestedPages.map { $0.lowerBound - 1 } ?? 0
        let last = min(requestedPages.map { $0.upperBound - 1 } ?? (originalCount - 1), originalCount - 1)
        guard first >= 0, first <= last else { throw ExportError.printFailed }
        let expected = Set(bookmarkHeadings.map(\.url) + mathLinkMarkers.flatMap { [$0.source, $0.target] })
        var locations: [URL: [(Int, PDFPage, CGRect)]] = [:]
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index), page.rotation == 0 else { throw ExportError.bookmarksFailed }
            for annotation in page.annotations {
                guard let url = annotation.url, expected.contains(url) else { continue }
                locations[url, default: []].append((index, page, annotation.bounds))
                page.removeAnnotation(annotation)
            }
        }
        for heading in bookmarkHeadings {
            guard let entries = locations[heading.url], !entries.isEmpty else { throw ExportError.bookmarksFailed }
        }
        for marker in mathLinkMarkers {
            guard let sources = locations[marker.source], !sources.isEmpty,
                  let targets = locations[marker.target], !targets.isEmpty,
                  (sources + targets).allSatisfy({ !$0.2.isEmpty && $0.2.minX.isFinite && $0.2.maxY.isFinite }) else {
                throw ExportError.bookmarksFailed
            }
        }
        if first != 0 || last != originalCount - 1 {
            for index in (0..<originalCount).reversed() where index < first || index > last { pdf.removePage(at: index) }
        }
        var expectedMathLinks: [(Int, CGRect, Int, CGPoint)] = []
        for marker in mathLinkMarkers {
            guard let destination = locations[marker.target]?.first(where: { (first...last).contains($0.0) }) else { continue }
            for source in locations[marker.source] ?? [] where (first...last).contains(source.0) {
                let annotation = PDFAnnotation(bounds: source.2, forType: .link, withProperties: nil)
                annotation.destination = PDFDestination(page: destination.1, at: CGPoint(x: destination.2.minX, y: destination.2.maxY))
                annotation.color = .clear
                source.1.addAnnotation(annotation)
                expectedMathLinks.append((source.0 - first, source.2, destination.0 - first,
                                          CGPoint(x: destination.2.minX, y: destination.2.maxY)))
            }
        }
        let root = PDFOutline()
        var ancestors: [(Int, PDFOutline)] = []
        var selectedTitles: [String] = []
        for heading in bookmarkHeadings {
            let entries = (locations[heading.url] ?? []).filter { $0.0 >= first && $0.0 <= last }
            if entries.isEmpty { continue }
            let sorted = entries.sorted {
                if $0.0 != $1.0 { return $0.0 < $1.0 }
                if $0.2.maxY != $1.2.maxY { return $0.2.maxY > $1.2.maxY }
                return $0.2.minX < $1.2.minX
            }
            let position = sorted[0]
            guard !position.2.isEmpty, position.2.minX.isFinite, position.2.maxY.isFinite else { throw ExportError.bookmarksFailed }
            let outline = PDFOutline()
            outline.label = heading.title
            outline.destination = PDFDestination(page: position.1, at: CGPoint(x: position.2.minX, y: position.2.maxY))
            while let last = ancestors.last, last.0 >= heading.level { ancestors.removeLast() }
            let parent = ancestors.last?.1 ?? root
            parent.insertChild(outline, at: parent.numberOfChildren)
            ancestors.append((heading.level, outline))
            selectedTitles.append(heading.title)
        }
        pdf.outlineRoot = selectedTitles.isEmpty ? nil : root
        let output = original.deletingLastPathComponent().appendingPathComponent("bookmarked.pdf")
        guard pdf.write(to: output), let verified = PDFDocument(url: output),
              verified.pageCount == last - first + 1 else {
            throw ExportError.bookmarksFailed
        }
        var labels: [String] = []
        func collect(_ parent: PDFOutline) throws {
            for index in 0..<parent.numberOfChildren {
                guard let child = parent.child(at: index), let page = child.destination?.page,
                      page.document === verified else { throw ExportError.bookmarksFailed }
                labels.append(child.label ?? "")
                try collect(child)
            }
        }
        if let verifiedRoot = verified.outlineRoot { try collect(verifiedRoot) }
        guard labels == selectedTitles else { throw ExportError.bookmarksFailed }
        for index in 0..<verified.pageCount {
            guard let page = verified.page(at: index),
                  !page.annotations.contains(where: { $0.url.map(expected.contains) ?? false }) else {
                throw ExportError.bookmarksFailed
            }
        }
        for (sourceIndex, bounds, targetIndex, point) in expectedMathLinks {
            guard let page = verified.page(at: sourceIndex),
                  page.annotations.contains(where: { annotation in
                      guard let destination = annotation.destination, let target = destination.page,
                            verified.index(for: target) == targetIndex else { return false }
                      return abs(annotation.bounds.minX - bounds.minX) < 0.1 && abs(annotation.bounds.minY - bounds.minY) < 0.1 &&
                          abs(annotation.bounds.width - bounds.width) < 0.1 && abs(annotation.bounds.height - bounds.height) < 0.1 &&
                          abs(destination.point.x - point.x) < 0.1 && abs(destination.point.y - point.y) < 0.1
                  }) else { throw ExportError.bookmarksFailed }
        }
        return output
    }

    private func finish(_ result: Result<Output, Error>) {
        guard let completion else { return }
        // A WebKit failure can arrive while AppKit is still writing the file.
        // Keep the delegate and temporary file alive until the print callback.
        if printOperation != nil {
            if case let .failure(error) = result, pendingPrintError == nil { pendingPrintError = error }
            return
        }
        let previousLegacy = legacyService
        legacyService = nil
        legacyToken = nil
        previousLegacy?.cancel()
        self.completion = nil
        let previousMath = mathService
        mathService = nil
        mathToken = nil
        previousMath?.cancel()
        defer { printLifetime = nil }
        webView?.navigationDelegate = nil
        webView = nil
        spoolDocument = nil
        spoolInfo = nil
        renderTask = nil
        metadataTask?.cancel()
        metadataTask = nil
        if case .failure = result, let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        completion(result)
    }
}
