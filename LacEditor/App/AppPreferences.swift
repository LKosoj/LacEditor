import Combine
import Foundation
import AppKit

/// Every persistent store uses the same namespace. A new bundle identifier
/// alone does not isolate files stored under Application Support.
enum AppEnvironment {
    static let experimentIdentifier = "com.laceditor.ui-experiment"
    static var isExperiment: Bool { Bundle.main.bundleIdentifier == experimentIdentifier }
    static var displayName: String {
        let variant: (english: String, russian: String, chinese: String)?
        switch Bundle.main.bundleIdentifier {
        case experimentIdentifier:
            variant = ("LacEditor Experiment", "LacEditor: экспериментальная версия", "LacEditor 实验版")
        case "com.laceditor.development":
            variant = ("LacEditor Development", "LacEditor: версия для разработки", "LacEditor 开发版")
        case "com.laceditor.acceptance":
            variant = ("LacEditor Acceptance", "LacEditor: приёмочная версия", "LacEditor 验收版")
        default:
            variant = nil
        }

        guard let variant else { return "LacEditor" }
        switch L10n.languageCode {
        case "ru": return variant.russian
        case "zh-Hans": return variant.chinese
        default: return variant.english
        }
    }
    static var experimentIteration: String { Bundle.main.object(forInfoDictionaryKey: "LacEditorExperimentIteration") as? String ?? "UI8" }

    static func dataDirectoryName(for identifier: String?) -> String {
        switch identifier {
        case experimentIdentifier: "LacEditor-UI-Experiment"
        case "com.laceditor.acceptance": "LacEditor-Acceptance"
        case "com.laceditor.development": "LacEditor-Development"
        default: "LacEditor"
        }
    }

    static var dataDirectoryName: String {
        dataDirectoryName(for: Bundle.main.bundleIdentifier)
    }
}

enum WorkspaceExitBehavior: String, CaseIterable, Identifiable {
    case preserveWorkspace
    case askToSave

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preserveWorkspace: L10n.tr("保留工作区并退出")
        case .askToSave: L10n.tr("每次检查未保存文件")
        }
    }
}

struct MarkdownExportProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var enabled: Bool
    var writer: String
    var extensions: [String]
    var rawType: String
    var arguments: String
    var templatePath: String?
    var referenceDocumentPath: String?
    var epubTOCDepth: Int?
    var epubCoverPath: String?
    var kind: String? = nil
    var command: String? = nil
    var commandDestination: String? = nil
    var showCommandOutput: Bool? = nil
    var pdfEngine: String? = nil

    static func standard(_ format: PandocExportFormat) -> Self {
        Self(id: "pandoc.\(format.rawValue)", name: format.title, enabled: true,
             writer: format.writer, extensions: [format.fileExtension], rawType: "", arguments: "",
             templatePath: nil, referenceDocumentPath: nil, epubTOCDepth: nil, epubCoverPath: nil)
    }
    static var defaults: [Self] {
        PandocExportFormat.allCases.filter { $0 != .html && $0 != .htmlPlain && $0 != .pdf }.map(Self.standard)
    }
    static func pdfEngineProfile() -> Self {
        var profile = standard(.pdf)
        profile.id = UUID().uuidString
        profile.name = L10n.tr("PDF（Pandoc / LaTeX）")
        profile.kind = "pdf-engine"
        profile.pdfEngine = ""
        return profile
    }
    static func customCommand() -> Self {
        var profile = standard(.text)
        profile.id = UUID().uuidString
        profile.name = L10n.tr("自定义命令")
        profile.writer = ""
        profile.extensions = []
        profile.kind = "command"
        profile.command = ""
        profile.commandDestination = "file"
        profile.showCommandOutput = false
        return profile
    }
}

struct MarkdownExportConfiguration: Codable, Equatable {
    var profiles: [MarkdownExportProfile]
}

struct MarkdownImageUploadConfiguration: Codable, Equatable {
    var method = "disabled"
    var endpoint = ""
    var executable = ""
    var arguments = ""
    var automaticLocal = false
    var allowDocumentPolicy = false
    var automaticOnline = false
    var allowDocumentCopy = false
    var copyFolder = ""

    private enum CodingKeys: String, CodingKey { case method, endpoint, executable, arguments, automaticLocal, allowDocumentPolicy, automaticOnline, allowDocumentCopy, copyFolder }

