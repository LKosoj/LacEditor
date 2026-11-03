import SwiftUI
import AppKit
import WebKit

/// Окно сводного просмотра: сцены проекта подряд одной страницей, только для чтения.
struct WriterCombinedView: View {
    @ObservedObject var controller: WriterCombinedViewController
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if controller.isStale { staleBar }
            ZStack {
                if controller.partCount == 0 && !controller.isLoading && controller.errorMessage == nil {
                    ContentUnavailableView(L10n.tr("合并预览为空"), systemImage: "doc.text")
                } else {
                    WriterCombinedWebView(html: controller.html, token: controller.token) { controller.openPart(index: $0) }
                }
                if controller.isLoading { ProgressView().controlSize(.large) }
            }
            if let message = controller.errorMessage {
                footer(message, systemImage: "exclamationmark.triangle")
            } else if !controller.problems.isEmpty {
                footer(L10n.tr("有 %d 个文件无法读取", controller.problems.count), systemImage: "exclamationmark.triangle")
                    .help(controller.problems.joined(separator: "\n"))
            }
        }
        .onChange(of: colorScheme) { _, _ in controller.reload() }
        // Хранилище сообщает до записи значения: проверка откладывается на следующий такт.
        .onReceive(controller.store.objectWillChange) { _ in
            Task { @MainActor in controller.checkStale() }
        }
    }

    private var staleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text(L10n.tr("文本已变化"))
            Button(L10n.tr("刷新")) { controller.reload() }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.12))
    }

    private func footer(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(.orange)
            Text(text).font(.caption)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(Color.orange.opacity(0.1))
    }
}

/// Страница сводного просмотра. JavaScript выключен, поэтому прокрутка после «Обновить» не сохраняется.
struct WriterCombinedWebView: NSViewRepresentable {
    let html: String
    let token: String
    let onOpen: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.token = token
        coordinator.onOpen = onOpen
        // Перезагрузка только при новой странице: иначе любая перерисовка SwiftUI сбрасывала бы прокрутку.
        guard coordinator.lastHTML != html else { return }
        coordinator.lastHTML = html
        view.loadHTMLString(html, baseURL: nil)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var token = ""
        var lastHTML: String?
        var onOpen: (Int) -> Void = { _ in }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated else {
                // Первичная загрузка собственной страницы.
                decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
                return
            }
            decisionHandler(.cancel)
            guard let url = navigationAction.request.url else { return }
            if let index = WriterCombinedPage.partIndex(from: url, token: token) {
                onOpen(index)
            } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
