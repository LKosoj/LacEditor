import SwiftUI
import AppKit
import Combine

/// Цвет статуса (сцены, пользовательские статусы). Значения `rawValue` хранятся в манифесте проекта.
enum StatusColor: String, Codable, CaseIterable {
    case gray, blue, orange, green, purple, teal

    var nsColor: NSColor {
        switch self {
        case .gray: .systemGray
        case .blue: .systemBlue
        case .orange: .systemOrange
        case .green: .systemGreen
        case .purple: .systemPurple
        case .teal: .systemTeal
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// Цветная точка статуса. Подпись всегда рядом (строка списка) или в `.help`: цвет — не единственный признак.
struct StatusDot: View {
    let color: StatusColor
    let title: String

    init(color: StatusColor, title: String) {
        self.color = color
        self.title = title
    }

    var body: some View {
        Circle()
            .fill(color.color)
            .frame(width: 8, height: 8)
            .help(title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}

/// Значок «предложено AI». Своего фона нет.
struct AIBadge: View {
    init() {}

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "sparkles")
            Text(verbatim: "AI")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("AI 建议"))
    }
}

enum FindingSource: String, Equatable {
    case rule, ai

    var symbol: String {
        switch self {
        case .rule: "text.magnifyingglass"
        case .ai: "sparkles"
        }
    }
}

/// Строка находки (стиль, повторы, согласованность). Выбор, клавиши и действия — у вызывающего: сама строка ничего не обрабатывает.
struct FindingRow: View {
    let source: FindingSource
    let fragment: String
    let explanation: String?
    let location: String?
    let category: String?

    init(source: FindingSource, fragment: String, explanation: String? = nil, location: String? = nil, category: String? = nil) {
        self.source = source
        self.fragment = fragment
        self.explanation = explanation
        self.location = location
        self.category = category
    }

    static func accessibilityText(source: FindingSource, fragment: String, explanation: String?, location: String?, category: String?) -> String {
        let sourceName = source == .ai ? L10n.tr("AI 建议") : L10n.tr("本地规则")
        return [sourceName, category, fragment, explanation, location]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: source.symbol)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(fragment).lineLimit(3)
                if let explanation, !explanation.isEmpty {
                    Text(explanation).font(.callout).foregroundStyle(.secondary)
                }
                if let location, !location.isEmpty {
                    Text(location).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if source == .ai { AIBadge() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(source: source, fragment: fragment, explanation: explanation, location: location, category: category))
    }
}

/// Ненавязчивая подсказка «Включите AI, чтобы …». Нужны `AppState` и `WindowManager` в окружении.
/// Показывается, пока функция недоступна и подсказку не закрыли крестиком.
struct AIRecommendationHint: View {
    let feature: AIFeature
    let message: String
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    // Счётчик нужен только чтобы перерисовать view при изменении настроек: appState сам их не публикует.
    @State private var refresh = 0
    @State private var dismissed = false

    init(feature: AIFeature, message: String) {
        self.feature = feature
        self.message = message
    }

    private var availability: AIAvailability { appState.aiAvailability(for: feature) }

    var body: some View {
        Group {
            if refresh >= 0, !dismissed, availability != .available, !AIHintStore().isDismissed(feature) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.tr("AI 设置…")) { openSettings() }
                        .buttonStyle(.link)
                    Button {
                        AIHintStore().dismiss(feature)
                        dismissed = true
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.tr("隐藏此提示"))
                }
            }
        }
        .onReceive(appState.preferences.objectWillChange.receive(on: DispatchQueue.main)) { _ in refresh += 1 }
    }

    private func openSettings() {
        SettingsNavigator.shared.open(.ai, aiPage: availability == .featureDisabled ? .features : .connections)
        SettingsWindowController.shared.present(windowManager: windowManager)
    }
}
