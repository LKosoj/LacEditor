import Foundation
import Security
import Yams
import Darwin
import ImageIO
import UniformTypeIdentifiers
import SwiftSoup
import AppKit
import WebKit
import cmark_gfm
import cmark_gfm_extensions

struct PicListKeychainStore {
    private let namespace: String
    init(namespace: String = AppEnvironment.dataDirectoryName) { self.namespace = namespace }

    static func endpointWithoutKey(_ text: String) -> (endpoint: String, key: String?)? {
        guard var parts = URLComponents(string: text) else { return nil }
        let items = parts.queryItems ?? []
        let keys = items.filter { $0.name.lowercased() == "key" }
        let remaining = items.filter { $0.name.lowercased() != "key" }
        if !keys.isEmpty { parts.queryItems = remaining.isEmpty ? nil : remaining }
        guard let endpoint = parts.string else { return nil }
        return (endpoint, keys.isEmpty ? nil : keys.compactMap(\.value).last ?? "")
    }

    private func query(_ endpoint: String) throws -> [String: Any] {
        guard let url = URL(string: endpoint), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw MarkdownImageUploadService.UploadError.invalidInput
        }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "\(namespace).PicList",
                kSecAttrAccount as String: url.absoluteString]
    }

    func load(endpoint: String) throws -> String? {
        var item = try query(endpoint)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw MarkdownImageUploadService.UploadError.keychain }
        return value
    }

    func save(_ key: String, endpoint: String) throws {
        let item = try query(endpoint)
        if key.isEmpty {
            let status = SecItemDelete(item as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw MarkdownImageUploadService.UploadError.keychain }
            return
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var added = item
            added[kSecValueData as String] = data
            guard SecItemAdd(added as CFDictionary, nil) == errSecSuccess else { throw MarkdownImageUploadService.UploadError.keychain }
        } else if status != errSecSuccess { throw MarkdownImageUploadService.UploadError.keychain }
    }
}

@MainActor
final class MarkdownSVGRenderService: NSObject, WKNavigationDelegate {
    private(set) var intrinsicSize: CGSize?
    private var webView: WKWebView?
    private var navigation: WKNavigation?
    private var completion: ((NSImage?) -> Void)?
    private let encoded: String
    private let fragment: String
    private let width: CGFloat
    private let configuration: WKWebViewConfiguration

    init(encoded: String, fragment: String = "", width: CGFloat, configuration: WKWebViewConfiguration = WKWebViewConfiguration(), completion: @escaping (NSImage?) -> Void) {
        self.encoded = encoded
        self.fragment = fragment
        self.width = width
        self.configuration = configuration
        self.completion = completion
    }