    init(method: String = "disabled", endpoint: String = "", executable: String = "", arguments: String = "", automaticLocal: Bool = false, allowDocumentPolicy: Bool = false, automaticOnline: Bool = false, allowDocumentCopy: Bool = false, copyFolder: String = "") {
        self.method = method
        self.endpoint = endpoint
        self.executable = executable
        self.arguments = arguments
        self.automaticLocal = automaticLocal
        self.allowDocumentPolicy = allowDocumentPolicy
        self.automaticOnline = automaticOnline
        self.allowDocumentCopy = allowDocumentCopy
        self.copyFolder = copyFolder
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        method = try values.decodeIfPresent(String.self, forKey: .method) ?? "disabled"
        endpoint = try values.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        executable = try values.decodeIfPresent(String.self, forKey: .executable) ?? ""
        arguments = try values.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        automaticLocal = try values.decodeIfPresent(Bool.self, forKey: .automaticLocal) ?? false
        allowDocumentPolicy = try values.decodeIfPresent(Bool.self, forKey: .allowDocumentPolicy) ?? false
        automaticOnline = try values.decodeIfPresent(Bool.self, forKey: .automaticOnline) ?? false
        allowDocumentCopy = try values.decodeIfPresent(Bool.self, forKey: .allowDocumentCopy) ?? false
        copyFolder = try values.decodeIfPresent(String.self, forKey: .copyFolder) ?? ""
    }
}

struct MarkdownNativeExportOptions: Codable, Equatable {
    var pageBreakTopHeadings: Bool? = nil
    var paper = "a4"
    var paperWidth = 595.28
    var paperHeight = 841.89
    var customMargins = false
    var marginTop = 36.0
    var marginBottom = 36.0
    var marginLeft = 36.0
    var marginRight = 36.0
    var imageWidth = 760.0
    var imageQuality: String? = nil
    var customImageFontSize = false
    var imageFontSize = 24.0
}

struct MarkdownHTMLExportOptions: Codable, Equatable {
    var appendHead = ""
    var appendBody = ""
    var allowDocumentOverrides = false
}

struct MarkdownPDFHeaderFooterOptions: Codable, Equatable {
    var header = ""
    var footer = ""
    var allowDocumentOverrides = false
}

enum StatisticsDisplayUnit: String, CaseIterable, Identifiable {
    case words, characters, charactersWithoutWhitespace, lines, readingMinutes
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .words: L10n.tr("词数")
        case .characters: L10n.tr("字符数")
        case .charactersWithoutWhitespace: L10n.tr("不含空白的字符数")
        case .lines: L10n.tr("行数")
        case .readingMinutes: L10n.tr("预计阅读时间")
        }
    }
}

enum MarkdownMathNumbering: String, Codable, CaseIterable, Sendable { case none, ams, all }
enum MarkdownTextAlignment: String, Codable, CaseIterable, Sendable { case left, center, right, justify }

@MainActor
final class AppPreferences: ObservableObject {
    static let defaultFontSize: CGFloat = 14
    static let defaultLineSpacing = FoldLayoutManager.defaultLineSpacing
    @Published var markdownNumberHeadings: Bool { didSet { defaults.set(markdownNumberHeadings, forKey: Keys.markdownNumberHeadings) } }
    @Published var markdownUppercaseHeadingLevels: Set<Int> {
        didSet {
            let valid = Set(markdownUppercaseHeadingLevels.filter { (1...6).contains($0) })
            guard valid == markdownUppercaseHeadingLevels else { markdownUppercaseHeadingLevels = valid; return }
            defaults.set(valid.sorted(), forKey: Keys.markdownUppercaseHeadingLevels)
        }
    }
    @Published var markdownListStyles: MarkdownListStyles {
        didSet {
            if let data = try? JSONEncoder().encode(markdownListStyles) { defaults.set(data, forKey: Keys.markdownListStyles) }
        }
    }

    @Published var markdownStrictMode: Bool { didSet { defaults.set(markdownStrictMode, forKey: Keys.markdownStrictMode) } }
    @Published var markdownInlineMath: Bool { didSet { defaults.set(markdownInlineMath, forKey: Keys.markdownInlineMath) } }
    @Published var markdownLegacyInlineMath: Bool { didSet { defaults.set(markdownLegacyInlineMath, forKey: Keys.markdownLegacyInlineMath) } }
    @Published var markdownSmartPunctuation: Bool? {
        didSet {
            if let markdownSmartPunctuation { defaults.set(markdownSmartPunctuation, forKey: Keys.markdownSmartPunctuation) }
            else { defaults.removeObject(forKey: Keys.markdownSmartPunctuation) }
        }
    }
    @Published var markdownEditingWhitespace: Bool? {
        didSet {
            if let markdownEditingWhitespace { defaults.set(markdownEditingWhitespace, forKey: Keys.markdownEditingWhitespace) }
            else { defaults.removeObject(forKey: Keys.markdownEditingWhitespace) }
        }
    }
    @Published var markdownExportWhitespace: Bool { didSet { defaults.set(markdownExportWhitespace, forKey: Keys.markdownExportWhitespace) } }
    @Published var markdownEditingSoftBreaks: Bool { didSet { defaults.set(markdownEditingSoftBreaks, forKey: Keys.markdownEditingSoftBreaks) } }
    @Published var markdownExportSoftBreaks: Bool? {
        didSet {
            if let markdownExportSoftBreaks { defaults.set(markdownExportSoftBreaks, forKey: Keys.markdownExportSoftBreaks) }
            else { defaults.removeObject(forKey: Keys.markdownExportSoftBreaks) }
        }
    }

