import Combine
import Foundation

/// Every persistent store uses the same namespace. A new bundle identifier
/// alone does not isolate files stored under Application Support.
enum AppEnvironment {
    static let experimentIdentifier = "com.laceditor.ui-experiment"
    static var isExperiment: Bool { Bundle.main.bundleIdentifier == experimentIdentifier }
    static var displayName: String {
        switch Bundle.main.bundleIdentifier {
        case experimentIdentifier: L10n.tr("LacEditor 实验版")
        case "com.laceditor.development": L10n.tr("LacEditor 开发版")
        case "com.laceditor.acceptance": L10n.tr("LacEditor 验收版")
        default: "LacEditor"
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

@MainActor
final class AppPreferences: ObservableObject {
    static let defaultFontSize: CGFloat = 14
    static let defaultLineSpacing = FoldLayoutManager.defaultLineSpacing

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
    @Published var systemSpellingEnabled: Bool {
        didSet { defaults.set(systemSpellingEnabled, forKey: Keys.systemSpellingEnabled) }
    }
    @Published var systemGrammarEnabled: Bool {
        didSet { defaults.set(systemGrammarEnabled, forKey: Keys.systemGrammarEnabled) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        static let wordWrap = "isWordWrapEnabled"
        static let fontSize = "editorFontSize"
        static let lineSpacing = "editorLineSpacing"
        static let indentationStyle = "editorIndentationStyle"
        static let tabWidth = "editorTabWidth"
        static let lineNumbers = "isLineNumbersVisible"
        static let statusBar = "isStatusBarVisible"
        static let theme = "appTheme"
        static let exitBehavior = "workspaceExitBehavior"
        static let confirmedWorkspaceExitPrompt = "hasConfirmedWorkspaceExitPrompt"
        static let aiConfiguration = "aiConfiguration"
        static let jinaConfiguration = "jinaConfiguration"
        static let aiFeatures = "aiFeatures"
        static let aiFeatureModelIDs = "aiFeatureModelIDs"
        static let aiCustomChecks = "aiCustomChecks"
        static let aiBackgroundEnabled = "aiBackgroundEnabled"
        static let systemSpellingEnabled = "systemSpellingEnabled"
        static let systemGrammarEnabled = "systemGrammarEnabled"
    }
}