    func start() {
        guard completion != nil, webView == nil else { return }
        guard width.isFinite, width > 0 else { finish(nil); return }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: ceil(width), height: 1), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'"><style>html,body{margin:0;padding:0}img{display:block;max-width:100%;height:auto}</style></head><body><img></body></html>
        """
        navigation = view.loadHTMLString(html, baseURL: nil)
        if navigation == nil { finish(nil) }
    }

    func cancel() { webView?.stopLoading(); finish(nil) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation, completion != nil else { return }
        self.navigation = nil
        let script = """
        const image = document.querySelector('img');
        image.src = 'data:image/svg+xml;base64,' + encoded + fragment;
        await image.decode();
        const rect = image.getBoundingClientRect();
        if (!(rect.width > 0 && rect.height > 0)) throw new Error('Invalid image size');
        const canvas = document.createElement('canvas');
        const scale = window.devicePixelRatio || 1;
        canvas.width = Math.ceil(rect.width * scale);
        canvas.height = Math.ceil(rect.height * scale);
        canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
        return [rect.width, rect.height, canvas.toDataURL('image/png'), image.naturalWidth, image.naturalHeight];
        """
        webView.callAsyncJavaScript(script, arguments: ["encoded": encoded, "fragment": fragment], in: nil, in: .defaultClient) { [weak self, weak webView] result in
            guard let self, let webView, self.completion != nil else { return }
            guard case let .success(value) = result, let values = value as? [Any], values.count == 5,
                  let measuredWidth = values[0] as? NSNumber, let measuredHeight = values[1] as? NSNumber,
                  let uri = values[2] as? String, uri.hasPrefix("data:image/png;base64,"),
                  let naturalWidth = values[3] as? NSNumber, let naturalHeight = values[4] as? NSNumber else { self.finish(nil); return }
            let width = measuredWidth.doubleValue, height = measuredHeight.doubleValue
            guard width.isFinite, height.isFinite, width > 0, height > 0, width <= Double(webView.bounds.width),
                  width < Double(Int.max), height < Double(Int.max) else { self.finish(nil); return }
            let natural = CGSize(width: naturalWidth.doubleValue, height: naturalHeight.doubleValue)
            self.intrinsicSize = natural.width.isFinite && natural.height.isFinite && natural.width > 0 && natural.height > 0
                ? natural : CGSize(width: width, height: height)
            guard let data = Data(base64Encoded: String(uri.dropFirst("data:image/png;base64,".count))),
                  let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide >= Int(ceil(width)), bitmap.pixelsHigh >= Int(ceil(height)) else { self.finish(nil); return }
            let image = NSImage(size: NSSize(width: CGFloat(width), height: CGFloat(height)))
            image.addRepresentation(bitmap)
            self.finish(image)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(nil) }

    private func finish(_ image: NSImage?) {
        guard let completion else { return }
        self.completion = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        completion(image)
    }
}

enum MarkdownImageUploadService {
    static func fragmentSuffix(_ address: String) -> String {
        guard let fragment = URLComponents(string: address)?.percentEncodedFragment else { return "" }
        return "#" + fragment
    }

    static func dataURI(_ payload: Payload, address: String) -> String {
        "data:\(payload.mime);base64,\(payload.data.base64EncodedString())" + fragmentSuffix(address)
    }

    static func remoteImageDataURIs(_ addresses: [String], session: URLSession = .shared) async throws -> [Data: String] {
        var result: [Data: String] = [:]
        var downloaded: [String: Payload] = [:]
        var failed = Set<String>()
        for address in addresses {
            try Task.checkCancellation()
            guard let url = URL(string: address),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { continue }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            let key = components?.url?.absoluteString ?? url.absoluteString
            if failed.contains(key) { continue }
            let payload: Payload
            if let cached = downloaded[key] { payload = cached }
            else {
                do { payload = try await download(url, session: session); downloaded[key] = payload }
                catch {
                    try Task.checkCancellation()
                    failed.insert(key)
                    continue
                }
            }
            result[Data(address.utf8)] = dataURI(payload, address: address)
        }
        try Task.checkCancellation()
        return result
    }
    private final class SVGRootValidator: NSObject, XMLParserDelegate {
        private(set) var validRoot = false
        private var sawRoot = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard !sawRoot else { return }
            sawRoot = true
            validRoot = elementName == "svg" && namespaceURI == "http://www.w3.org/2000/svg"
        }
    }

    private final class InlineSVGValidator: NSObject, XMLParserDelegate {
        let isCancelled: () -> Bool
        private(set) var valid = true
        private(set) var hasRoot = false
        private(set) var hasNamespace = false
        private var depth = 0
        private let elements: Set<String> = ["svg", "g", "rect", "circle", "ellipse", "line", "polyline", "polygon", "path"]
        private let common: Set<String> = ["fill", "stroke", "stroke-width", "opacity", "fill-opacity", "stroke-opacity", "transform"]
        private let geometry: Set<String> = ["x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "width", "height", "points", "d"]

        init(isCancelled: @escaping () -> Bool) { self.isCancelled = isCancelled }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            guard !isCancelled(), elements.contains(name), (depth == 0) == (name == "svg") else { valid = false; parser.abortParsing(); return }
            if depth == 0 {
                hasRoot = true
                if let namespace = attributes["xmlns"] {
                    guard namespace == "http://www.w3.org/2000/svg" else { valid = false; parser.abortParsing(); return }
                    hasNamespace = true
                }
                for key in ["width", "height"] {
                    guard let value = attributes[key],
                          value.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
                          let number = Double(value), number.isFinite, number > 0 else {
                        valid = false; parser.abortParsing(); return
                    }
                }
            }
            for (key, value) in attributes {
                if isCancelled() { valid = false; parser.abortParsing(); return }
                let rootAttribute = depth == 0 && ["xmlns", "viewBox", "width", "height"].contains(key)
                guard rootAttribute || common.contains(key) || (depth > 0 && geometry.contains(key)) else { valid = false; parser.abortParsing(); return }
                let lower = value.lowercased()
                guard !lower.contains("%"), !lower.contains("currentcolor"), !lower.contains("inherit"),
                      !lower.contains("var("), !lower.contains("url(") else { valid = false; parser.abortParsing(); return }
                if key == "fill" || key == "stroke" {
                    let color = lower.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard ["none", "red", "black", "white"].contains(color) ||
                            color.range(of: #"^#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$"#, options: .regularExpression) != nil else {
                        valid = false; parser.abortParsing(); return
                    }
                }
            }
            depth += 1
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { depth -= 1 }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isCancelled() || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { valid = false; parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            valid = false; parser.abortParsing()
        }
    }

    static func standaloneSVGData(_ literal: String, isCancelled: () -> Bool = { false }) -> Data? {
        guard !isCancelled(), literal.hasPrefix("<svg"), !literal.contains("<!"), let data = literal.data(using: .utf8) else { return nil }
        return withoutActuallyEscaping(isCancelled) { cancellation in
            let parser = XMLParser(data: data), validator = InlineSVGValidator(isCancelled: cancellation)
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            parser.delegate = validator
            guard parser.parse(), validator.valid, validator.hasRoot, !cancellation() else { return nil }
            if validator.hasNamespace { return data }
            return ("<svg xmlns=\"http://www.w3.org/2000/svg\"" + String(literal.dropFirst(4))).data(using: .utf8)
        }
    }
    // WHATWG HTML Standard entities.json (https://html.spec.whatwg.org/entities.json),
    // legacy names without a semicolon. Source-code use is BSD 3-Clause:
    // https://whatwg.org/ipr-policy#copyright-license-for-whatwg-publications
    private static let legacyHTMLReferences = Set("AElig AMP Aacute Acirc Agrave Aring Atilde Auml COPY Ccedil ETH Eacute Ecirc Egrave Euml GT Iacute Icirc Igrave Iuml LT Ntilde Oacute Ocirc Ograve Oslash Otilde Ouml QUOT REG THORN Uacute Ucirc Ugrave Uuml Yacute aacute acirc acute aelig agrave amp aring atilde auml brvbar ccedil cedil cent copy curren deg divide eacute ecirc egrave eth euml frac12 frac14 frac34 gt iacute icirc iexcl igrave iquest iuml laquo lt macr micro middot nbsp not ntilde oacute ocirc ograve ordf ordm oslash otilde ouml para plusmn pound quot raquo reg sect shy sup1 sup2 sup3 szlig thorn times uacute ucirc ugrave uml uuml yacute yen yuml".split(separator: " ").map(String.init))
    private static let htmlNumericReplacements: [UInt64: UInt64] = [
        0x80: 0x20ac, 0x82: 0x201a, 0x83: 0x0192, 0x84: 0x201e, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
        0x88: 0x02c6, 0x89: 0x2030, 0x8a: 0x0160, 0x8b: 0x2039, 0x8c: 0x0152, 0x8e: 0x017d,
        0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201c, 0x94: 0x201d, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
        0x98: 0x02dc, 0x99: 0x2122, 0x9a: 0x0161, 0x9b: 0x203a, 0x9c: 0x0153, 0x9e: 0x017e, 0x9f: 0x0178
    ]
    enum UploadError: LocalizedError, Equatable {
        case unsupportedImage
        case invalidInput
        case invalidResult
        case commandFailed(String)
        case serverFailed
        case invalidPolicy
        case keychain
        case picListFinalization(String)
        case picListPartial([String], String)
        case uPicPartial([String], String)
        case picseePartial([String], String)
        case iPicPartial([String], String)
        case iPicTimedOut
        case uploadedFragmentConflict([String])

        var reportsUploadedResources: Bool {
            switch self {
            case .picListFinalization, .picListPartial, .uPicPartial, .picseePartial, .iPicPartial, .iPicTimedOut, .uploadedFragmentConflict: true
            default: false
            }
        }

        var errorDescription: String? {
            switch self {
            case .unsupportedImage: L10n.tr("暂不支持此图片语法")
            case .invalidInput: L10n.tr("图片或上传设置无效")
            case .invalidResult: L10n.tr("上传结果不完整或地址无效")
            case let .commandFailed(details): L10n.tr("上传程序失败：%@", details)
            case .serverFailed: L10n.tr("上传服务返回错误")
            case .invalidPolicy: L10n.tr("无法读取图片插入的文档设置")
            case .keychain: L10n.tr("无法访问 PicList 密钥")
            case let .picListFinalization(id): L10n.tr("PicList 已上传，但需要完成处理：%@", id)
            case let .picListPartial(urls, reason): L10n.tr("PicList 已上传部分文件：%@；%@", urls.joined(separator: "\n"), reason)
            case let .uPicPartial(urls, reason): L10n.tr("uPic 已上传部分文件：%@；%@", urls.joined(separator: "\n"), reason)
            case let .picseePartial(urls, reason): L10n.tr("Picsee 已上传部分文件：%@；%@", urls.joined(separator: "\n"), reason)
            case let .iPicPartial(urls, reason): L10n.tr("iPic 已上传部分文件：%@；%@", urls.joined(separator: "\n"), reason)
            case .iPicTimedOut: L10n.tr("iPic 未返回结果；上传可能仍在进行。")
            case let .uploadedFragmentConflict(urls): L10n.tr("上传结果的图片片段不同，未修改文档：%@", urls.joined(separator: "\n"))
            }
        }
    }

    struct Image: Equatable {
        enum Syntax: Equatable { case markdown, reference, html(quote: UInt16?) }
        struct InlineReference: Equatable {
            let range: NSRange
            let original: String
            let opening: String
            let title: String
            let titleProbe: NSRange?
        }
        let range: NSRange
        let addressRange: NSRange
        let rawAddress: String
        let address: String
        let syntax: Syntax
        var inlineReferences: [InlineReference] = []
        var htmlXML: String? = nil
    }

    // Called in source order for every cmark HTML node in the current tree.
    struct HTMLContext {
        private var rawContext: String?
        private var scriptFilter = MarkdownHTMLMediaService.SourceHTMLFilter()
        private var scriptCursor: Int?
        var inRawContext: Bool { rawContext != nil }
        var inScriptContext: Bool { rawContext == "script" }

        mutating func invalidate() { rawContext = "plaintext"; scriptCursor = nil }

        mutating func consume(source: NSString, range: NSRange, isCancelled: () -> Bool = { false },
                              confirmedTag: ((NSRange, String, Bool) -> Void)? = nil,
                              confirmedRawClose: ((NSRange, String) -> Void)? = nil) -> Bool {
            guard !isCancelled(), range.location >= 0, range.length >= 0, range.location <= source.length,
                  range.length <= source.length - range.location else { invalidate(); return false }
            let startedOutside = rawContext == nil
            guard MarkdownImageUploadService.htmlImages(in: source, range: range, rawContext: &rawContext,
                scriptFilter: &scriptFilter, scriptCursor: &scriptCursor, contextOnly: true,
                isCancelled: isCancelled, confirmedTag: confirmedTag, confirmedRawClose: confirmedRawClose) != nil else {
                invalidate(); return false
            }
            return startedOutside && rawContext == nil && !isCancelled()
        }
    }

    static func textareaContents(in source: String, isCancelled: () -> Bool) throws -> [NSRange] {
        guard source.range(of: "<textarea", options: .caseInsensitive) != nil else { return [] }
        let text = source as NSString
        let input = MarkdownPresentationParser.maskedFrontMatter(source, frontMatter: MarkdownPresentationParser.frontMatter(source))
        guard let result = MarkdownMathExtension.withDocument(input, options: CMARK_OPT_SMART | CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS | CMARK_OPT_FOOTNOTES, { root, _, _ in
            let mapping = MarkdownPresentationParser.Source(source, root: root, isCancelled: isCancelled)
            var context = HTMLContext(), opening: Int?, ranges: [NSRange] = [], valid = true
            func visit(_ node: OpaquePointer) {
                guard valid, !isCancelled() else { valid = false; return }
                if let name = cmark_node_get_type_string(node), ["html_inline", "html_block"].contains(String(cString: name)) {
                    guard let range = mapping.range(node), MarkdownPresentationParser.htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled) else {
                        valid = false; return
                    }
                    _ = context.consume(source: text, range: range, isCancelled: isCancelled, confirmedTag: { tag, name, closing in
                        if name == "textarea" && !closing { opening = NSMaxRange(tag) }
                    }, confirmedRawClose: { tag, name in
                        if name == "textarea", let start = opening, start <= tag.location {
                            ranges.append(NSRange(location: start, length: tag.location - start))
                            opening = nil
                        }
                    })
                }
                var child = cmark_node_first_child(node)
                while let current = child, valid, !isCancelled() { visit(current); child = cmark_node_next(current) }
            }
            visit(root)
            return valid && opening == nil ? ranges : nil
        }) else { throw UploadError.invalidInput }
        if isCancelled() { throw CancellationError() }
        guard let result else { throw UploadError.invalidInput }
        return result
    }

    static func mediaSources(in source: String, isCancelled: () -> Bool) throws -> [Image] {
        guard source.range(of: "<audio", options: .caseInsensitive) != nil || source.range(of: "<video", options: .caseInsensitive) != nil else { return [] }
        let text = source as NSString
        let input = MarkdownPresentationParser.maskedFrontMatter(source, frontMatter: MarkdownPresentationParser.frontMatter(source))
        guard let result = MarkdownMathExtension.withDocument(input, options: CMARK_OPT_SMART | CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS | CMARK_OPT_FOOTNOTES, { root, _, _ in
            let mapping = MarkdownPresentationParser.Source(source, root: root, isCancelled: isCancelled)
            var context = HTMLContext(), found: [Image] = [], valid = true, templateDepth = 0
            var pendingMedia: (name: String, parent: OpaquePointer, end: Int, sources: [Image], nested: [String])?
            func visit(_ node: OpaquePointer) {
                guard valid, !isCancelled() else { valid = false; return }
                if let pointer = cmark_node_get_type_string(node) {
                    let kind = String(cString: pointer)
                    if kind == "html_inline" || kind == "html_block" {
                        guard let range = mapping.range(node), MarkdownPresentationParser.htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled) else {
                            context.invalidate(); return
                        }
                        let outside = !context.inRawContext
                        let block = kind == "html_block" && outside && templateDepth == 0 ? text.substring(with: range) : ""
                        let hasMedia = block.range(of: "<audio", options: .caseInsensitive) != nil || block.range(of: "<video", options: .caseInsensitive) != nil
                        var candidates: [(NSRange, String, Image)] = []
                        _ = context.consume(source: text, range: range, isCancelled: isCancelled, confirmedTag: { tag, name, closing in
                            if name == "template" {
                                if kind == "html_inline", var pending = pendingMedia, pending.parent == cmark_node_parent(node) {
                                    if closing && pending.nested.last == name { pending.nested.removeLast() }
                                    else if !closing { pending.nested.append(name) }
                                    else { pendingMedia = nil; return }
                                    pending.end = NSMaxRange(tag)
                                    pendingMedia = pending
                                } else { pendingMedia = nil }
                                if closing { templateDepth = max(0, templateDepth - 1) }
                                else { templateDepth += 1 }
                                return
                            }
                            if kind == "html_inline", templateDepth == 0, let parent = cmark_node_parent(node) {
                                func orderedGap(from start: Int) -> Bool {
                                    start <= tag.location && !isCancelled()
                                }
                                if !closing && ["audio", "video"].contains(name) {
                                    pendingMedia = nil
                                    var missingSource = false
                                    if let value = htmlImage(in: text, range: tag, htmlForExport: false, isCancelled: isCancelled, tagName: name,
                                                             missingSource: { missingSource = true }) {
                                        found.append(value)
                                    } else if missingSource { pendingMedia = (name, parent, NSMaxRange(tag), [], []) }
                                } else if !closing && name == "source", var pending = pendingMedia,
                                          pending.parent == parent, pending.nested.isEmpty, orderedGap(from: pending.end),
                                          let value = htmlImage(in: text, range: tag, htmlForExport: false, isCancelled: isCancelled, tagName: name) {
                                    pending.sources.append(value)
                                    pending.end = NSMaxRange(tag)
                                    pendingMedia = pending
                                } else if closing, let pending = pendingMedia, name == pending.name,
                                          pending.parent == parent, pending.nested.isEmpty, orderedGap(from: pending.end) {
                                    found.append(contentsOf: pending.sources)
                                    pendingMedia = nil
                                } else if var pending = pendingMedia, pending.parent == parent, orderedGap(from: pending.end) {
                                    if closing && pending.nested.last == name { pending.nested.removeLast() }
                                    else if !closing && !["br", "hr", "img", "input", "source", "wbr", "area", "base", "embed", "link", "meta", "param", "track"].contains(name) { pending.nested.append(name) }
                                    else if closing { pendingMedia = nil; return }
                                    pending.end = NSMaxRange(tag)
                                    pendingMedia = pending
                                } else { pendingMedia = nil }
                            }
                            guard hasMedia, !closing, ["audio", "video", "source"].contains(name),
                                  let value = htmlImage(in: text, range: tag, htmlForExport: false, isCancelled: isCancelled, tagName: name) else { return }
                            candidates.append((tag, name, value))
                        }, confirmedRawClose: { tag, name in
                            if kind == "html_inline", var pending = pendingMedia,
                               pending.parent == cmark_node_parent(node), pending.nested.last == name {
                                pending.nested.removeLast()
                                pending.end = NSMaxRange(tag)
                                pendingMedia = pending
                            }
                        })
                        if hasMedia, !context.inRawContext, !candidates.isEmpty {
                            var marker: String
                            repeat { marker = "data-lac-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
                            while block.localizedCaseInsensitiveContains(marker)
                            let tagged = NSMutableString(string: block)
                            for index in candidates.indices.reversed() {
                                let (tag, name, _) = candidates[index]
                                let offset = tag.location - range.location + 1 + (name as NSString).length
                                tagged.insert(" \(marker)=\"\(index)\"", at: offset)
                            }
                            do {
                                let document = try SwiftSoup.parseBodyFragment(tagged as String)
                                var stack: [(SwiftSoup.Node, Element?, Bool)] = [(document, nil, false)]
                                var seen = Set<Int>(), selected = Set<Int>(), validMarkers = true
                                while let (node, parent, forbidden) = stack.popLast() {
                                    if isCancelled() { valid = false; break }
                                    let element = node as? Element
                                    let name = element?.tagName().lowercased()
                                    let blocked = forbidden || ["template", "script", "style"].contains(name ?? "")
                                    if let element, element.hasAttr(marker) {
                                        guard let index = Int(try element.attr(marker)), candidates.indices.contains(index), seen.insert(index).inserted else {
                                            validMarkers = false; break
                                        }
                                        let (_, expectedName, image) = candidates[index]
                                        if !blocked, name == expectedName, let normalized = normalizeHTMLReferences(image.rawAddress, isCancelled: isCancelled),
                                           let decoded = decodeHTMLReferences(normalized), try element.attr("src").utf8.elementsEqual(decoded.utf8) {
                                            if name == "audio" || name == "video" { selected.insert(index) }
                                            else if name == "source", let parent, ["audio", "video"].contains(parent.tagName().lowercased()), !parent.hasAttr("src") { selected.insert(index) }
                                        }
                                    }
                                    for child in node.getChildNodes() { stack.append((child, element ?? parent, blocked)) }
                                }
                                if validMarkers && seen.count == candidates.count {
                                    found.append(contentsOf: candidates.indices.filter { selected.contains($0) }.map { candidates[$0].2 })
                                }
                            } catch { valid = false }
                        }
                    }
                }
                var child = cmark_node_first_child(node)
                while let current = child, valid, !isCancelled() { visit(current); child = cmark_node_next(current) }
            }
            visit(root)
            return valid ? found : nil
        }) else { throw UploadError.invalidInput }
        if isCancelled() { throw CancellationError() }
        guard let result else { throw UploadError.invalidInput }
        return result
    }

    static func mediaSource(in source: NSString, range: NSRange, name: String, isCancelled: () -> Bool) -> Image? {
        guard ["audio", "video", "source"].contains(name) else { return nil }
        return htmlImage(in: source, range: range, htmlForExport: false, isCancelled: isCancelled, tagName: name)
    }

    static func replacement(in source: String, images: [Image], urls: [URL], selection: NSRange,
                            isCancelled: () -> Bool = { false }, filePaths: Bool = false) throws -> MarkdownFormattingEdit {
        if isCancelled() { throw CancellationError() }
        guard !images.isEmpty, images.count == urls.count else { throw UploadError.invalidResult }
        let ns = source as NSString
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= ns.length, selection.length <= ns.length - selection.location else { throw UploadError.invalidInput }
        var replacements: [(NSRange, String)] = []
        var expectedAddresses: [String] = []
        func address(_ url: URL) -> String {
            guard filePaths && url.isFileURL, let parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
            return parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?" + $0 } ?? "") + (parts.percentEncodedFragment.map { "#" + $0 } ?? "")
        }
        for (image, originalURL) in zip(images, urls) {
            var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)
            let sourceFragment = URLComponents(string: image.address)?.percentEncodedFragment
            let returnedFragment = components?.percentEncodedFragment
            if let sourceFragment, let returnedFragment, sourceFragment != returnedFragment {
                throw UploadError.uploadedFragmentConflict(urls.map(\.absoluteString))
            }
            if returnedFragment == nil { components?.percentEncodedFragment = sourceFragment }
            guard let url = components?.url else { throw UploadError.invalidResult }
            guard NSMaxRange(image.addressRange) <= ns.length,
                  ns.substring(with: image.addressRange) == image.rawAddress else { throw UploadError.invalidInput }
            let value: String
            switch image.syntax {
            case .markdown, .reference:
                let expected = address(url).replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                expectedAddresses.append(expected)
                value = expected.replacingOccurrences(of: "&", with: "&amp;")
            case let .html(quote):
                let expected = address(url)
                expectedAddresses.append(expected)
                let escaped = expected.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
                value = quote == nil ? "\"" + escaped + "\"" : escaped
            }
            if image.inlineReferences.isEmpty { replacements.append((image.addressRange, value)) }
            else {
                for reference in image.inlineReferences {
                    guard NSMaxRange(reference.range) <= ns.length,
                          ns.substring(with: reference.range) == reference.original else { throw UploadError.invalidInput }
                    replacements.append((reference.range, reference.opening + "(<" + value + ">" + reference.title + ")"))
                }
            }
        }
        replacements.sort { $0.0.location < $1.0.location }
        guard let first = replacements.first, let last = replacements.last else { throw UploadError.invalidInput }
        let start = first.0.location, end = NSMaxRange(last.0)
        let range = NSRange(location: start, length: end - start)
        let changed = NSMutableString(string: "")
        var cursor = start
        for (address, value) in replacements {
            guard address.location >= cursor else { throw UploadError.invalidInput }
            changed.append(ns.substring(with: NSRange(location: cursor, length: address.location - cursor)))
            changed.append(value)
            cursor = NSMaxRange(address)
        }
        changed.append(ns.substring(with: NSRange(location: cursor, length: end - cursor)))
        let candidate = ns.replacingCharacters(in: range, with: changed as String)
        var changes = [0]
        for (address, value) in replacements { changes.append(changes.last! + (value as NSString).length - address.length) }
        func adjusted(_ offset: Int) -> Int {
            var low = 0, high = replacements.count
            while low < high {
                let mid = (low + high) / 2
                if replacements[mid].0.location <= offset { low = mid + 1 } else { high = mid }
            }
            guard low > 0 else { return offset }
            let (address, value) = replacements[low - 1]
            if offset <= NSMaxRange(address) {
                return address.location + changes[low - 1] + min(offset - address.location, (value as NSString).length)
            }
            return offset + changes[low]
        }
        let checked: [Image]
        if images.count == 1 && images[0].inlineReferences.count <= 1 {
            checked = try self.images(in: candidate, selection: NSRange(location: adjusted(images[0].range.location), length: 0),
                                      allowSharedReference: true, isCancelled: isCancelled)
        } else {
            checked = try self.images(in: candidate, allowSharedReference: true, isCancelled: isCancelled)
        }
        let checkedByLocation = Dictionary(checked.map { ($0.range.location, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, image) in images.enumerated() {
            if isCancelled() { throw CancellationError() }
            let wanted = expectedAddresses[index]
            let ranges = image.inlineReferences.isEmpty ? [image.range] : image.inlineReferences.map(\.range)
            for reference in ranges {
                guard checkedByLocation[adjusted(reference.location)]?.address == wanted else { throw UploadError.invalidResult }
            }
        }
        let selectionStart = adjusted(selection.location), selectionEnd = adjusted(NSMaxRange(selection))
        return MarkdownFormattingEdit(range: range, replacement: changed as String,
                                      selectionRange: NSRange(location: selectionStart, length: max(0, selectionEnd - selectionStart)))
    }

    // cmark's source columns are UTF-8 byte offsets, whereas AppKit uses UTF-16.
    static func images(in source: String, selection: NSRange? = nil, allowSharedReference: Bool = false,
                       isCancelled: () -> Bool = { false }, htmlForExport: Bool = false,
                       confirmedAudio: ((NSRange) -> Void)? = nil, confirmedVideo: ((NSRange) -> Void)? = nil,
                       confirmedInline: ((NSRange, String) -> Void)? = nil,
                       confirmedFrame: ((NSRange, MarkdownHTMLMediaService.EmbeddedFrame) -> Void)? = nil,
                       confirmedBlock: ((NSRange) -> Void)? = nil,
                       confirmedImage: ((OpaquePointer, Image) -> Void)? = nil,
                       confirmedHTMLTags: ((OpaquePointer, NSRange, [(NSRange, String, Bool)]) -> Void)? = nil,
                       root: OpaquePointer? = nil, sourceMapping: MarkdownPresentationParser.Source? = nil) throws -> [Image] {
        guard !source.utf8.contains(0) else { throw UploadError.invalidInput }
        let text = source as NSString
        var mapping: MarkdownPresentationParser.Source!
        if let selection {
            guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
                  selection.location <= text.length, selection.length <= text.length - selection.location else { throw UploadError.invalidInput }
        }
        var lines: [(Int, String)] = [], start = 0, offset = 0
        while offset < text.length {
            if isCancelled() { throw CancellationError() }
            if text.character(at: offset) == 10 || text.character(at: offset) == 13 {
                if text.character(at: offset) == 13 && offset + 1 < text.length && text.character(at: offset + 1) == 10 { offset += 1 }
                offset += 1
                lines.append((start, text.substring(with: NSRange(location: start, length: offset - start))))
                start = offset
            } else { offset += 1 }
        }
        lines.append((start, text.substring(from: start)))
        var found: [Image] = [], ordinal = 0
        var htmlRawContext: String?
        var scriptFilter = MarkdownHTMLMediaService.SourceHTMLFilter()
        var scriptCursor: Int?
        var htmlContextSource: NSMutableString?
        var previousHTMLRangeEnd = 0
        var scriptStartedInContainer = false
        var tablePositions: [OpaquePointer: MarkdownPresentationParser.Source.TableCellPositions] = [:]
        var invalidTablePositions: Set<OpaquePointer> = []
        var references: [(range: NSRange, ordinal: Int, label: String)] = []
        var inlineTags: [OpaquePointer: [(NSRange, String)]] = [:]
        var inlineLinks: [NSRange] = []
        var unknownInlineLink = false
        func visit(_ node: OpaquePointer) throws {
            if isCancelled() { throw CancellationError() }
            guard let name = cmark_node_get_type_string(node) else { return }
            let kind = String(cString: name)
            let currentOrdinal = ordinal
            if kind == "link" || kind == "image" { ordinal += 1 }
            func relevant(_ range: NSRange) -> Bool {
                guard let selection else { return true }
                return selection.length == 0 ? selection.location >= range.location && selection.location < NSMaxRange(range)
                    : NSIntersectionRange(selection, range).length > 0
            }
            func nodeRange() -> NSRange? {
                var ancestor = cmark_node_parent(node)
                while let current = ancestor {
                    if let name = cmark_node_get_type_string(current), String(cString: name) == "table_cell" {
                        if tablePositions[current] == nil && !invalidTablePositions.contains(current) {
                            if let positions = mapping.tableCellPositions(current) { tablePositions[current] = positions }
                            else { invalidTablePositions.insert(current) }
                        }
                        guard let positions = tablePositions[current] else { return nil }
                        return mapping.tableInlineRange(node, positions: positions)
                    }
                    ancestor = cmark_node_parent(current)
                }
                return mapping.range(node)
            }
            func insideContainer() -> Bool {
                var ancestor = cmark_node_parent(node)
                while let current = ancestor, cmark_node_get_type(current) != CMARK_NODE_DOCUMENT {
                    if isCancelled() { return false }
                    let kind = cmark_node_get_type(current)
                    if kind == CMARK_NODE_BLOCK_QUOTE || kind == CMARK_NODE_ITEM || kind == CMARK_NODE_LIST { return true }
                    ancestor = cmark_node_parent(current)
                }
                return false
            }
            if htmlForExport && confirmedInline != nil && kind == "link" {
                if let range = nodeRange() { inlineLinks.append(range) }
                else { unknownInlineLink = true }
            }
            if kind == "html_inline" || kind == "html_block" {
                if let range = nodeRange() {
                    if root != nil && htmlForExport {
                        if range.location < previousHTMLRangeEnd { htmlRawContext = "plaintext" }
                        if htmlRawContext == "script", previousHTMLRangeEnd < range.location,
                           scriptStartedInContainer || insideContainer() {
                            for position in previousHTMLRangeEnd..<range.location {
                                if isCancelled() { throw CancellationError() }
                                if text.character(at: position) == 10 || text.character(at: position) == 13 {
                                    htmlRawContext = "plaintext"; break
                                }
                            }
                        }
                        previousHTMLRangeEnd = NSMaxRange(range)
                        if !MarkdownPresentationParser.htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled) {
                            guard kind == "html_block", let prefixes = MarkdownPresentationParser.containerHTMLPrefixes(node, range: range, source: mapping, sourceText: text, isCancelled: isCancelled) else {
                                htmlRawContext = "plaintext"; return
                            }
                            if htmlContextSource == nil { htmlContextSource = NSMutableString(string: source) }
                            for prefix in prefixes { htmlContextSource?.replaceCharacters(in: prefix, with: String(repeating: " ", count: prefix.length)) }
                        }
                    }
                    let htmlText = (htmlContextSource as NSString?) ?? text
                    let startedOutside = htmlRawContext == nil
                    let block = htmlForExport && kind == "html_block" && startedOutside ? htmlText.substring(with: range) : nil
                    let prefix = block.map { $0.drop(while: { $0.isWhitespace }).prefix(7).lowercased() } ?? ""
                    let audio = block.map { prefix.hasPrefix("<audio") && MarkdownHTMLMediaService.audioSource(in: $0, allowPaired: true) != nil } ?? false
                    let video = block.map { prefix.hasPrefix("<video") && MarkdownHTMLMediaService.videoSource(in: $0) != nil } ?? false
                    let frame: MarkdownHTMLMediaService.EmbeddedFrame?
                    if let block, confirmedFrame != nil, prefix == "<iframe" {
                        frame = MarkdownHTMLMediaService.iframe(in: block)
                    } else { frame = nil }
                    let parent = cmark_node_parent(node)
                    var tags: [(NSRange, String, Bool)] = []
                    let images = htmlImages(in: htmlText, range: range, rawContext: &htmlRawContext, scriptFilter: &scriptFilter, scriptCursor: &scriptCursor,
                                            confirmedAudio: htmlForExport ? confirmedAudio : nil,
                                            confirmedInline: htmlForExport && kind == "html_inline" && confirmedInline != nil ? { tag, value in
                                                if let parent { inlineTags[parent, default: []].append((tag, value)) }
                                            } : nil,
                                            htmlForExport: htmlForExport, isCancelled: isCancelled,
                                            confirmedTag: { tag, name, closing in
                                                if confirmedHTMLTags != nil { tags.append((tag, name, closing)) }
                                                if root != nil && htmlForExport && name == "script" && !closing { scriptStartedInContainer = insideContainer() }
                                            }, confirmedRawClose: { tag, name in
                                                if confirmedHTMLTags != nil { tags.append((tag, name, true)) }
                                            })
                    if isCancelled() { throw CancellationError() }
                    if images != nil { confirmedHTMLTags?(node, range, tags) }
                    if htmlRawContext != "script" { scriptStartedInContainer = false }
                    if audio && images != nil && htmlRawContext == nil { confirmedAudio?(range) }
                    if video && images != nil && htmlRawContext == nil { confirmedVideo?(range) }
                    if let frame, images != nil, htmlRawContext == nil { confirmedFrame?(range, frame) }
                    if htmlForExport && kind == "html_block" && startedOutside && images != nil && htmlRawContext == nil { confirmedBlock?(range) }
                    if images == nil && relevant(range) {
                        if htmlForExport { htmlRawContext = "plaintext" }
                        else { throw UploadError.unsupportedImage }
                    }
                    for image in images ?? [] where relevant(image.range) {
                        if let selection, selection.length > 0, selection != image.range { throw UploadError.invalidInput }
                        found.append(image)
                        confirmedImage?(node, image)
                    }
                } else if let literal = cmark_node_get_literal(node) {
                    if htmlRawContext == "script" {
                        if htmlForExport { htmlRawContext = "plaintext"; return }
                        throw UploadError.unsupportedImage
                    }
                    let raw = String(cString: literal) as NSString
                    var localFilter = MarkdownHTMLMediaService.SourceHTMLFilter()
                    var localCursor: Int?
                    let images = htmlImages(in: raw, range: NSRange(location: 0, length: raw.length), rawContext: &htmlRawContext,
                                            scriptFilter: &localFilter, scriptCursor: &localCursor, isCancelled: isCancelled)
                    if htmlRawContext == "script" {
                        if !htmlForExport { throw UploadError.unsupportedImage }
                        htmlRawContext = "plaintext"
                    }
                    if isCancelled() { throw CancellationError() }
                    let first = max(0, min(Int(cmark_node_get_start_line(node)) - 1, lines.count - 1))
                    let last = max(first, min(Int(cmark_node_get_end_line(node)) - 1, lines.count - 1))
                    let end = lines[last].0 + (lines[last].1 as NSString).length
                    if (images == nil || !(images?.isEmpty ?? true)) && relevant(NSRange(location: lines[first].0, length: end - lines[first].0)) {
                        if !htmlForExport { throw UploadError.unsupportedImage }
                        if images == nil { htmlRawContext = "plaintext" }
                    }
                }
            }
            if kind == "image", htmlForExport { return }
            if kind == "image" {
                if htmlRawContext != nil { return }
                guard let whole = nodeRange(), let url = cmark_node_get_url(node) else {
                    let first = max(0, min(Int(cmark_node_get_start_line(node)) - 1, lines.count - 1))
                    let last = max(first, min(Int(cmark_node_get_end_line(node)) - 1, lines.count - 1))
                    let end = lines[last].0 + (lines[last].1 as NSString).length
                    if relevant(NSRange(location: lines[first].0, length: end - lines[first].0)) { throw UploadError.unsupportedImage }
                    return
                }
                if !relevant(whole) { return }
                if let selection, selection.length > 0, selection != whole { throw UploadError.invalidInput }
                guard let address = addressRange(in: text, image: whole) else {
                    guard let label = referenceLabel(text.substring(with: whole) as NSString) else { throw UploadError.unsupportedImage }
                    references.append((whole, currentOrdinal, label))
                    return
                }
                let raw = text.substring(with: whole) as NSString
                let local = NSRange(location: address.location - whole.location, length: address.length)
                let marker = "https://laceditor.invalid/" + UUID().uuidString
                let originalURL = String(cString: url)
                let title = cmark_node_get_title(node).map { String(cString: $0) } ?? ""
                guard imageIdentity(raw as String) == [originalURL, title],
                      imageIdentity(raw.replacingCharacters(in: local, with: marker)) == [marker, title] else { throw UploadError.unsupportedImage }
                found.append(Image(range: whole, addressRange: address, rawAddress: text.substring(with: address), address: String(cString: url), syntax: .markdown))
                return
            }
            var child = cmark_node_first_child(node)
            while let next = child { try visit(next); child = cmark_node_next(next) }
        }
        func process(_ root: OpaquePointer) -> Result<Void, Error> {
            mapping = sourceMapping ?? MarkdownPresentationParser.Source(source, root: root, isCancelled: isCancelled)
            return Result {
                try visit(root)
                let links = inlineLinks.sorted { $0.location < $1.location }
                var linkEnd = 0
                let linkEnds = links.map { range in
                    linkEnd = max(linkEnd, NSMaxRange(range))
                    return linkEnd
                }
                for tags in inlineTags.values {
                    if isCancelled() { throw CancellationError() }
                    var stack: [(String, Int)] = [], valid = true, hasAnchor = false
                    for (range, tag) in tags where tag != "<br>" {
                        if isCancelled() { throw CancellationError() }
                        let closing = tag.hasPrefix("</")
                        let name = closing ? String(tag.dropFirst(2).dropLast()) : String(tag.dropFirst().prefix { $0 != " " && $0 != ">" })
                        if closing {
                            guard let opening = stack.last, opening.0 == name else { valid = false; break }
                            if name == "a" {
                                if unknownInlineLink { valid = false; break }
                                var low = 0, high = links.count
                                while low < high {
                                    let middle = (low + high) / 2
                                    if links[middle].location < range.location { low = middle + 1 } else { high = middle }
                                }
                                if low > 0 && linkEnds[low - 1] > opening.1 { valid = false; break }
                                hasAnchor = false
                            }
                            stack.removeLast()
                        } else {
                            if name == "a" && hasAnchor { valid = false; break }
                            if name == "a" { hasAnchor = true }
                            stack.append((name, range.location))
                        }
                    }
                    if !stack.isEmpty { valid = false }
                    for (range, tag) in tags where valid || tag == "<br>" {
                        if isCancelled() { throw CancellationError() }
                        confirmedInline?(range, tag)
                    }
                }
            }
        }
        let result: Result<Void, Error>
        if let root { result = process(root) }
        else {
            let input = MarkdownPresentationParser.maskedFrontMatter(source, frontMatter: MarkdownPresentationParser.frontMatter(source))
            guard let parsed = MarkdownMathExtension.withDocument(input, options: CMARK_OPT_SMART | CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS | CMARK_OPT_FOOTNOTES, { root, _, _ in process(root) }) else { throw UploadError.invalidInput }
            result = parsed
        }
        try result.get()
        if isCancelled() { throw CancellationError() }
        if !references.isEmpty {
            let resolved = try resolveReferences(in: source, references: references,
                allowShared: selection == nil || allowSharedReference, isCancelled: isCancelled)
            var ranges = Set(found.map(\.addressRange))
            for image in resolved where ranges.insert(image.addressRange).inserted { found.append(image) }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    private static func imageIdentity(_ source: String) -> [String]? {
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return nil }
        defer { cmark_parser_free(parser) }
        source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
        guard let root = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(root) }
        var found: [[String]] = []
        func visit(_ node: OpaquePointer) {
            if let kind = cmark_node_get_type_string(node), String(cString: kind) == "image", let url = cmark_node_get_url(node) {
                found.append([String(cString: url), cmark_node_get_title(node).map { String(cString: $0) } ?? ""])
            }
            var child = cmark_node_first_child(node)
            while let next = child { visit(next); child = cmark_node_next(next) }
        }
        visit(root)
        return found.count == 1 ? found[0] : nil
    }

    private static func destinations(_ source: String) -> [(String, String, String)]? {
        let input = MarkdownPresentationParser.maskedFrontMatter(source, frontMatter: MarkdownPresentationParser.frontMatter(source))
        return MarkdownMathExtension.withDocument(input, options: CMARK_OPT_SMART | CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS | CMARK_OPT_FOOTNOTES) { root, _, _ in
            var values: [(String, String, String)] = []
            func visit(_ node: OpaquePointer) {
                guard let raw = cmark_node_get_type_string(node) else { return }
                let kind = String(cString: raw)
                if kind == "link" || kind == "image" {
                    values.append((kind, cmark_node_get_url(node).map { String(cString: $0) } ?? "",
                                   cmark_node_get_title(node).map { String(cString: $0) } ?? ""))
                    if kind == "image" { return }
                }
                var child = cmark_node_first_child(node)
                while let next = child { visit(next); child = cmark_node_next(next) }
            }
            visit(root)
            return values
        }
    }

    private static func referenceLabel(_ raw: NSString) -> String? {
        guard raw.length >= 4, raw.character(at: 0) == 33, raw.character(at: 1) == 91 else { return nil }
        var cursor = 2, depth = 1
        while cursor < raw.length && depth > 0 {
            if raw.character(at: cursor) == 92 && cursor + 1 < raw.length { cursor += 2; continue }
            if raw.character(at: cursor) == 91 { depth += 1 }
            if raw.character(at: cursor) == 93 { depth -= 1 }
            cursor += 1
        }
        guard depth == 0 else { return nil }
        let alt = raw.substring(with: NSRange(location: 2, length: cursor - 3))
        if cursor == raw.length { return normalizedReference(alt) }
        guard raw.character(at: cursor) == 91, raw.character(at: raw.length - 1) == 93 else { return nil }
        let explicit = raw.substring(with: NSRange(location: cursor + 1, length: raw.length - cursor - 2))
        return normalizedReference(explicit.isEmpty ? alt : explicit)
    }

    private static func normalizedReference(_ value: String) -> String? {
        let lines = value.components(separatedBy: .newlines)
        let unwrapped = lines.enumerated().map { index, line in
            guard index > 0 else { return line }
            var result = line.trimmingCharacters(in: .whitespaces)
            while result.hasPrefix(">") {
                result.removeFirst()
                if result.hasPrefix(" ") { result.removeFirst() }
            }
            return result
        }.joined(separator: " ")
        let escaped = unwrapped.replacingOccurrences(of: "<", with: "\\<").replacingOccurrences(of: ">", with: "\\>")
            .replacingOccurrences(of: " ", with: "%20")
        guard let decoded = imageIdentity("![x](<" + escaped + ">)")?.first else { return nil }
        let label = decoded.replacingOccurrences(of: "%20", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        return label.isEmpty ? nil : label
    }

    private static func inlineReference(in text: NSString, range: NSRange, definition: NSRange,
                                        address: String, title: String) -> Image.InlineReference? {
        let raw = text.substring(with: range) as NSString
        guard raw.length >= 4, raw.character(at: 0) == 33, raw.character(at: 1) == 91 else { return nil }
        var cursor = 2, depth = 1
        while cursor < raw.length && depth > 0 {
            if raw.character(at: cursor) == 92 && cursor + 1 < raw.length { cursor += 2; continue }
            if raw.character(at: cursor) == 91 { depth += 1 }
            if raw.character(at: cursor) == 93 { depth -= 1 }
            cursor += 1
        }
        guard depth == 0 else { return nil }
        let opening = raw.substring(to: cursor)
        var position = NSMaxRange(definition)
        if position < text.length && text.character(at: position) == 62 { position += 1 }
        var newlineCount = 0
        while position < text.length {
            let c = text.character(at: position)
            if c == 32 || c == 9 { position += 1; continue }
            if c == 10 || c == 13 {
                newlineCount += 1
                if c == 13 && position + 1 < text.length && text.character(at: position + 1) == 10 { position += 1 }
                position += 1
                if newlineCount > 1 { break }
                continue
            }
            if c == 62 && newlineCount == 1 { position += 1; continue }
            break
        }
        var titleToken = "", titleProbe: NSRange?
        if position < text.length {
            let delimiter = text.character(at: position)
            if delimiter == 34 || delimiter == 39 || delimiter == 40 {
                let closing: UInt16 = delimiter == 40 ? 41 : delimiter
                let start = position
                position += 1
                while position < text.length && text.character(at: position) != closing {
                    if text.character(at: position) == 92 && position + 1 < text.length { position += 2 } else { position += 1 }
                }
                guard position < text.length else { return nil }
                titleToken = " " + text.substring(with: NSRange(location: start, length: position - start + 1))
                if newlineCount > 0 && title.isEmpty { titleProbe = NSRange(location: start, length: position - start + 1) }
            }
        }
        let escaped = address.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "<", with: "\\<").replacingOccurrences(of: ">", with: "\\>")
            .replacingOccurrences(of: "&", with: "&amp;")
        if !titleToken.contains("\n") && !titleToken.contains("\r") {
            guard imageIdentity(opening + "(<" + escaped + ">" + titleToken + ")") == [address, title] else { return nil }
        }
        return Image.InlineReference(range: range, original: raw as String, opening: opening, title: titleToken, titleProbe: titleProbe)
    }

    private static func resolveReferences(in source: String, references: [(range: NSRange, ordinal: Int, label: String)],
                                          allowShared: Bool, isCancelled: () -> Bool) throws -> [Image] {
        guard let baseline = destinations(source) else { throw UploadError.unsupportedImage }
        let text = source as NSString, labels = Set(references.map { $0.label })
        var candidates: [(range: NSRange, marker: String)] = [], cursor = 0
        var nonce = "https://laceditor.invalid/" + UUID().uuidString
        while source.contains(nonce) { nonce += "X" }
        while cursor < text.length {
            if isCancelled() { throw CancellationError() }
            if text.character(at: cursor) == 92 && cursor + 1 < text.length { cursor += 2; continue }
            guard text.character(at: cursor) == 91 else { cursor += 1; continue }
            let labelStart = cursor + 1
            cursor += 1
            while cursor < text.length && text.character(at: cursor) != 93 {
                if text.character(at: cursor) == 92 && cursor + 1 < text.length { cursor += 2; continue }
                if text.character(at: cursor) == 91 { break }
                cursor += 1
            }
            if cursor + 1 < text.length && text.character(at: cursor) == 93 && text.character(at: cursor + 1) == 58,
               let label = normalizedReference(text.substring(with: NSRange(location: labelStart, length: cursor - labelStart))), labels.contains(label) {
                var addressStart = cursor + 2
                var continuation = false
                while addressStart < text.length {
                    let c = text.character(at: addressStart)
                    if c == 32 || c == 9 || c == 10 || c == 13 {
                        if c == 10 || c == 13 { continuation = true }
                        addressStart += 1
                        continue
                    }
                    if c == 62 && continuation {
                        addressStart += 1
                        continue
                    }
                    break
                }
                if addressStart < text.length {
                    let line = text.lineRange(for: NSRange(location: addressStart, length: 0))
                    let lineEnd = NSMaxRange(line)
                    let rest = text.substring(with: NSRange(location: addressStart, length: lineEnd - addressStart))
                    let synthetic = ("![x](" + rest + ")") as NSString
                    if let local = addressRange(in: synthetic, image: NSRange(location: 0, length: synthetic.length)) {
                        let range = NSRange(location: addressStart + local.location - 5, length: local.length)
                        if range.location >= addressStart && NSMaxRange(range) <= lineEnd {
                            candidates.append((range, nonce + "/" + String(candidates.count)))
                        }
                    }
                }
            }
            if cursor < text.length && text.character(at: cursor) == 91 { continue }
            cursor += 1
        }
        guard !candidates.isEmpty else { throw UploadError.unsupportedImage }
        let changed = NSMutableString(string: "")
        var cursor = 0
        for candidate in candidates {
            guard candidate.range.location >= cursor else { throw UploadError.unsupportedImage }
            changed.append(text.substring(with: NSRange(location: cursor, length: candidate.range.location - cursor)))
            changed.append(candidate.marker)
            cursor = NSMaxRange(candidate.range)
        }
        changed.append(text.substring(from: cursor))
        if isCancelled() { throw CancellationError() }
        guard let after = destinations(changed as String), after.count == baseline.count else { throw UploadError.unsupportedImage }
        let byMarker = Dictionary(uniqueKeysWithValues: candidates.map { ($0.marker, $0.range) })
        var changedImages: [String: Int] = [:]
        var changedLinks = Set<String>()
        for index in baseline.indices {
            guard baseline[index].0 == after[index].0, baseline[index].2 == after[index].2 else { throw UploadError.unsupportedImage }
            if baseline[index].1 != after[index].1 {
                guard byMarker[after[index].1] != nil else { throw UploadError.unsupportedImage }
                if baseline[index].0 == "image" { changedImages[after[index].1, default: 0] += 1 }
                else { changedLinks.insert(after[index].1) }
            }
        }
        var output: [Image] = [], groups: [String: Int] = [:]
        for reference in references {
            if isCancelled() { throw CancellationError() }
            guard baseline.indices.contains(reference.ordinal), baseline[reference.ordinal].0 == "image",
                  let range = byMarker[after[reference.ordinal].1] else { throw UploadError.unsupportedImage }
            let marker = after[reference.ordinal].1
            let materialize = changedLinks.contains(marker) || (!allowShared && changedImages[marker, default: 0] > 1)
            let inline: Image.InlineReference?
            if materialize {
                guard let value = inlineReference(in: text, range: reference.range, definition: range,
                    address: baseline[reference.ordinal].1, title: baseline[reference.ordinal].2) else { throw UploadError.unsupportedImage }
                inline = value
            } else { inline = nil }
            if let index = groups[marker] {
                if let inline { output[index].inlineReferences.append(inline) }
            } else {
                var image = Image(range: reference.range, addressRange: range, rawAddress: text.substring(with: range),
                                  address: baseline[reference.ordinal].1, syntax: .reference)
                if let inline { image.inlineReferences = [inline] }
                groups[marker] = output.count
                output.append(image)
            }
        }
        var titleMarkers: [NSRange: String] = [:], titleTargets: [NSRange: String] = [:]
        for image in output {
            for reference in image.inlineReferences {
                if let token = reference.titleProbe {
                    if titleMarkers[token] == nil { titleMarkers[token] = "LacTitle" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
                    titleTargets[reference.range] = titleMarkers[token]
                }
            }
        }
        if !titleMarkers.isEmpty {
            let tokens = titleMarkers.sorted { $0.key.location < $1.key.location }
            let check = NSMutableString(string: "")
            var offset = 0
            for (range, marker) in tokens {
                guard range.location >= offset else { throw UploadError.unsupportedImage }
                check.append(text.substring(with: NSRange(location: offset, length: range.location - offset)))
                check.append("'" + marker + "'")
                offset = NSMaxRange(range)
            }
            check.append(text.substring(from: offset))
            if isCancelled() { throw CancellationError() }
            guard let result = destinations(check as String), result.count == baseline.count else { throw UploadError.unsupportedImage }
            for index in baseline.indices where baseline[index].0 != result[index].0 || baseline[index].1 != result[index].1 {
                throw UploadError.unsupportedImage
            }
            for reference in references {
                if let marker = titleTargets[reference.range], result[reference.ordinal].2 != marker { throw UploadError.unsupportedImage }
            }
        }
        var proof: [(NSRange, String)] = []
        for image in output where !image.inlineReferences.isEmpty {
            let address = image.address.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "<", with: "\\<").replacingOccurrences(of: ">", with: "\\>")
                .replacingOccurrences(of: "&", with: "&amp;")
            for reference in image.inlineReferences {
                proof.append((reference.range, reference.opening + "(<" + address + ">" + reference.title + ")"))
            }
        }
        if !proof.isEmpty {
            proof.sort { $0.0.location < $1.0.location }
            let check = NSMutableString(string: "")
            var offset = 0
            for (range, value) in proof {
                guard range.location >= offset else { throw UploadError.unsupportedImage }
                check.append(text.substring(with: NSRange(location: offset, length: range.location - offset)))
                check.append(value)
                offset = NSMaxRange(range)
            }
            check.append(text.substring(from: offset))
            if isCancelled() { throw CancellationError() }
            guard let result = destinations(check as String), result.count == baseline.count else { throw UploadError.unsupportedImage }
            for index in baseline.indices where baseline[index].0 != result[index].0 || baseline[index].1 != result[index].1 || baseline[index].2 != result[index].2 {
                throw UploadError.unsupportedImage
            }
        }
        return output
    }

    private static func htmlImages(in source: NSString, range: NSRange, rawContext: inout String?,
                                   scriptFilter: inout MarkdownHTMLMediaService.SourceHTMLFilter, scriptCursor: inout Int?,
                                   confirmedAudio: ((NSRange) -> Void)? = nil, confirmedInline: ((NSRange, String) -> Void)? = nil,
                                   htmlForExport: Bool = false, contextOnly: Bool = false,
                                   isCancelled: () -> Bool = { false },
                                   confirmedTag: ((NSRange, String, Bool) -> Void)? = nil,
                                   confirmedRawClose: ((NSRange, String) -> Void)? = nil) -> [Image]? {
        let end = NSMaxRange(range)
        guard end <= source.length else { return nil }
        var cursor = range.location, result: [Image] = [], skipAudioUntil = 0
        var noAudioClosing = false
        let rawText = Set(["script", "style", "title", "textarea", "xmp", "iframe", "noembed", "noframes", "plaintext"])
        func whitespace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }
        while cursor < end {
            if isCancelled() { return nil }
            if let context = rawContext {
                if context == "plaintext" { return result }
                let needle = "</" + context
                var closing: NSRange?
                while cursor < end {
                    if isCancelled() { return nil }
                    let found = source.range(of: needle, options: .caseInsensitive, range: NSRange(location: cursor, length: end - cursor))
                    guard found.location != NSNotFound else { return result }
                    let next = NSMaxRange(found)
                    if next < end && (whitespace(source.character(at: next)) || source.character(at: next) == 47 || source.character(at: next) == 62) {
                        closing = found
                        break
                    }
                    cursor = next
                }
                guard let closing else { return result }
                var closeEnd = NSMaxRange(closing), delimiter: UInt16?
                while closeEnd < end {
                    if isCancelled() { return nil }
                    let value = source.character(at: closeEnd)
                    if let quote = delimiter { if value == quote { delimiter = nil } }
                    else if value == 34 || value == 39 { delimiter = value }
                    else if value == 62 { break }
                    closeEnd += 1
                }
                guard closeEnd < end else { return result }
                cursor = closeEnd + 1
                if context == "script" {
                    guard let start = scriptCursor, start <= cursor, cursor <= source.length else { return nil }
                    _ = scriptFilter.filter(source.substring(with: NSRange(location: start, length: cursor - start)), isCancelled: isCancelled)
                    if isCancelled() { return nil }
                    scriptCursor = cursor
                    if scriptFilter.suppressesText { continue }
                    scriptCursor = nil
                }
                confirmedRawClose?(NSRange(location: closing.location, length: cursor - closing.location), context)
                rawContext = nil
                continue
            }
            guard source.character(at: cursor) == 60 else { cursor += 1; continue }
            let remaining = NSRange(location: cursor, length: end - cursor)
            if remaining.length >= 4 && source.substring(with: NSRange(location: cursor, length: 4)) == "<!--" {
                let rest = NSRange(location: cursor + 4, length: end - cursor - 4)
                if rest.length > 0 && source.character(at: rest.location) == 62 { cursor = rest.location + 1 }
                else if rest.length > 1 && source.character(at: rest.location) == 45 && source.character(at: rest.location + 1) == 62 { cursor = rest.location + 2 }
                else {
                    let closes = ["-->", "--!>"].map { source.range(of: $0, options: [], range: rest) }.filter { $0.location != NSNotFound }
                    cursor = closes.min(by: { $0.location < $1.location }).map(NSMaxRange) ?? end
                }
                continue
            }
            var position = cursor + 1, closing = false
            if position < end && source.character(at: position) == 47 { closing = true; position += 1 }
            let nameStart = position
            while position < end {
                if isCancelled() { return nil }
                let c = source.character(at: position)
                if whitespace(c) || c == 47 || c == 62 { break }
                position += 1
            }
            guard position > nameStart else { cursor += 1; continue }
            let name = source.substring(with: NSRange(location: nameStart, length: position - nameStart)).lowercased()
            var quote: UInt16?
            while position < end {
                if isCancelled() { return nil }
                let c = source.character(at: position)
                if let delimiter = quote { if c == delimiter { quote = nil } }
                else if c == 34 || c == 39 { quote = c }
                else if c == 62 { break }
                position += 1
            }
            if position >= end { return name == "img" ? nil : result }
            let tag = NSRange(location: cursor, length: position + 1 - cursor)
            confirmedTag?(tag, name, closing)
            if confirmedInline != nil && ["kbd", "ruby", "rt", "rp", "span", "strong", "em", "b", "i", "u", "s", "del", "mark", "sub", "sup"].contains(name) {
                let fixed = "<" + (closing ? "/" : "") + name + ">"
                if source.substring(with: tag).lowercased() == fixed { confirmedInline?(tag, fixed) }
                else if name == "span" && !closing, let style = MarkdownHTMLMediaService.inlineStyleOpening(source.substring(with: tag), isCancelled: isCancelled) {
                    confirmedInline?(tag, "<span style=\"" + style.css + "\">")
                }
            }
            if confirmedInline != nil && name == "a" {
                let literal = source.substring(with: tag)
                if closing && literal.lowercased() == "</a>" { confirmedInline?(tag, "</a>") }
                else if !closing, let opening = MarkdownHTMLMediaService.inlineLinkOpening(literal) { confirmedInline?(tag, opening) }
            }
            if confirmedInline != nil && name == "br" && !closing && ["<br>", "<br/>", "<br />"].contains(source.substring(with: tag).lowercased()) {
                confirmedInline?(tag, "<br>")
            }
            if name == "audio" && !closing && confirmedAudio != nil && !noAudioClosing && cursor >= skipAudioUntil {
                let after = NSMaxRange(tag)
                let closingTag = source.range(of: "</audio>", options: .caseInsensitive, range: NSRange(location: after, length: end - after))
                if closingTag.location != NSNotFound {
                    skipAudioUntil = NSMaxRange(closingTag)
                    let audio = NSRange(location: cursor, length: NSMaxRange(closingTag) - cursor)
                    if MarkdownHTMLMediaService.audioSource(in: source.substring(with: audio), allowPaired: true) != nil {
                        confirmedAudio?(audio)
                        confirmedTag?(closingTag, "audio", true)
                        cursor = NSMaxRange(audio)
                        continue
                    }
                } else { noAudioClosing = true }
            }
            if name == "img" && !closing && !contextOnly {
                guard let image = htmlImage(in: source, range: tag, htmlForExport: htmlForExport, isCancelled: isCancelled) else { return nil }
                result.append(image)
            }
            cursor = position + 1
            if !closing && rawText.contains(name) {
                rawContext = name
                if name == "script" {
                    scriptFilter = MarkdownHTMLMediaService.SourceHTMLFilter()
                    _ = scriptFilter.filter(source.substring(with: tag), isCancelled: isCancelled)
                    if isCancelled() { return nil }
                    scriptCursor = cursor
                }
            }
        }
        return result
    }

    static func confirmedHTMLImage(in source: NSString, range: NSRange, isCancelled: () -> Bool) -> Image? {
        htmlImage(in: source, range: range, htmlForExport: false, isCancelled: isCancelled)
    }

    private static func htmlImage(in source: NSString, range: NSRange, htmlForExport: Bool, isCancelled: () -> Bool,
                                  tagName: String = "img", missingSource: (() -> Void)? = nil) -> Image? {
        guard NSMaxRange(range) <= source.length else { return nil }
        var start = range.location, end = NSMaxRange(range)
        func space(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }
        while start < end && space(source.character(at: start)) { if isCancelled() { return nil }; start += 1 }
        while end > start && space(source.character(at: end - 1)) { if isCancelled() { return nil }; end -= 1 }
        let prefix = "<" + tagName
        let prefixLength = (prefix as NSString).length
        guard end - start > prefixLength, source.substring(with: NSRange(location: start, length: prefixLength)).lowercased() == prefix else { return nil }
        var cursor = start + prefixLength
        guard space(source.character(at: cursor)) || source.character(at: cursor) == 47 || source.character(at: cursor) == 62 else { return nil }
        var address: NSRange?, quote: UInt16?, attributes: [(NSRange, NSRange, Bool)] = []
        while cursor < end {
            if isCancelled() { return nil }
            while cursor < end && space(source.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
            guard cursor < end else { return nil }
            let current = source.character(at: cursor)
            if current == 62 { cursor += 1; break }
            if current == 47 && cursor + 1 < end && source.character(at: cursor + 1) == 62 { cursor += 2; break }
            let nameStart = cursor
            while cursor < end {
                if isCancelled() { return nil }
                let c = source.character(at: cursor)
                if space(c) || c == 61 || c == 47 || c == 62 { break }
                if c == 34 || c == 39 || c == 60 { return nil }
                cursor += 1
            }
            guard cursor > nameStart else { return nil }
            let nameRange = NSRange(location: nameStart, length: cursor - nameStart)
            let name = source.substring(with: nameRange).lowercased()
            while cursor < end && space(source.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
            if cursor >= end || source.character(at: cursor) != 61 {
                if name == "src" { return nil }
                continue
            }
            cursor += 1
            while cursor < end && space(source.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
            guard cursor < end else { return nil }
            let delimiter = source.character(at: cursor)
            let quoted = delimiter == 34 || delimiter == 39
            if quoted { cursor += 1 }
            let valueStart = cursor
            while cursor < end {
                if isCancelled() { return nil }
                let c = source.character(at: cursor)
                if quoted ? c == delimiter : (space(c) || c == 62) { break }
                if !quoted && (c == 34 || c == 39 || c == 60 || c == 61 || c == 96) { return nil }
                cursor += 1
            }
            guard (cursor > valueStart || quoted), cursor < end else { return nil }
            let valueRange = NSRange(location: valueStart, length: cursor - valueStart)
            attributes.append((nameRange, valueRange, quoted))
            if quoted { cursor += 1 }
            if name == "src" {
                guard address == nil, valueRange.length > 0 else { return nil }
                address = valueRange
                quote = quoted ? delimiter : nil
            }
        }
        guard cursor == end else { return nil }
        guard let address else { missingSource?(); return nil }
        let raw = source.substring(with: address)
        guard let normalized = normalizeHTMLReferences(raw, isCancelled: isCancelled) else { return nil }
        let markdown = normalized.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "<", with: "\\<").replacingOccurrences(of: ">", with: "\\>")
            .replacingOccurrences(of: " ", with: "%20")
        guard let identity = imageIdentity("![x](<" + markdown + ">)"), !identity[0].isEmpty else { return nil }
        var htmlXML: String?
        let needsXMLNormalization = htmlForExport && attributes.contains { attribute in
            let (name, value, quoted) = attribute
            let rawName = source.substring(with: name)
            return !quoted || rawName != rawName.lowercased() ||
                source.rangeOfCharacter(from: CharacterSet(charactersIn: "&<\r\n\t"), options: [], range: value).location != NSNotFound
        }
        if needsXMLNormalization {
            let xml = NSMutableString(string: source.substring(with: NSRange(location: start, length: end - start)))
            var valid = true
            for (name, value, quoted) in attributes.reversed() {
                if isCancelled() { return nil }
                let rawValue = source.substring(with: value)
                guard let normalized = normalizeHTMLReferences(rawValue, isCancelled: isCancelled),
                      let decoded = decodeHTMLReferences(normalized) else { valid = false; break }
                let escaped = decoded.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                    .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
                    .replacingOccurrences(of: "\t", with: "&#9;").replacingOccurrences(of: "\n", with: "&#10;")
                    .replacingOccurrences(of: "\r", with: "&#13;")
                xml.replaceCharacters(in: NSRange(location: value.location - start, length: value.length),
                                      with: quoted ? escaped : "\"" + escaped + "\"")
                xml.replaceCharacters(in: NSRange(location: name.location - start, length: name.length),
                                      with: source.substring(with: name).lowercased())
            }
            if valid { htmlXML = xml as String }
        }
        return Image(range: NSRange(location: start, length: end - start), addressRange: address,
                     rawAddress: raw, address: identity[0], syntax: .html(quote: quote), htmlXML: htmlXML)
    }

    private static func normalizeHTMLReferences(_ raw: String, isCancelled: () -> Bool) -> String? {
        let rawUnits = raw as NSString
        var entity = 0, corrections: [(NSRange, String)] = []
        while entity < rawUnits.length {
            if isCancelled() { return nil }
            guard rawUnits.character(at: entity) == 38, entity + 1 < rawUnits.length else { entity += 1; continue }
            var next = entity + 1
            let numeric = rawUnits.character(at: next) == 35
            var radix = 10
            if numeric {
                next += 1
                if next < rawUnits.length && (rawUnits.character(at: next) == 120 || rawUnits.character(at: next) == 88) { radix = 16; next += 1 }
            }
            let nameStart = next
            while next < rawUnits.length {
                if isCancelled() { return nil }
                let c = rawUnits.character(at: next)
                let digit = (48...57).contains(c)
                let letter = (65...90).contains(c) || (97...122).contains(c)
                let hex = (65...70).contains(c) || (97...102).contains(c)
                if numeric ? (digit || (radix == 16 && hex)) : (digit || letter) { next += 1 } else { break }
            }
            if next > nameStart {
                let hasSemicolon = next < rawUnits.length && rawUnits.character(at: next) == 59
                if numeric {
                    let number = rawUnits.substring(with: NSRange(location: nameStart, length: next - nameStart))
                    var value = UInt64(number, radix: radix) ?? 0x110000
                    if value == 0 || value > 0x10ffff || (0xd800...0xdfff).contains(value) { value = 0xfffd }
                    value = htmlNumericReplacements[value] ?? value
                    corrections.append((NSRange(location: entity, length: next - entity + (hasSemicolon ? 1 : 0)), "&#\(value);"))
                    if hasSemicolon { next += 1 }
                } else if !hasSemicolon {
                    let name = rawUnits.substring(with: NSRange(location: nameStart, length: next - nameStart))
                    let followedByEquals = next < rawUnits.length && rawUnits.character(at: next) == 61
                    if legacyHTMLReferences.contains(name) && !followedByEquals { corrections.append((NSRange(location: next, length: 0), ";")) }
                }
            }
            entity = max(entity + 1, next)
        }
        let normalized = NSMutableString(string: "")
        var previous = 0
        for (range, value) in corrections {
            if isCancelled() { return nil }
            normalized.append(rawUnits.substring(with: NSRange(location: previous, length: range.location - previous)))
            normalized.append(value)
            previous = NSMaxRange(range)
        }
        normalized.append(rawUnits.substring(from: previous))
        return normalized as String
    }

    private static func decodeHTMLReferences(_ value: String) -> String? {
        var buffer = cmark_strbuf()
        cmark_strbuf_init(cmark_get_default_mem_allocator(), &buffer, 0)
        defer { cmark_strbuf_free(&buffer) }
        let bytes = Array(value.utf8)
        guard bytes.count <= Int(Int32.max) else { return nil }
        bytes.withUnsafeBufferPointer { input in
            if let base = input.baseAddress { houdini_unescape_html_f(&buffer, base, numericCast(input.count)) }
        }
        guard let pointer = buffer.ptr else { return nil }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(buffer.size)), as: UTF8.self)
    }

    static func addressRange(in text: NSString, image: NSRange) -> NSRange? {
        let end = NSMaxRange(image)
        guard image.length >= 5, text.character(at: image.location) == 33, text.character(at: image.location + 1) == 91 else { return nil }
        var i = image.location + 2, depth = 1
        while i < end && depth > 0 {
            let c = text.character(at: i)
            if c == 92 && i + 1 < end { i += 2; continue }
            if c == 91 { depth += 1 }
            if c == 93 { depth -= 1 }
            i += 1
        }
        guard depth == 0, i < end, text.character(at: i) == 40 else { return nil }
        i += 1
        while i < end && (text.character(at: i) == 32 || text.character(at: i) == 10 || text.character(at: i) == 13 || text.character(at: i) == 9) { i += 1 }
        guard i < end else { return nil }
        let angle = text.character(at: i) == 60
        if angle { i += 1 }
        let start = i
        var parentheses = 0
        while i < end {
            let c = text.character(at: i)
            if c == 92 && i + 1 < end { i += 2; continue }
            if angle && c == 62 { return NSRange(location: start, length: i - start) }
            if !angle {
                if c == 40 { parentheses += 1 }
                if c == 41 {
                    if parentheses == 0 { return NSRange(location: start, length: i - start) }
                    parentheses -= 1
                }
                if c == 32 || c == 9 || c == 10 || c == 13 { return NSRange(location: start, length: i - start) }
            }
            i += 1
        }
        return nil
    }
}

extension MarkdownImageUploadService {
    enum DocumentPolicy: Equatable { case absent, upload, other(String) }

    static func documentPolicy(in text: String, isCancelled: () -> Bool) throws -> DocumentPolicy {
        if isCancelled() { throw CancellationError() }
        do {
            guard let mapping = try PandocExportService.yamlFrontMatter(text), let node = mapping["typora-copy-images-to"] else { return .absent }
            if isCancelled() { throw CancellationError() }
            guard node.tag == Tag(.str), let value = node.scalar?.string else { throw UploadError.invalidPolicy }
            return value == "upload" ? .upload : .other(value)
        } catch is CancellationError { throw CancellationError() }
        catch { throw UploadError.invalidPolicy }
    }

    struct Payload {
        let data: Data
        let filename: String
        let mime: String
        let localURL: URL?

        init(data: Data, filename: String, mime: String, localURL: URL? = nil) {
            self.data = data
            self.filename = filename
            self.mime = mime
            self.localURL = localURL
        }
    }

    static func payload(address: String, document: URL?, paths: MarkdownResourcePaths? = nil) throws -> Payload {
        if address.hasPrefix("data:") {
            guard let comma = address.firstIndex(of: ",") else { throw UploadError.invalidInput }
            let header = String(address[address.index(address.startIndex, offsetBy: 5)..<comma])
            let parts = header.split(separator: ";", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1].lowercased() == "base64",
                  let declared = UTType(mimeType: String(parts[0])), declared.conforms(to: .image),
                  let bytes = Data(base64Encoded: String(address[address.index(after: comma)..<(address[address.index(after: comma)...].firstIndex(of: "#") ?? address.endIndex)])),
                  let mime = actualMIME(bytes), UTType(mimeType: mime) == declared,
                  let ext = imageExtension(mime) else { throw UploadError.invalidInput }
            return Payload(data: bytes, filename: "image.\(ext)", mime: mime)
        }
        let url = try localURL(address: address, document: document, paths: paths)
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let mime = type.preferredMIMEType?.lowercased() else { throw UploadError.invalidInput }
        let bytes = try Data(contentsOf: url)
        guard actualMIME(bytes) == mime else { throw UploadError.invalidInput }
        return Payload(data: bytes, filename: url.lastPathComponent, mime: mime, localURL: URL(fileURLWithPath: url.path))
    }

    static func localURL(address: String, document: URL?, paths: MarkdownResourcePaths? = nil) throws -> URL {
        let url: URL
        if let paths {
            guard let parsed = paths.resolve(address), parsed.isFileURL else { throw UploadError.invalidInput }
            url = parsed
        } else if let parsed = URL(string: address), parsed.scheme != nil {
            guard parsed.isFileURL else { throw UploadError.invalidInput }
            url = parsed
        } else {
            let base = address.hasPrefix("/") ? URL(fileURLWithPath: "/", isDirectory: true) : document?.deletingLastPathComponent()
            guard let base, base.isFileURL,
                  let parsed = URL(string: address, relativeTo: base)?.absoluteURL,
                  parsed.isFileURL else { throw UploadError.invalidInput }
            url = parsed
        }
        return url
    }

    static func payload(data: Data) throws -> Payload {
        guard let mime = actualMIME(data), let ext = imageExtension(mime) else { throw UploadError.invalidInput }
        return Payload(data: data, filename: "image.\(ext)", mime: mime)
    }

    static func download(_ url: URL, session: URLSession = .shared) async throws -> Payload {
        let data = try await downloadData(url, session: session)
        return try payload(data: data)
    }

    static func downloadData(_ url: URL, session: URLSession = .shared) async throws -> Data {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw UploadError.invalidInput }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let final = http.url, ["http", "https"].contains(final.scheme?.lowercased() ?? ""), final.host != nil else { throw UploadError.serverFailed }
        return data
    }

    static func upload(_ payloads: [Payload], method: String, endpoint: String, executable: String,
                       arguments: String, document: URL?, isCancelled: () -> Bool) async throws -> [URL] {
        if isCancelled() { throw CancellationError() }
        if method == "picgo" {
            guard let url = URL(string: endpoint) else { throw UploadError.invalidInput }
            let result = try await uploadToPicGo(payloads, endpoint: url)
            if isCancelled() { throw CancellationError() }
            return result
        }
        if method == "piclist" {
            guard let url = URL(string: endpoint) else { throw UploadError.invalidInput }
            let key = try PicListKeychainStore().load(endpoint: endpoint)
            let result = try await uploadToPicList(payloads, endpoint: url, key: key, isCancelled: isCancelled)
            if Task.isCancelled || isCancelled() {
                throw UploadError.picListPartial(result.map(\.absoluteString), L10n.tr("取消"))
            }
            return result
        }
        if method == "ipic" {
            return try await uploadToIPic(payloads, isCancelled: isCancelled)
        }
        if method == "upic" || method == "picsee" {
            guard executable.hasPrefix("/") else { throw UploadError.invalidInput }
            let isPicsee = method == "picsee"
            var urls: [URL] = []
            for payload in payloads {
                do {
                    if Task.isCancelled || isCancelled() { throw CancellationError() }
                    urls += try uploadWithCommand([payload], executable: URL(fileURLWithPath: executable),
                                                  arguments: isPicsee ? ["-u"] : ["--output", "url", "--upload"], document: document, isCancelled: isCancelled,
                                                  percentEncodedPaths: !isPicsee, picsee: isPicsee)
                } catch {
                    if isPicsee, let failure = error as? UploadError, case let .picseePartial(current, reason) = failure {
                        throw UploadError.picseePartial(urls.map(\.absoluteString) + current, reason)
                    }
                    guard !urls.isEmpty else { throw error }
                    if isPicsee { throw UploadError.picseePartial(urls.map(\.absoluteString), error.localizedDescription) }
                    throw UploadError.uPicPartial(urls.map(\.absoluteString), error.localizedDescription)
                }
            }
            if Task.isCancelled || isCancelled() {
                if isPicsee { throw UploadError.picseePartial(urls.map(\.absoluteString), L10n.tr("取消")) }
                throw UploadError.uPicPartial(urls.map(\.absoluteString), L10n.tr("取消"))
            }
            return urls
        }
        if method == "command" {
            guard executable.hasPrefix("/") else { throw UploadError.invalidInput }
            let args = arguments.isEmpty ? [] : arguments.components(separatedBy: .newlines)
            return try uploadWithCommand(payloads, executable: URL(fileURLWithPath: executable), arguments: args,
                                         document: document, isCancelled: isCancelled)
        }
        throw UploadError.invalidInput
    }

    static func uploadToPicList(_ payloads: [Payload], endpoint: URL, key: String?, session: URLSession = .shared,
                                isCancelled: () -> Bool = { false }) async throws -> [URL] {
        guard !payloads.isEmpty, var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw UploadError.invalidInput }
        if let key, !key.isEmpty {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "key", value: key))
            components.queryItems = items
        }
        guard let url = components.url else { throw UploadError.invalidInput }
        var result: [URL] = []
        for payload in payloads {
            do {
                try Task.checkCancellation()
                if isCancelled() { throw CancellationError() }
                do { result += try await uploadToPicGo([payload], endpoint: url, session: session, fieldName: "file") }
                catch let UploadError.picListFinalization(id) {
                    if Task.isCancelled || isCancelled() { throw UploadError.picListFinalization(id) }
                    var recovery = components
                    var items = recovery.queryItems ?? []
                    items.append(URLQueryItem(name: "finalizationId", value: id))
                    recovery.queryItems = items
                    guard let recoveryURL = recovery.url else { throw UploadError.picListFinalization(id) }
                    var request = URLRequest(url: recoveryURL)
                    request.httpMethod = "POST"
                    do {
                        let (data, response) = try await session.data(for: request)
                        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              object["success"] as? Bool == true, let urls = object["result"] as? [String] else {
                            throw UploadError.picListFinalization(id)
                        }
                        result += try validURLs(urls, count: 1)
                    } catch { throw UploadError.picListFinalization(id) }
                }
                catch is CancellationError { throw CancellationError() }
                catch let error as UploadError { throw error }
                catch { if Task.isCancelled || isCancelled() { throw CancellationError() }; throw UploadError.serverFailed }
                if isCancelled() { throw CancellationError() }
            } catch {
                guard !result.isEmpty else { throw error }
                throw UploadError.picListPartial(result.map(\.absoluteString), error.localizedDescription)
            }
        }
        return result
    }

    private static func actualMIME(_ data: Data) -> String? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(source) > 0, CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
           let type = CGImageSourceGetType(source), let mime = UTType(type as String)?.preferredMIMEType {
            if mime.lowercased() != "image/svg+xml" { return mime.lowercased() }
        }
        let parser = XMLParser(data: data), validator = SVGRootValidator()
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = validator
        return parser.parse() && validator.validRoot ? "image/svg+xml" : nil
    }

    private static func imageExtension(_ mime: String) -> String? {
        guard let type = UTType(mimeType: mime), type.conforms(to: .image) else { return nil }
        return type.preferredFilenameExtension
    }

    static func validURLs(_ values: [String], count: Int) throws -> [URL] {
        guard count > 0, values.count == count else { throw UploadError.invalidResult }
        return try values.map { value in
            guard !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  let url = URL(string: value), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "file"].contains(scheme),
                  (scheme == "file" ? url.isFileURL && !url.path.isEmpty : url.host != nil) else { throw UploadError.invalidResult }
            return url
        }
    }

    static func uploadToPicGo(_ payloads: [Payload], endpoint: URL, session: URLSession = .shared,
                              fieldName: String = "files") async throws -> [URL] {
        guard !payloads.isEmpty, ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""), endpoint.host != nil else { throw UploadError.invalidInput }
        let boundary = "LacEditor-\(UUID().uuidString)"
        var body = Data()
        func append(_ value: String) { body.append(contentsOf: value.utf8) }
        for payload in payloads {
            guard imageExtension(payload.mime) != nil, !payload.data.isEmpty else { throw UploadError.invalidInput }
            let safeName = payload.filename.replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "\"", with: "_")
                .replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(safeName)\"\r\nContent-Type: \(payload.mime)\r\n\r\n")
            body.append(payload.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UploadError.serverFailed }
        if fieldName == "file", object["success"] as? Bool == false, object["stage"] as? String == "finalization",
           let id = object["finalizationId"] as? String, !id.isEmpty { throw UploadError.picListFinalization(id) }
        guard object["success"] as? Bool == true, let result = object["result"] as? [String] else { throw UploadError.serverFailed }
        return try validURLs(result, count: payloads.count)
    }
}

extension MarkdownImageUploadService {
    static func uploadToIPic(_ payloads: [Payload], start: IPicImageUploadService.Start? = nil,
                             isCancelled: () -> Bool = { false }) async throws -> [URL] {
        guard !payloads.isEmpty else { throw UploadError.invalidInput }
        var urls: [URL] = []
        for payload in payloads {
            do {
                if Task.isCancelled || isCancelled() { throw CancellationError() }
                urls.append(try await IPicImageUploadService.upload(payload, start: start, isCancelled: isCancelled))
                if Task.isCancelled || isCancelled() { throw CancellationError() }
            } catch {
                guard !urls.isEmpty else { throw error }
                throw UploadError.iPicPartial(urls.map(\.absoluteString), error.localizedDescription)
            }
        }
        return urls
    }

    static func uploadWithCommand(_ payloads: [Payload], executable: URL, arguments: [String], document: URL?,
                                  isCancelled: () -> Bool, percentEncodedPaths: Bool = false, picsee: Bool = false) throws -> [URL] {
        guard !payloads.isEmpty, executable.isFileURL else { throw UploadError.invalidInput }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("LacEditor-upload-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        var paths: [String] = []
        for (index, payload) in payloads.enumerated() {
            guard let ext = imageExtension(payload.mime), !payload.data.isEmpty else { throw UploadError.invalidInput }
            let url: URL
            if let local = payload.localURL { url = local }
            else {
                url = directory.appendingPathComponent("\(index).\(ext)")
                try payload.data.write(to: url, options: .atomic)
            }
            if percentEncodedPaths {
                guard let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { throw UploadError.invalidInput }
                paths.append(encoded)
            } else { paths.append(url.path) }
        }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        guard manager.createFile(atPath: stdoutURL.path, contents: nil), manager.createFile(atPath: stderrURL.path, contents: nil) else { throw UploadError.invalidInput }
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }
        let filename = document?.lastPathComponent ?? ""
        let filepath = document?.path ?? ""
        let resolvedArguments = arguments.map { argument in
            var result = "", index = argument.startIndex
            while index < argument.endIndex {
                let suffix = argument[index...]
                if suffix.hasPrefix("${filename}") {
                    result += filename
                    index = argument.index(index, offsetBy: "${filename}".count)
                } else if suffix.hasPrefix("${filepath}") {
                    result += filepath
                    index = argument.index(index, offsetBy: "${filepath}".count)
                } else {
                    result.append(argument[index])
                    index = argument.index(after: index)
                }
            }
            return result
        } + paths
        let status: Int32
        do { status = try runCommand(executable: executable, arguments: resolvedArguments, stdout: stdout, stderr: stderr, isCancelled: isCancelled) }
        catch is CancellationError {
            if percentEncodedPaths || picsee {
                try stdout.synchronize()
                let output = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
                var lines = output.components(separatedBy: .newlines)
                while lines.last == "" { lines.removeLast() }
                if lines.count >= 2, lines[lines.count - 2] == "Output URL:",
                   let urls = try? validURLs([lines[lines.count - 1]], count: 1) {
                    if picsee { throw UploadError.picseePartial(urls.map(\.absoluteString), L10n.tr("取消")) }
                    throw UploadError.uPicPartial(urls.map(\.absoluteString), L10n.tr("取消"))
                }
            }
            throw CancellationError()
        }
        try stdout.synchronize()
        try stderr.synchronize()
        let output = try String(contentsOf: stdoutURL, encoding: .utf8)
        if status != 0 {
            let diagnostics = try String(contentsOf: stderrURL, encoding: .utf8)
            if picsee {
                var lines = output.components(separatedBy: .newlines)
                while lines.last == "" { lines.removeLast() }
                if lines.count >= 2, lines[lines.count - 2] == "Output URL:",
                   let urls = try? validURLs([lines[lines.count - 1]], count: 1) {
                    throw UploadError.picseePartial(urls.map(\.absoluteString), diagnostics.isEmpty ? L10n.tr("上传服务返回错误") : diagnostics)
                }
            }
            throw UploadError.commandFailed([output, diagnostics].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        var lines = output.components(separatedBy: .newlines)
        while lines.last == "" { lines.removeLast() }
        if picsee {
            guard lines.count >= 2, lines[lines.count - 2] == "Output URL:" else { throw UploadError.invalidResult }
        }
        guard lines.count >= payloads.count else { throw UploadError.invalidResult }
        return try validURLs(Array(lines.suffix(payloads.count)), count: payloads.count)
    }

    private static func runCommand(executable: URL, arguments: [String], stdout: FileHandle, stderr: FileHandle,
                                   isCancelled: () -> Bool) throws -> Int32 {
        func check(_ code: Int32) throws {
            if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
        if isCancelled() { throw CancellationError() }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, stdout.fileDescriptor, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr.fileDescriptor, STDERR_FILENO))
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var argv = ([executable.path] + arguments).map { strdup($0) }
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM)) }
        argv.append(nil)
        environment.append(nil)
        var pid: pid_t = 0
        if isCancelled() { throw CancellationError() }
        let result = executable.path.withCString { path in
            argv.withUnsafeMutableBufferPointer { buffer in
                environment.withUnsafeMutableBufferPointer { env in
                    posix_spawn(&pid, path, &actions, &attributes, buffer.baseAddress!, env.baseAddress!)
                }
            }
        }
        try check(result)
        var status: Int32 = 0
        while true {
            if isCancelled() {
                _ = kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                throw CancellationError()
            }
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited < 0 && errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if isCancelled() { throw CancellationError() }
        return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
}
