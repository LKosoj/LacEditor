import Foundation
import XCTest
@testable import LacEditor

final class SymbolOutlineTests: XCTestCase {
    typealias Row = (String, OutlineSymbol.Kind, Int)

    private func symbols(_ text: String, _ language: EditorLanguage) -> [OutlineSymbol] {
        SymbolOutlineService.symbols(in: text, language: language, isCancelled: { false }) ?? []
    }

    private func outline(_ text: String, _ language: EditorLanguage) -> [Row] {
        symbols(text, language).map { ($0.name, $0.kind, $0.level) }
    }

    private func assertOutline(_ actual: [Row], _ expected: [Row], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.map(\.0), expected.map(\.0), file: file, line: line)
        XCTAssertEqual(actual.map(\.1), expected.map(\.1), file: file, line: line)
        XCTAssertEqual(actual.map(\.2), expected.map(\.2), file: file, line: line)
    }

    func testSidebarUsesSymbolSectionOnlyForNonMarkdown() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sidebar = try String(contentsOf: root.appendingPathComponent("LacEditor/Views/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(sidebar.contains("SymbolOutlineSection(document: document)"))
        XCTAssertTrue(sidebar.contains("} else if let document = appState.selectedDocument, SymbolOutlineService.supports(document.language)"))
        let markdownOutline = try String(contentsOf: root.appendingPathComponent("LacEditor/Views/MarkdownOutlineView.swift"), encoding: .utf8)
        XCTAssertFalse(markdownOutline.contains("SymbolOutline"))
    }

    // MARK: Без Tree-sitter

    func testPlainTextAndMarkdownAreNotSupported() {
        XCTAssertFalse(SymbolOutlineService.supports(.plainText))
        XCTAssertFalse(SymbolOutlineService.supports(.markdown))
        XCTAssertTrue(SymbolOutlineService.supports(.json))
    }

    func testCancellationReturnsNil() {
        XCTAssertNil(SymbolOutlineService.symbols(in: "{\"a\":1}", language: .json, isCancelled: { true }))
        XCTAssertNil(SymbolOutlineService.symbols(in: "function a(){}", language: .javascript, isCancelled: { true }))
    }

    func testCurrentIndexPicksInnermostContainingSymbol() {
        let list = [
            OutlineSymbol(id: 0, name: "K", kind: .classType, level: 0, range: NSRange(location: 10, length: 100)),
            OutlineSymbol(id: 1, name: "m1", kind: .method, level: 1, range: NSRange(location: 20, length: 20)),
            OutlineSymbol(id: 2, name: "m2", kind: .method, level: 1, range: NSRange(location: 60, length: 20))
        ]
        XCTAssertEqual(SymbolOutlineService.currentIndex(in: list, caret: 25), 1)
        XCTAssertEqual(SymbolOutlineService.currentIndex(in: list, caret: 45), 0)
        XCTAssertEqual(SymbolOutlineService.currentIndex(in: list, caret: 70), 2)
        XCTAssertNil(SymbolOutlineService.currentIndex(in: list, caret: 5))
        XCTAssertNil(SymbolOutlineService.currentIndex(in: list, caret: 200))
        XCTAssertEqual(SymbolOutlineService.currentIndex(in: list, caret: 110), 0)
        XCTAssertEqual(SymbolOutlineService.currentIndex(in: list, caret: 40), 1)
    }

    func testFilterIsCaseAndDiacriticInsensitiveAndKeepsOrder() {
        let names = ["Функция", "other", "функция2", "Écran"]
        let list = names.enumerated().map {
            OutlineSymbol(id: $0.offset, name: $0.element, kind: .function, level: 0, range: NSRange(location: $0.offset, length: 1))
        }
        XCTAssertEqual(SymbolOutlineService.filtered(list, query: "ФУН").map(\.name), ["Функция", "функция2"])
        XCTAssertEqual(SymbolOutlineService.filtered(list, query: "ecran").map(\.name), ["Écran"])
        XCTAssertEqual(SymbolOutlineService.filtered(list, query: "").count, 4)
    }

    func testJSONKeysTopTwoLevels() {
        let text = "{\"a\":{\"b\":{\"c\":1}},\"d\":[{\"e\":1}],\"f\":\"x:y\"}"
        let found = symbols(text, .json)
        assertOutline(found.map { ($0.name, $0.kind, $0.level) },
                      [("a", .key, 0), ("b", .key, 1), ("d", .key, 0), ("f", .key, 0)])
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: found[0].range), "\"a\":{\"b\":{\"c\":1}}")
        XCTAssertEqual(ns.substring(with: found[1].range), "\"b\":{\"c\":1}")
        XCTAssertEqual(ns.substring(with: found[3].range), "\"f\":\"x:y\"")
        XCTAssertEqual(found.map(\.id), [0, 1, 2, 3])
    }

    func testJSONEscapedQuotesAndMalformed() {
        let escaped = symbols("{\"k\\\"q\": 1}", .json)
        XCTAssertEqual(escaped.map(\.name), ["k\\\"q"])
        XCTAssertEqual(symbols("{\"a\": 1, \"b", .json).map(\.name), ["a"])
        XCTAssertEqual(symbols("{\"a\": {\"b\": 1", .json).map(\.name), ["a", "b"])
        XCTAssertEqual(symbols("", .json).count, 0)
        XCTAssertEqual(symbols("[{\"a\":1}]", .json).count, 0)
    }

    func testJSONOffsetsWithEmojiAndChinese() {
        let text = "{\"😀\": 1, \"你好\": 2}"
        let found = symbols(text, .json)
        XCTAssertEqual(found.map(\.name), ["😀", "你好"])
        XCTAssertEqual((text as NSString).substring(with: found[1].range), "\"你好\": 2")
    }