    var markdownSyntax: MarkdownSyntaxOptions {
        MarkdownSyntaxOptions(strictMode: markdownStrictMode, inlineMath: markdownInlineMath, legacyInlineMath: markdownLegacyInlineMath,
                              smartPunctuation: markdownSmartPunctuation, preserveEditingWhitespace: markdownEditingWhitespace,
                              preserveExportWhitespace: markdownExportWhitespace, preserveEditingSoftBreaks: markdownEditingSoftBreaks,
                              preserveExportSoftBreaks: markdownExportSoftBreaks)
    }

    @Published var markdownTextAlignment: MarkdownTextAlignment? {
        didSet {
            if let markdownTextAlignment { defaults.set(markdownTextAlignment.rawValue, forKey: Keys.markdownTextAlignment) }
            else { defaults.removeObject(forKey: Keys.markdownTextAlignment) }
        }
    }
    @Published var markdownRightToLeft: Bool {
        didSet { defaults.set(markdownRightToLeft, forKey: Keys.markdownRightToLeft) }
    }
    @Published var markdownVerticalWriting: Bool {
        didSet { defaults.set(markdownVerticalWriting, forKey: Keys.markdownVerticalWriting) }
    }
    @Published var markdownStrikeCompletedTasks: Bool {
        didSet { defaults.set(markdownStrikeCompletedTasks, forKey: Keys.markdownStrikeCompletedTasks) }
    }
    @Published var markdownParagraphSpacing: Double? {
        didSet {
            guard markdownParagraphSpacing.map({ $0.isFinite && $0 >= 0 }) ?? true else { markdownParagraphSpacing = oldValue; return }
            if let markdownParagraphSpacing { defaults.set(markdownParagraphSpacing, forKey: Keys.markdownParagraphSpacing) }
            else { defaults.removeObject(forKey: Keys.markdownParagraphSpacing) }
        }
    }

    @Published var markdownSmallCapsLevels: Set<Int> {
        didSet {
            let valid = Set(markdownSmallCapsLevels.filter { (1...6).contains($0) })
            guard valid == markdownSmallCapsLevels else { markdownSmallCapsLevels = valid; return }
            defaults.set(valid.sorted(), forKey: Keys.markdownSmallCapsLevels)
        }
    }

    @Published var markdownCenteredHeadingLevels: Set<Int> {
        didSet {
            let valid = Set(markdownCenteredHeadingLevels.filter { (1...6).contains($0) })
            guard valid == markdownCenteredHeadingLevels else { markdownCenteredHeadingLevels = valid; return }
            defaults.set(valid.sorted(), forKey: Keys.markdownCenteredHeadingLevels)
        }
    }

    @Published var editorLigatures: Int? {
        didSet {
            guard editorLigatures.map({ (0...2).contains($0) }) ?? true else { editorLigatures = oldValue; return }
            if let editorLigatures { defaults.set(editorLigatures, forKey: Keys.editorLigatures) }
            else { defaults.removeObject(forKey: Keys.editorLigatures) }
        }
    }

    @Published var markdownTOCMaxLevel: Int {
        didSet {
            guard (1...6).contains(markdownTOCMaxLevel) else { markdownTOCMaxLevel = oldValue; return }
            defaults.set(markdownTOCMaxLevel, forKey: Keys.markdownTOCMaxLevel)
        }
    }

    @Published var markdownLightColors: MarkdownColorOverrides {
        didSet { if let data = try? JSONEncoder().encode(markdownLightColors) { defaults.set(data, forKey: Keys.markdownLightColors) } }
    }
    @Published var markdownDarkColors: MarkdownColorOverrides {
        didSet { if let data = try? JSONEncoder().encode(markdownDarkColors) { defaults.set(data, forKey: Keys.markdownDarkColors) } }
    }

    func markdownColors(darkMode: Bool) -> MarkdownColorOverrides { darkMode ? markdownDarkColors : markdownLightColors }

    @Published var markdownMaximumWidth: Double? {
        didSet {
            if let value = markdownMaximumWidth, !value.isFinite || value <= 0 {
                markdownMaximumWidth = oldValue
                return
            }
            defaults.set(markdownMaximumWidth, forKey: Keys.markdownMaximumWidth)
        }
    }

    @Published var statisticsDisplayUnit: StatisticsDisplayUnit {
        didSet { defaults.set(statisticsDisplayUnit.rawValue, forKey: Keys.statisticsDisplayUnit) }
    }
    @Published var readingWordsPerMinute: Int {
        didSet {
            guard readingWordsPerMinute > 0 else { readingWordsPerMinute = oldValue; return }
            defaults.set(readingWordsPerMinute, forKey: Keys.readingWordsPerMinute)
        }
    }

    @Published var markdownHTMLExportOptions: MarkdownHTMLExportOptions {
        didSet {
            if let data = try? JSONEncoder().encode(markdownHTMLExportOptions) {
                defaults.set(data, forKey: Keys.markdownHTMLExportOptions)
            }
        }
    }

