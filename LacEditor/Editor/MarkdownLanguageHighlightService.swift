import Foundation
import JavaScriptCore

/// Uses bundled language modes only; Markdown and code are passed as data.
enum MarkdownLanguageHighlightService {
    private static func resourceRoot() -> URL? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        return bundle.resourceURL
    }

    static func tokens(in text: String, language: String, isCancelled: @escaping () -> Bool) -> [SyntaxHighlighter.Token]? {
        guard !isCancelled(), let root = resourceRoot() else { return nil }
        let cmDirectory = root.appendingPathComponent("CodeMirror", isDirectory: true)
        let hlDirectory = root.appendingPathComponent("HighlightJS", isDirectory: true)
        let prismDirectory = root.appendingPathComponent("PrismJS", isDirectory: true)
        guard let data = try? Data(contentsOf: cmDirectory.appendingPathComponent("languages.json")),
              let languages = try? JSONDecoder().decode([String: Language].self, from: data),
              let additionalData = try? Data(contentsOf: hlDirectory.appendingPathComponent("languages.json")),
              let additional = try? JSONDecoder().decode([String: String].self, from: additionalData),
              let prismData = try? Data(contentsOf: prismDirectory.appendingPathComponent("languages.json")),
              let prism = try? JSONDecoder().decode([String: String].self, from: prismData) else { return nil }
        let name = language.lowercased()
        let config = languages[name], highlightName = additional[name], prismName = prism[name]
        guard config != nil || highlightName != nil || prismName != nil else { return nil }
        let isPrism = config == nil && highlightName == nil
        let isHighlight = config == nil && !isPrism
        let directory = isPrism ? prismDirectory : (isHighlight ? hlDirectory : cmDirectory)
        guard let runner = try? String(contentsOf: directory.appendingPathComponent("runner.js"), encoding: .utf8),
              let context = JSContext() else { return nil }
        let read: @convention(block) (NSString) -> NSString? = { key in
            if isCancelled() { return nil }
            let value = key as String
            let path = !isHighlight && !isPrism && value == "core" ? "addon/runmode/runmode.node" : value
            let allowed = path.split(separator: "/").allSatisfy { part in
                !part.isEmpty && part != "." && part != ".." && part.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0)
                }
            }
            let known = isPrism ? ["prism-core", "prism-clike", "prism-solidity", "prism-v"].contains(path)
                : (isHighlight ? (path == "core" || path.hasPrefix("languages/"))
                   : (path.hasPrefix("mode/") || path.hasPrefix("addon/mode/") || path == "addon/runmode/runmode.node"))
            guard allowed, known,
                  let source = try? String(contentsOf: directory.appendingPathComponent(path + ".js"), encoding: .utf8) else { return nil }
            return source as NSString
        }
        let cancelled: @convention(block) () -> Bool = { isCancelled() }
        context.setObject(read, forKeyedSubscript: "readCodeMirrorModule" as NSString)
        context.setObject(cancelled, forKeyedSubscript: "codeMirrorCancelled" as NSString)
        context.setObject(read, forKeyedSubscript: "readHighlightModule" as NSString)
        context.setObject(cancelled, forKeyedSubscript: "highlightCancelled" as NSString)
        context.setObject(read, forKeyedSubscript: "readPrismModule" as NSString)
        context.setObject(cancelled, forKeyedSubscript: "prismCancelled" as NSString)
        context.evaluateScript(runner)
        let function = isPrism ? "prismTokens" : (isHighlight ? "highlightTokens" : "codeMirrorTokens")
        let arguments: [Any] = isPrism ? [prismName ?? "", text]
            : (isHighlight ? [highlightName ?? "", text] : [config?.mode ?? "", config?.mime ?? "", text])
        guard context.exception == nil, !isCancelled(),
              let value = context.objectForKeyedSubscript(function)?.call(withArguments: arguments),
              context.exception == nil, !isCancelled(), let rows = value.toArray() as? [[Any]] else { return nil }
        let source = text as NSString
        func boundary(_ position: Int) -> Bool {
            position == 0 || position == source.length ||
                !((0xd800...0xdbff).contains(source.character(at: position - 1)) && (0xdc00...0xdfff).contains(source.character(at: position)))
        }
        var result: [SyntaxHighlighter.Token] = []
        for row in rows {
            if isCancelled() { return nil }
            guard row.count == 3, let start = (row[0] as? NSNumber)?.intValue,
                  let length = (row[1] as? NSNumber)?.intValue, let style = row[2] as? String,
                  start >= 0, length > 0, start <= source.length, length <= source.length - start else { return nil }
            guard boundary(start), boundary(start + length), let kind = kind(style) else { continue }
            result.append(SyntaxHighlighter.Token(range: NSRange(location: start, length: length), kind: kind))
        }
        return result
    }

    private struct Language: Decodable { let mode: String; let mime: String }

    private static func kind(_ style: String) -> SyntaxHighlighter.TokenKind? {
        for part in style.split(separator: " ") {
            switch part.split(separator: "-").first {
            case "keyword", "operator": return .keyword
            case "string": return .string
            case "number": return .number
            case "atom", "builtin", "built_in", "symbol", "boolean", "constant": return .literal
            case "comment": return .comment
            case "def", "title", "function": return .function
            case "type", "class": return .typeName
            case "punctuation", "bracket": return .punctuation
            case "tag", "meta": return .markup
            case "header", "section": return .heading
            case "strong": return .strong
            case "em": return .emphasis
            case "attribute": return .attribute
            case "property": return .property
            case "variable", "variableName": return .variable
            default: continue
            }
        }
        return nil
    }
}