#if canImport(SwiftTreeSitter) && canImport(TreeSitterJavaScript) && canImport(TreeSitterTypeScript) && canImport(TreeSitterPython) && canImport(TreeSitterCSS) && canImport(TreeSitterHTML) && canImport(TreeSitterSwift) && canImport(TreeSitterBash) && canImport(TreeSitterYAML) && canImport(TreeSitterC) && canImport(TreeSitterCPP) && canImport(TreeSitterSQL)
    func testJavaScriptFunctionsClassesMethodsAndArrowFunctions() {
        let text = "function a(){ function inner(){} }\nclass B { m(){} static s(){} }\nconst c = () => 1;\nconst d = function(){};\nconst n = 5;\nfunction* g(){}\n"
        assertOutline(outline(text, .javascript), [
            ("a", .function, 0), ("B", .classType, 0), ("m", .method, 1), ("s", .method, 1),
            ("c", .function, 0), ("d", .function, 0), ("g", .function, 0)
        ])
    }

    func testTypeScriptInterfacesTypesEnumsNamespaces() {
        let text = "interface I { x: number }\ntype T = string;\nenum E { A }\nnamespace N { export function f(){} }\nabstract class C { abstract m(): void }\nexport class X {}\n"
        let rows = outline(text, .typescript)
        XCTAssertTrue(rows.contains { $0.0 == "I" && $0.1 == .interface && $0.2 == 0 })
        XCTAssertTrue(rows.contains { $0.0 == "T" && $0.1 == .typeAlias && $0.2 == 0 })
        XCTAssertTrue(rows.contains { $0.0 == "E" && $0.1 == .enumeration && $0.2 == 0 })
        XCTAssertTrue(rows.contains { $0.0 == "N" && $0.1 == .namespace && $0.2 == 0 })
        XCTAssertTrue(rows.contains { $0.0 == "f" && $0.1 == .function && $0.2 == 1 })
        XCTAssertTrue(rows.contains { $0.0 == "C" && $0.1 == .classType && $0.2 == 0 })
        XCTAssertTrue(rows.contains { $0.0 == "X" && $0.1 == .classType && $0.2 == 0 })
    }

    func testPythonClassesMethodsAndDecorators() {
        let text = "@dec\ndef f():\n  def inner(): pass\nclass A:\n  def m(self): pass\n  @staticmethod\n  def s(): pass\n  async def a(self): pass\n"
        let found = symbols(text, .python)
        assertOutline(found.map { ($0.name, $0.kind, $0.level) }, [
            ("f", .function, 0), ("A", .classType, 0), ("m", .method, 1), ("s", .method, 1), ("a", .method, 1)
        ])
        XCTAssertEqual(found[0].range.location, 0)
        XCTAssertEqual(found[3].range.location, (text as NSString).range(of: "@staticmethod").location)
    }

    func testSwiftTypesFunctionsInitializersPropertiesExtensions() {
        let text = "struct S { var x = 1; let y: Int; init() {}; func f() {} }\nclass C { }\nenum E { case a }\nextension S { func g() {} }\nprotocol P {}\ntypealias T = Int\nfunc top() {}\nactor A {}\n"
        assertOutline(outline(text, .swift), [
            ("S", .structure, 0), ("x", .property, 1), ("y", .property, 1), ("init", .initializer, 1), ("f", .method, 1),
            ("C", .classType, 0), ("E", .enumeration, 0), ("S", .extensionType, 0), ("g", .method, 1),
            ("P", .interface, 0), ("T", .typeAlias, 0), ("top", .function, 0), ("A", .classType, 0)
        ])
    }

    func testCFamilyFunctionsStructsClassesEnumsNamespaces() {
        let text = "int f(int a){return a;}\nstruct S { int x; void m(){} };\nclass K { public: K(){} ~K(){} };\nenum class E { A };\nnamespace N { void g(){} }\ntypedef struct { int a; } Pt;\nvoid Foo::bar(){}\nint *p(){return 0;}\nstruct Fwd;\nint proto(int);\n"
        assertOutline(outline(text, .cFamily), [
            ("f", .function, 0), ("S", .structure, 0), ("m", .method, 1), ("K", .classType, 0),
            ("K", .method, 1), ("~K", .method, 1), ("E", .enumeration, 0), ("N", .namespace, 0), ("g", .function, 1),
            ("Pt", .structure, 0), ("Foo::bar", .function, 0), ("p", .function, 0)
        ])
    }

    func testShellFunctions() {
        assertOutline(outline("foo() { echo; }\nfunction bar { echo; }\n", .shell), [("foo", .function, 0), ("bar", .function, 0)])
    }

    func testCSSRulesMediaAndKeyframes() {
        let text = "a, b { color: red }\n@media (min-width: 600px) { .x { top: 0 } }\n@keyframes spin { from { top: 0 } }\n"
        assertOutline(outline(text, .css), [
            ("a, b", .selector, 0), ("@media (min-width: 600px)", .atRule, 0), (".x", .selector, 1), ("@keyframes spin", .atRule, 0)
        ])
    }

    func testHTMLHeadingsAndElementsWithID() {
        let text = "<h1>Title <b>bold</b></h1><div id=\"main\"><h2 id=\"s\">Sub</h2></div><p>x</p><script id=\"z\"></script><h3></h3>"
        assertOutline(outline(text, .html), [("h1 Title bold", .heading, 0), ("div#main", .element, 0), ("h2 Sub", .heading, 1)])
    }

    func testYAMLTopTwoLevelsOnly() {
        let text = "a:\n  b:\n    c: 1\nd: 2\ne:\n  - x: 1\n"
        let rows = outline(text, .yaml)
        assertOutline(rows, [("a", .key, 0), ("b", .key, 1), ("d", .key, 0), ("e", .key, 0)])
    }

    func testSQLCreateStatements() {
        let text = "CREATE TABLE users (id int);\nCREATE VIEW v AS SELECT 1;\nCREATE FUNCTION f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;\nCREATE INDEX idx ON users (id);\nSELECT 1;\n"
        assertOutline(outline(text, .sql), [("users", .table, 0), ("v", .view, 0), ("f", .function, 0), ("idx", .index, 0)])
    }

    func testNamesOffsetsWithEmojiAndChineseBeforeSymbol() {
        let cases: [(EditorLanguage, String, String)] = [
            (.javascript, "// 你好 😀\n", "function f(){}"),
            (.python, "# 你好 😀\n", "def f(): pass"),
            (.swift, "// 你好 😀\n", "func f() {}"),
            (.cFamily, "// 你好 😀\n", "void f(){}"),
            (.shell, "# 你好 😀\n", "f() { echo; }")
        ]
        for (language, prefix, body) in cases {
            let found = symbols(prefix + body, language)
            XCTAssertEqual(found.map(\.name), ["f"], "\(language)")
            XCTAssertEqual(found.first?.range.location, (prefix as NSString).length, "\(language)")
        }
        XCTAssertEqual(symbols("function привет(){}", .javascript).map(\.name), ["привет"])
        XCTAssertEqual(symbols("function 你好(){}", .javascript).map(\.name), ["你好"])
    }

    func testSyntaxErrorKeepsOtherSymbols() {
        let js = symbols("function a(){}\nlet = ;\nclass B {}\nfunction c(){}", .javascript).map(\.name)
        XCTAssertTrue(js.contains("a"))
        XCTAssertTrue(js.contains("B"))
        XCTAssertTrue(js.contains("c"))
        let py = symbols("def f(:\n  pass\nclass A: pass", .python).map(\.name)
        XCTAssertTrue(py.contains("A"))
    }

    func testSymbolsAreInDocumentOrderAndLevelsMatchNesting() {
        let samples: [(EditorLanguage, String)] = [
            (.javascript, "class B { m(){} }\nfunction a(){}\n"),
            (.python, "class A:\n  def m(self): pass\ndef f(): pass\n"),
            (.swift, "struct S { func f() {} }\nfunc g() {}\n"),
            (.cFamily, "namespace N { void g(){} }\nvoid h(){}\n"),
            (.json, "{\"a\":{\"b\":1},\"c\":2}")
        ]
        for (language, text) in samples {
            let found = symbols(text, language)
            XCTAssertFalse(found.isEmpty, "\(language)")
            XCTAssertEqual(found.map(\.id), Array(found.indices), "\(language)")
            XCTAssertEqual(found.map(\.range.location), found.map(\.range.location).sorted(), "\(language)")
            for (index, symbol) in found.enumerated() where symbol.level > 0 {
                XCTAssertGreaterThanOrEqual(found[index - 1].level, symbol.level - 1, "\(language)")
            }
        }
    }

    func testDeepNestingDoesNotCrash() {
        let depth = 5000
        let text = "function a(){" + String(repeating: "{", count: depth) + String(repeating: "}", count: depth) + "}\n"
        XCTAssertNotNil(SymbolOutlineService.symbols(in: text, language: .javascript, isCancelled: { false }))
        let nested = "x = " + String(repeating: "(", count: depth) + "1" + String(repeating: ")", count: depth) + "\nclass K: pass\n"
        XCTAssertNotNil(SymbolOutlineService.symbols(in: nested, language: .python, isCancelled: { false }))
    }
#endif
}