    @Published var markdownPDFHeaderFooterOptions: MarkdownPDFHeaderFooterOptions {
        didSet {
            if let data = try? JSONEncoder().encode(markdownPDFHeaderFooterOptions) {
                defaults.set(data, forKey: Keys.markdownPDFHeaderFooterOptions)
            }
        }
    }

    @Published var markdownNativeExportOptions: MarkdownNativeExportOptions {
        didSet {
            if let data = try? JSONEncoder().encode(markdownNativeExportOptions) {
                defaults.set(data, forKey: Keys.markdownNativeExportOptions)
            }
        }
    }

    @Published var markdownImageUploadConfiguration: MarkdownImageUploadConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(markdownImageUploadConfiguration) {
                defaults.set(data, forKey: Keys.markdownImageUploadConfiguration)
            }
        }
    }

    @Published var markdownExportConfiguration: MarkdownExportConfiguration {
        didSet { saveMarkdownExportConfiguration() }
    }
    private(set) var invalidMarkdownExportConfiguration = false
    private var exportUnknownEntries: [(Int, Any)] = []
    private var exportOriginalEntries: [String: [String: Any]] = [:]
    private var exportOriginalRoot: [String: Any] = [:]
    var unsupportedMarkdownExportEntryCount: Int { exportUnknownEntries.count }

    @Published var wordWrapEnabled: Bool {
        didSet { defaults.set(wordWrapEnabled, forKey: Keys.wordWrap) }
    }
    @Published var editorFontSize: CGFloat {
        didSet {
            let clamped = min(max(editorFontSize, 9), 32)
            if clamped != editorFontSize {
                editorFontSize = clamped
                return
            }
            defaults.set(Double(editorFontSize), forKey: Keys.fontSize)
            defaults.set(true, forKey: Keys.markdownTypographyCustomized)
        }
    }
    @Published var editorLineSpacing: CGFloat {
        didSet {
            let clamped = min(max(editorLineSpacing, 0), 10)
            if clamped != editorLineSpacing {
                editorLineSpacing = clamped
                return
            }
            defaults.set(Double(editorLineSpacing), forKey: Keys.lineSpacing)
            defaults.set(true, forKey: Keys.markdownTypographyCustomized)
        }
    }
    @Published var editorTextFontFamily: String? {
        didSet {
            defaults.set(editorTextFontFamily, forKey: Keys.editorTextFontFamily)
            defaults.set(true, forKey: Keys.markdownTypographyCustomized)
        }
    }
    @Published var editorCodeFontFamily: String? {
        didSet {
            defaults.set(editorCodeFontFamily, forKey: Keys.editorCodeFontFamily)
            defaults.set(true, forKey: Keys.markdownTypographyCustomized)
        }
    }
    @Published var indentationStyle: IndentationStyle {
        didSet { defaults.set(indentationStyle.rawValue, forKey: Keys.indentationStyle) }
    }
    @Published var tabWidth: Int {
        didSet {
            let clamped = [2, 4, 8].contains(tabWidth) ? tabWidth : 4
            if clamped != tabWidth {
                tabWidth = clamped
                return
            }
            defaults.set(tabWidth, forKey: Keys.tabWidth)
        }
    }
    @Published var lineNumbersVisible: Bool {
        didSet { defaults.set(lineNumbersVisible, forKey: Keys.lineNumbers) }
    }
    @Published var statusBarVisible: Bool {
        didSet { defaults.set(statusBarVisible, forKey: Keys.statusBar) }
    }
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }
    @Published var workspaceExitBehavior: WorkspaceExitBehavior {
        didSet {
            defaults.set(workspaceExitBehavior.rawValue, forKey: Keys.exitBehavior)
        }
    }
    @Published var startupFolderPath: String {
        didSet { defaults.set(startupFolderPath, forKey: Keys.startupFolderPath) }
    }
    @Published var aiConfiguration: AIConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(aiConfiguration) {
                defaults.set(data, forKey: Keys.aiConfiguration)
            }
        }
    }
    @Published var jinaConfiguration: JinaConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(jinaConfiguration) {
                defaults.set(data, forKey: Keys.jinaConfiguration)
            }
        }
    }

    @Published var aiFeatures: Set<AIFeature> {
        didSet {
            let values = aiFeatures.map(\.rawValue).sorted()
            if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Keys.aiFeatures) }
        }
    }
    @Published var aiFeatureModelIDs: [String: String] {
        didSet { defaults.set(aiFeatureModelIDs, forKey: Keys.aiFeatureModelIDs) }
    }
    @Published var aiCustomChecks: [AICustomCheck] {
        didSet {
            if let data = try? JSONEncoder().encode(aiCustomChecks) { defaults.set(data, forKey: Keys.aiCustomChecks) }
        }
    }
    @Published var aiBackgroundEnabled: Bool {
        didSet { defaults.set(aiBackgroundEnabled, forKey: Keys.aiBackgroundEnabled) }
    }
    @Published var autoPairBracketsEnabled: Bool {
        didSet { defaults.set(autoPairBracketsEnabled, forKey: Keys.autoPairBracketsEnabled) }
    }
    @Published var autoPairMarkdownEnabled: Bool {
        didSet { defaults.set(autoPairMarkdownEnabled, forKey: Keys.autoPairMarkdownEnabled) }
    }
    @Published var smartQuotesEnabled: Bool {
        didSet { defaults.set(smartQuotesEnabled, forKey: Keys.smartQuotesEnabled) }
    }
    @Published var smartDashesEnabled: Bool {
        didSet { defaults.set(smartDashesEnabled, forKey: Keys.smartDashesEnabled) }
    }
    @Published var systemTextReplacementEnabled: Bool {
        didSet { defaults.set(systemTextReplacementEnabled, forKey: Keys.systemTextReplacementEnabled) }
    }
    @Published var mathPhysicsEnabled: Bool {
        didSet { defaults.set(mathPhysicsEnabled, forKey: Keys.mathPhysicsEnabled) }
    }
    @Published var mathNumbering: MarkdownMathNumbering {
        didSet { defaults.set(mathNumbering.rawValue, forKey: Keys.mathNumbering) }
    }
    @Published var systemSpellingEnabled: Bool {
        didSet { defaults.set(systemSpellingEnabled, forKey: Keys.systemSpellingEnabled) }
    }
    @Published var systemGrammarEnabled: Bool {
        didSet { defaults.set(systemGrammarEnabled, forKey: Keys.systemGrammarEnabled) }
    }

    private let defaults: UserDefaults

    var markdownTypography: MarkdownTypography? {
        let customMetrics = defaults.bool(forKey: Keys.markdownTypographyCustomized)
        guard customMetrics || markdownMaximumWidth != nil || markdownTOCMaxLevel != 6 || editorLigatures != nil || !markdownSmallCapsLevels.isEmpty || !markdownUppercaseHeadingLevels.isEmpty || !markdownCenteredHeadingLevels.isEmpty || markdownTextAlignment != nil || markdownRightToLeft || markdownVerticalWriting || markdownStrikeCompletedTasks || markdownNumberHeadings || !markdownListStyles.ordered.isEmpty || !markdownListStyles.unordered.isEmpty || markdownParagraphSpacing != nil || !markdownLightColors.isEmpty || !markdownDarkColors.isEmpty else { return nil }
        let font = Self.textFont(family: editorTextFontFamily, size: editorFontSize)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font) + editorLineSpacing
        let textFamily = Self.availableFont(family: editorTextFontFamily, size: editorFontSize)?.familyName
        let codeFamily = Self.availableFont(family: editorCodeFontFamily, size: editorFontSize)?.familyName
        return MarkdownTypography(fontSize: Double(editorFontSize), lineHeight: Double(lineHeight),
                                  textFamily: textFamily, codeFamily: codeFamily, maximumWidth: markdownMaximumWidth, usesCustomFontMetrics: customMetrics,
                                  tocMaxLevel: markdownTOCMaxLevel, ligatures: editorLigatures, smallCapsLevels: markdownSmallCapsLevels, centeredHeadingLevels: markdownCenteredHeadingLevels,
                                  textAlignment: markdownTextAlignment?.rawValue, rightToLeft: markdownRightToLeft, verticalWriting: markdownVerticalWriting, strikeCompletedTasks: markdownStrikeCompletedTasks, numberHeadings: markdownNumberHeadings, paragraphSpacing: markdownParagraphSpacing,
                                  listStyles: markdownListStyles, uppercaseHeadingLevels: markdownUppercaseHeadingLevels, lightColors: markdownLightColors, darkColors: markdownDarkColors)
    }

    static func availableFont(family: String?, size: CGFloat) -> NSFont? {
        guard let family, !family.isEmpty else { return nil }
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    }

    static func textFont(family: String?, size: CGFloat) -> NSFont {
        availableFont(family: family, size: size) ?? lacEditorFont(size: size)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        markdownNumberHeadings = defaults.bool(forKey: Keys.markdownNumberHeadings)
        markdownUppercaseHeadingLevels = Set((defaults.array(forKey: Keys.markdownUppercaseHeadingLevels) as? [Int] ?? []).filter { (1...6).contains($0) })
        markdownListStyles = defaults.data(forKey: Keys.markdownListStyles)
            .flatMap { try? JSONDecoder().decode(MarkdownListStyles.self, from: $0) } ?? .init()
        markdownStrictMode = (defaults.object(forKey: Keys.markdownStrictMode) as? Bool) ?? true
        markdownInlineMath = (defaults.object(forKey: Keys.markdownInlineMath) as? Bool) ?? true
        markdownLegacyInlineMath = defaults.bool(forKey: Keys.markdownLegacyInlineMath)
        markdownSmartPunctuation = defaults.object(forKey: Keys.markdownSmartPunctuation) as? Bool
        markdownEditingWhitespace = defaults.object(forKey: Keys.markdownEditingWhitespace) as? Bool
        markdownExportWhitespace = defaults.bool(forKey: Keys.markdownExportWhitespace)
        markdownEditingSoftBreaks = (defaults.object(forKey: Keys.markdownEditingSoftBreaks) as? Bool) ?? true
        markdownExportSoftBreaks = defaults.object(forKey: Keys.markdownExportSoftBreaks) as? Bool
        markdownTextAlignment = defaults.string(forKey: Keys.markdownTextAlignment).flatMap(MarkdownTextAlignment.init(rawValue:))
        markdownRightToLeft = defaults.bool(forKey: Keys.markdownRightToLeft)
        markdownVerticalWriting = defaults.bool(forKey: Keys.markdownVerticalWriting)
        markdownStrikeCompletedTasks = defaults.bool(forKey: Keys.markdownStrikeCompletedTasks)
        let savedParagraphSpacing = (defaults.object(forKey: Keys.markdownParagraphSpacing) as? NSNumber)?.doubleValue
        markdownParagraphSpacing = savedParagraphSpacing.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        markdownSmallCapsLevels = Set((defaults.array(forKey: Keys.markdownSmallCapsLevels) as? [Int] ?? []).filter { (1...6).contains($0) })
        markdownCenteredHeadingLevels = Set((defaults.array(forKey: Keys.markdownCenteredHeadingLevels) as? [Int] ?? []).filter { (1...6).contains($0) })
        let savedLigatures = (defaults.object(forKey: Keys.editorLigatures) as? NSNumber)?.intValue
        editorLigatures = savedLigatures.flatMap { (0...2).contains($0) ? $0 : nil }
        let savedTOCLevel = defaults.integer(forKey: Keys.markdownTOCMaxLevel)
        markdownTOCMaxLevel = (1...6).contains(savedTOCLevel) ? savedTOCLevel : 6
        markdownLightColors = defaults.data(forKey: Keys.markdownLightColors).flatMap { try? JSONDecoder().decode(MarkdownColorOverrides.self, from: $0) } ?? MarkdownColorOverrides()
        markdownDarkColors = defaults.data(forKey: Keys.markdownDarkColors).flatMap { try? JSONDecoder().decode(MarkdownColorOverrides.self, from: $0) } ?? MarkdownColorOverrides()
        let savedWidth = (defaults.object(forKey: Keys.markdownMaximumWidth) as? NSNumber)?.doubleValue
        markdownMaximumWidth = savedWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        statisticsDisplayUnit = StatisticsDisplayUnit(rawValue: defaults.string(forKey: Keys.statisticsDisplayUnit) ?? "") ?? .words
        let readingSpeed = defaults.integer(forKey: Keys.readingWordsPerMinute)
        readingWordsPerMinute = readingSpeed > 0 ? readingSpeed : 200
        markdownHTMLExportOptions = defaults.data(forKey: Keys.markdownHTMLExportOptions)
            .flatMap { try? JSONDecoder().decode(MarkdownHTMLExportOptions.self, from: $0) }
            ?? MarkdownHTMLExportOptions()
        markdownPDFHeaderFooterOptions = defaults.data(forKey: Keys.markdownPDFHeaderFooterOptions)
            .flatMap { try? JSONDecoder().decode(MarkdownPDFHeaderFooterOptions.self, from: $0) }
            ?? MarkdownPDFHeaderFooterOptions()
        markdownNativeExportOptions = defaults.data(forKey: Keys.markdownNativeExportOptions)
            .flatMap { try? JSONDecoder().decode(MarkdownNativeExportOptions.self, from: $0) }
            ?? MarkdownNativeExportOptions()
        markdownImageUploadConfiguration = defaults.data(forKey: Keys.markdownImageUploadConfiguration)
            .flatMap { try? JSONDecoder().decode(MarkdownImageUploadConfiguration.self, from: $0) }
            ?? MarkdownImageUploadConfiguration()
        markdownExportConfiguration = MarkdownExportConfiguration(profiles: MarkdownExportProfile.defaults)
        editorTextFontFamily = defaults.string(forKey: Keys.editorTextFontFamily)
        editorCodeFontFamily = defaults.string(forKey: Keys.editorCodeFontFamily)
        jinaConfiguration = defaults.data(forKey: Keys.jinaConfiguration)
            .flatMap { try? JSONDecoder().decode(JinaConfiguration.self, from: $0) }
            ?? JinaConfiguration()
        let features = defaults.data(forKey: Keys.aiFeatures)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        aiFeatures = Set(features.compactMap(AIFeature.init(rawValue:)))
        aiFeatureModelIDs = defaults.dictionary(forKey: Keys.aiFeatureModelIDs) as? [String: String] ?? [:]
        aiCustomChecks = defaults.data(forKey: Keys.aiCustomChecks)
            .flatMap { try? JSONDecoder().decode([AICustomCheck].self, from: $0) } ?? []
        aiBackgroundEnabled = defaults.bool(forKey: Keys.aiBackgroundEnabled)
        autoPairBracketsEnabled = defaults.bool(forKey: Keys.autoPairBracketsEnabled)
        autoPairMarkdownEnabled = defaults.bool(forKey: Keys.autoPairMarkdownEnabled)
        smartQuotesEnabled = defaults.bool(forKey: Keys.smartQuotesEnabled)
        smartDashesEnabled = defaults.bool(forKey: Keys.smartDashesEnabled)
        systemTextReplacementEnabled = defaults.bool(forKey: Keys.systemTextReplacementEnabled)
        mathPhysicsEnabled = defaults.object(forKey: Keys.mathPhysicsEnabled) as? Bool ?? true
        mathNumbering = MarkdownMathNumbering(rawValue: defaults.string(forKey: Keys.mathNumbering) ?? "") ?? .none
        systemSpellingEnabled = defaults.bool(forKey: Keys.systemSpellingEnabled)
        systemGrammarEnabled = defaults.bool(forKey: Keys.systemGrammarEnabled)
        aiConfiguration = defaults.data(forKey: Keys.aiConfiguration)
            .flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) }
            ?? AIConfiguration()
        wordWrapEnabled = defaults.object(forKey: Keys.wordWrap) as? Bool ?? true
        let storedFontSize = defaults.object(forKey: Keys.fontSize) as? Double
        editorFontSize = min(
            max(CGFloat(storedFontSize ?? Double(Self.defaultFontSize)), 9),
            32
        )
        let storedLineSpacing = defaults.object(forKey: Keys.lineSpacing) as? Double
        editorLineSpacing = min(
            max(
                CGFloat(storedLineSpacing ?? Double(Self.defaultLineSpacing)),
                0
            ),
            10
        )
        indentationStyle = IndentationStyle(
            rawValue: defaults.string(forKey: Keys.indentationStyle) ?? ""
        ) ?? .spaces
        let storedTabWidth = defaults.integer(forKey: Keys.tabWidth)
        tabWidth = [2, 4, 8].contains(storedTabWidth) ? storedTabWidth : 4
        lineNumbersVisible = defaults.object(forKey: Keys.lineNumbers) as? Bool ?? true
        statusBarVisible = defaults.object(forKey: Keys.statusBar) as? Bool ?? true
        let storedTheme = defaults.string(forKey: Keys.theme)
        theme = AppTheme(rawValue: storedTheme ?? "") ?? .system
        let storedExitBehavior = defaults.string(forKey: Keys.exitBehavior)
        workspaceExitBehavior = WorkspaceExitBehavior(
            rawValue: storedExitBehavior ?? ""
        ) ?? .preserveWorkspace
        startupFolderPath = defaults.string(forKey: Keys.startupFolderPath) ?? ""
        loadMarkdownExportConfiguration()
    }

    private func loadMarkdownExportConfiguration() {
        guard let data = defaults.data(forKey: Keys.markdownExportConfiguration) else { return }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["profiles"] as? [Any] else {
            invalidMarkdownExportConfiguration = true
            return
        }
        exportOriginalRoot = root
        var profiles: [MarkdownExportProfile] = []
        var seen = Set<String>()
        for (index, entry) in entries.enumerated() {
            guard let object = entry as? [String: Any], JSONSerialization.isValidJSONObject(object),
                  object["kind"] == nil || ["pandoc", "command", "pdf-engine"].contains(object["kind"] as? String ?? ""),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let profile = try? JSONDecoder().decode(MarkdownExportProfile.self, from: data),
                  !profile.id.isEmpty, seen.insert(profile.id).inserted else {
                exportUnknownEntries.append((index, entry)); continue
            }
            exportOriginalEntries[profile.id] = object
            profiles.append(profile)
        }
        markdownExportConfiguration = MarkdownExportConfiguration(profiles: profiles)
    }

    private func saveMarkdownExportConfiguration() {
        guard !invalidMarkdownExportConfiguration else { return }
        var entries: [Any] = markdownExportConfiguration.profiles.compactMap { profile in
            guard let data = try? JSONEncoder().encode(profile),
                  let encoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            var merged = exportOriginalEntries[profile.id] ?? [:]
            for key in ["templatePath", "referenceDocumentPath", "epubTOCDepth", "epubCoverPath", "kind", "command", "commandDestination", "showCommandOutput", "pdfEngine"] { merged.removeValue(forKey: key) }
            for (key, value) in encoded { merged[key] = value }
            return merged
        }
        for (index, entry) in exportUnknownEntries { entries.insert(entry, at: min(index, entries.count)) }
        var root = exportOriginalRoot
        root["profiles"] = entries
        if let data = try? JSONSerialization.data(withJSONObject: root) {
            defaults.set(data, forKey: Keys.markdownExportConfiguration)
        }
    }

    func resetMarkdownExportConfiguration() {
        invalidMarkdownExportConfiguration = false
        exportUnknownEntries.removeAll()
        exportOriginalEntries.removeAll()
        exportOriginalRoot.removeAll()
        markdownExportConfiguration = MarkdownExportConfiguration(profiles: MarkdownExportProfile.defaults)
    }

    func removeUnsupportedMarkdownExportEntries() {
        exportUnknownEntries.removeAll()
        saveMarkdownExportConfiguration()
        objectWillChange.send()
    }

    func aiProfile(for feature: AIFeature, customCheck: AICustomCheck? = nil) -> AIModelProfile {
        var profile = aiConfiguration[feature.role]
        let featureModel = aiFeatureModelIDs[feature.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !featureModel.isEmpty { profile.modelID = featureModel }
        if feature == .customCheck {
            let checkModel = customCheck?.modelID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !checkModel.isEmpty { profile.modelID = checkModel }
        }
        return profile
    }

    var hasConfirmedWorkspaceExitPrompt: Bool {
        defaults.bool(forKey: Keys.confirmedWorkspaceExitPrompt)
    }

    func confirmWorkspaceExitPrompt() {
        defaults.set(true, forKey: Keys.confirmedWorkspaceExitPrompt)
    }

    private enum Keys {
        static let markdownNumberHeadings = "markdownNumberHeadings"
        static let markdownUppercaseHeadingLevels = "markdownUppercaseHeadingLevels"
        static let markdownListStyles = "markdownListStyles"
        static let markdownStrictMode = "markdownStrictMode"
        static let markdownInlineMath = "markdownInlineMath"
        static let markdownLegacyInlineMath = "markdownLegacyInlineMath"
        static let markdownSmartPunctuation = "markdownSmartPunctuation"
        static let markdownEditingWhitespace = "markdownEditingWhitespace"
        static let markdownExportWhitespace = "markdownExportWhitespace"
        static let markdownEditingSoftBreaks = "markdownEditingSoftBreaks"
        static let markdownExportSoftBreaks = "markdownExportSoftBreaks"
        static let wordWrap = "isWordWrapEnabled"
        static let editorLigatures = "editorLigatures"
        static let markdownSmallCapsLevels = "markdownSmallCapsLevels"
        static let markdownCenteredHeadingLevels = "markdownCenteredHeadingLevels"
        static let markdownTextAlignment = "markdownTextAlignment"
        static let markdownRightToLeft = "markdownRightToLeft"
        static let markdownVerticalWriting = "markdownVerticalWriting"
        static let markdownStrikeCompletedTasks = "markdownStrikeCompletedTasks"
        static let markdownParagraphSpacing = "markdownParagraphSpacing"
        static let markdownTOCMaxLevel = "markdownTOCMaxLevel"
        static let markdownLightColors = "markdownLightColors"
        static let markdownDarkColors = "markdownDarkColors"
        static let markdownMaximumWidth = "markdownMaximumWidth"
        static let fontSize = "editorFontSize"
        static let lineSpacing = "editorLineSpacing"
        static let indentationStyle = "editorIndentationStyle"
        static let tabWidth = "editorTabWidth"
        static let lineNumbers = "isLineNumbersVisible"
        static let statusBar = "isStatusBarVisible"
        static let theme = "appTheme"
        static let exitBehavior = "workspaceExitBehavior"
        static let startupFolderPath = "startupFolderPath"
        static let confirmedWorkspaceExitPrompt = "hasConfirmedWorkspaceExitPrompt"
        static let aiConfiguration = "aiConfiguration"
        static let jinaConfiguration = "jinaConfiguration"
        static let aiFeatures = "aiFeatures"
        static let aiFeatureModelIDs = "aiFeatureModelIDs"
        static let aiCustomChecks = "aiCustomChecks"
        static let aiBackgroundEnabled = "aiBackgroundEnabled"
        static let autoPairBracketsEnabled = "autoPairBracketsEnabled"
        static let autoPairMarkdownEnabled = "autoPairMarkdownEnabled"
        static let smartQuotesEnabled = "smartQuotesEnabled"
        static let smartDashesEnabled = "smartDashesEnabled"
        static let systemTextReplacementEnabled = "systemTextReplacementEnabled"
        static let mathPhysicsEnabled = "mathPhysicsEnabled"
        static let mathNumbering = "mathNumbering"
        static let systemSpellingEnabled = "systemSpellingEnabled"
        static let systemGrammarEnabled = "systemGrammarEnabled"
        static let markdownExportConfiguration = "markdownExportConfiguration"
        static let statisticsDisplayUnit = "statisticsDisplayUnit"
        static let readingWordsPerMinute = "readingWordsPerMinute"
        static let markdownHTMLExportOptions = "markdownHTMLExportOptions"
        static let markdownPDFHeaderFooterOptions = "markdownPDFHeaderFooterOptions"
        static let markdownNativeExportOptions = "markdownNativeExportOptions"
        static let markdownImageUploadConfiguration = "markdownImageUploadConfiguration"
        static let markdownTypographyCustomized = "markdownTypographyCustomized"
        static let editorTextFontFamily = "editorTextFontFamily"
        static let editorCodeFontFamily = "editorCodeFontFamily"
    }
}
