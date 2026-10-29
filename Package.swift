// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LacEditor",
    defaultLocalization: "en",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", revision: "49dcadd93161f4a44b4994d3a3e8de9f085aface"),
        .package(url: "https://github.com/jpsim/Yams.git", revision: "a27b21e0c81c5bf42049b897a62aaf387e80f279"),
        .package(
            url: "https://github.com/swiftlang/swift-cmark.git",
            exact: "0.8.0"
        ),
        .package(
            url: "https://github.com/tree-sitter/swift-tree-sitter.git",
            exact: "0.9.0"
        ),
        .package(path: "Vendor/TreeSitterJavaScript"),
        .package(path: "Vendor/TreeSitterTypeScript"),
        .package(path: "Vendor/TreeSitterPython"),
        .package(path: "Vendor/TreeSitterCSS"),
        .package(path: "Vendor/TreeSitterHTML"),
        .package(path: "Vendor/TreeSitterSwift"),
        .package(path: "Vendor/TreeSitterBash"),
        .package(path: "Vendor/TreeSitterYAML"),
        .package(path: "Vendor/TreeSitterC"),
        .package(path: "Vendor/TreeSitterCPP"),
        .package(path: "Vendor/TreeSitterSQL")
    ],
    targets: [
        .executableTarget(
            name: "LacEditor",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterJavaScript", package: "TreeSitterJavaScript"),
                .product(name: "TreeSitterTypeScript", package: "TreeSitterTypeScript"),
                .product(name: "TreeSitterPython", package: "TreeSitterPython"),
                .product(name: "TreeSitterCSS", package: "TreeSitterCSS"),
                .product(name: "TreeSitterHTML", package: "TreeSitterHTML"),
                .product(name: "TreeSitterSwift", package: "TreeSitterSwift"),
                .product(name: "TreeSitterBash", package: "TreeSitterBash"),
                .product(name: "TreeSitterYAML", package: "TreeSitterYAML"),
                .product(name: "TreeSitterC", package: "TreeSitterC"),
                .product(name: "TreeSitterCPP", package: "TreeSitterCPP"),
                .product(name: "TreeSitterSQL", package: "TreeSitterSQL")
            ],
            path: "LacEditor",
            exclude: ["Assets.xcassets", "Info.plist"],
            resources: [.process("zh-Hans.lproj"), .process("en.lproj"), .process("ru.lproj"), .copy("Resources/Pandoc"), .copy("Resources/Mermaid"), .copy("Resources/MathJax"), .copy("Resources/LegacyDiagrams"), .copy("Resources/CodeMirror"), .copy("Resources/HighlightJS"), .copy("Resources/PrismJS"), .copy("Resources/Gemoji"), .copy("Resources/HTML-Entities-LICENSE.txt"), .copy("Resources/Yams-LICENSE.txt"), .copy("Resources/SwiftSoup-LICENSE.txt"), .copy("Resources/iPicUploader-LICENSE.txt")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("WebKit"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Security"),
                .linkedFramework("ImageIO"),
                .linkedFramework("PDFKit"),
                .linkedFramework("AVFoundation")
            ]
        ),
        .testTarget(
            name: "LacEditorTests",
            dependencies: ["LacEditor"],
            path: "LacEditorTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
