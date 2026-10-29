import AppKit
import SwiftUI

@objc(LacApplication)
final class LacApplication: NSApplication {
    override func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
    ) -> Bool {
        false
    }
}

@main
@MainActor
struct LacEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState
    @StateObject private var windowManager: WindowManager

    init() {
        L10n.configure()
        let manager = WindowManager(
            recoveryStore: DocumentRecoveryStore(),
            workspaceStore: WorkspaceSessionStore(),
            experimentSamples: AppEnvironment.isExperiment ? ExperimentSampleLibrary() : nil
        )
        let recoveredDocuments = manager.takeRecoveredDocuments()
        let state = AppState(
            initialDocuments: Array(recoveredDocuments.prefix(1)),
            recentFiles: manager.recentFiles,
            preferences: manager.preferences,
            recoveryStore: manager.recoveryStore
        )
        state.windowManager = manager
        let windowID = UUID()
        manager.preparePrimaryWindow(windowID: windowID, state: state)
        manager.openFilesFromCommandLine(WindowManager.commandLineURLs(
            arguments: Array(CommandLine.arguments.dropFirst()),
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        ))
        _appState = StateObject(wrappedValue: state)
        _windowManager = StateObject(wrappedValue: manager)
        AppDelegate.sharedManager = manager
    }

    var body: some Scene {
        // AppKit owns every editor window, including the first one. A file
        // launch does not ask SwiftUI to instantiate a Window scene, so mixing
        // scene-owned and manager-owned editors can leave queued files waiting
        // for a window that is only created by a later Dock reopen event.
        Settings {
            SettingsHostView(fallbackState: appState, windowManager: windowManager)
        }
        .commands {
            LacEditorCommands(windowManager: windowManager)
        }
    }
}

struct SettingsHostView: View {
    @ObservedObject var fallbackState: AppState
    @ObservedObject var windowManager: WindowManager

    private var targetState: AppState {
        windowManager.activeState ?? fallbackState
    }

    var body: some View {
        SettingsView()
            .environmentObject(targetState)
            .preferredColorScheme(targetState.preferredColorScheme)
            .tint(LacEditorDesign.accent)
            .background(
                WindowThemeCoordinator(
                    theme: targetState.theme,
                    systemAppearanceDidChange: targetState.refreshSystemAppearance
                )
            )
    }
}

/// Presents settings as a normal, non-modal macOS utility window. A sidebar
/// hosted inside NSSplitViewController does not always inherit SwiftUI's
/// `openSettings` action, which can create a Settings scene behind the editor
/// and immediately return focus to the main window. Keeping one explicit
/// controller makes the button deterministic and keeps the window in front.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var windowController: NSWindowController?
    private weak var presentedManager: WindowManager?
    private var presentationWorkItem: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?
    private let applicationIsActive: @MainActor () -> Bool
    private let activateApplication: @MainActor () -> Void

    init(applicationIsActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
         activateApplication: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }) {
        self.applicationIsActive = applicationIsActive
        self.activateApplication = activateApplication
        super.init()
    }

    deinit {
        presentationWorkItem?.cancel()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func present(windowManager: WindowManager) {
        // Finish the originating SwiftUI button/menu event before transferring
        // key-window ownership. Otherwise that event may reactivate its editor
        // after the settings window has already been shown.
        presentationWorkItem?.cancel()
        stopWaitingForActivation()
        let work = DispatchWorkItem { [weak self, weak windowManager] in
            guard let self, let windowManager else { return }
            presentationWorkItem = nil
            if applicationIsActive() {
                show(windowManager: windowManager)
            } else {
                // An inactive-window click can finish activating the SwiftUI
                // editor scene after makeKeyAndOrderFront. Wait for that one
                // activation event, then present outside its notification.
                activationObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
                ) { [weak self, weak windowManager] _ in
                    MainActor.assumeIsolated {
                        guard let self, let windowManager else { return }
                        self.stopWaitingForActivation()
                        self.present(windowManager: windowManager)
                    }
                }
                activateApplication()
            }
        }
        presentationWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func stopWaitingForActivation() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private func show(windowManager: WindowManager) {
        guard let state = windowManager.activeState else { return }
        let presentationScreen = NSApp.keyWindow?.screen ?? NSScreen.main

        if let window = windowController?.window {
            if presentedManager !== windowManager {
                window.contentViewController = NSHostingController(
                    rootView: SettingsHostView(
                        fallbackState: state,
                        windowManager: windowManager
                    )
                )
                presentedManager = windowManager
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("设置")
        window.identifier = NSUserInterfaceItemIdentifier("LacEditor.SettingsWindow")
        window.tabbingMode = .disallowed
        window.contentViewController = NSHostingController(
            rootView: SettingsHostView(
                fallbackState: state,
                windowManager: windowManager
            )
        )
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("LacEditor.UI2.Settings")
        _ = window.setFrameUsingName("LacEditor.UI2.Settings")
        if let visibleFrame = presentationScreen?.visibleFrame {
            window.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - window.frame.width / 2,
                y: visibleFrame.midY - window.frame.height / 2
            ))
        } else {
            window.center()
        }
        let controller = NSWindowController(window: window)
        windowController = controller
        presentedManager = windowManager
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        presentationWorkItem?.cancel()
        presentationWorkItem = nil
        stopWaitingForActivation()
        windowController = nil
    }
}

struct EditorWindowRoot: View {
    @ObservedObject var appState: AppState
    @ObservedObject var windowManager: WindowManager
    let windowID: UUID

    var body: some View {
        MainWindowView()
            .environmentObject(appState)
            .environmentObject(windowManager)
            .preferredColorScheme(appState.preferredColorScheme)
            .tint(LacEditorDesign.accent)
            .frame(minWidth: 900, minHeight: 560)
            .background(
                WindowCloseCoordinator(
                    appState: appState,
                    windowManager: windowManager,
                    windowID: windowID
                )
            )
            .background(
                WindowThemeCoordinator(
                    theme: appState.theme,
                    systemAppearanceDidChange: appState.refreshSystemAppearance
                )
            )
    }
}

struct WindowThemeCoordinator: NSViewRepresentable {
    let theme: AppTheme
    let systemAppearanceDidChange: () -> Void

    func makeNSView(context: Context) -> AppearanceObserverView {
        let view = AppearanceObserverView()
        view.systemAppearanceDidChange = systemAppearanceDidChange
        applyTheme(to: view)
        return view
    }

    func updateNSView(_ nsView: AppearanceObserverView, context: Context) {
        nsView.systemAppearanceDidChange = systemAppearanceDidChange
        applyTheme(to: nsView)
    }

    private func applyTheme(to view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let targetAppearance: NSAppearance?
            switch theme {
            case .system:
                targetAppearance = nil
            case .light:
                targetAppearance = NSAppearance(named: .aqua)
            case .dark:
                targetAppearance = NSAppearance(named: .darkAqua)
            }
            if window.appearance?.name != targetAppearance?.name {
                window.appearance = targetAppearance
            }
            window.contentView?.needsDisplay = true
        }
    }

    final class AppearanceObserverView: NSView {
        var systemAppearanceDidChange: (() -> Void)?

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            DispatchQueue.main.async { [weak self] in
                self?.systemAppearanceDidChange?()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedManager: WindowManager?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // SwiftUI's Window scene may consume Finder's open-document event
        // before application(_:open:) is called. Intercept the AppKit event
        // directly so an existing workspace stays alive and receives the URL.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
        // SwiftUI installs its command menus during scene construction, which
        // happens after WindowManager is initialized. Translate once again at
        // the AppKit launch boundary and after the scene has had a run-loop
        // turn to create the menu hierarchy.
        DispatchQueue.main.async {
            MenuLocalizationController.localizeMainMenu()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MenuLocalizationController.localizeMainMenu()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let error = Self.sharedManager?.startupError {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = L10n.tr("无法恢复工作区")
            alert.informativeText = L10n.tr("LacEditor 无法安全恢复工作区，已取消启动。原有数据未被删除。\n\n%@", error.localizedDescription)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        Self.sharedManager?.reopenPrimaryWindow()
        Task { @MainActor in
            await Self.sharedManager?.prepareExperimentSamples()
        }
    }

    @objc func showLocalizedAboutPanel(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppEnvironment.displayName
        ])
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        // Closing the final window keeps the app alive for Finder/Dock reopen.
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            Self.sharedManager?.reopenPrimaryWindow()
        }
        return true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        Self.sharedManager?.reopenPrimaryWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openFilesFromFinder(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openFilesFromFinder(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    private func openFilesFromFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Self.sharedManager?.openFilesFromFinder(urls)
    }

    @objc private func handleOpenDocuments(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard let directObject = event.paramDescriptor(forKeyword: keyDirectObject) else {
            return
        }

        var urls: [URL] = []
        if directObject.numberOfItems > 0 {
            for index in 1...directObject.numberOfItems {
                if let url = directObject.atIndex(index)?.fileURLValue {
                    urls.append(url)
                }
            }
        } else if let url = directObject.fileURLValue {
            urls.append(url)
        }
        openFilesFromFinder(urls)
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard Self.sharedManager?.startupError == nil else { return }
        Self.sharedManager?.persistRecoverySnapshotsImmediately()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The SwiftUI command tree can be rebuilt when the first window is
        // activated. Re-apply the visible top-level labels after that rebuild.
        MenuLocalizationController.localizeMainMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MenuLocalizationController.localizeMainMenu()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MenuLocalizationController.localizeMainMenu()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager = Self.sharedManager else { return .terminateNow }
        guard manager.startupError == nil else { return .terminateNow }
        let finish = { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        manager.requestApplicationTermination(completion: finish)
        return .terminateLater
    }
}

@MainActor
final class AppearanceMenuController: NSObject {
    private weak var windowManager: WindowManager?
    private var observer: NSObjectProtocol?

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu,
                      menu.items.contains(where: { $0.title == L10n.tr("外观") }) else {
                    return
                }
                self?.installNativeSubmenu(in: menu)
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.installFromMainMenu()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func installFromMainMenu() {
        guard let viewMenu = NSApp.mainMenu?.items.first(where: {
            $0.title == L10n.tr("View")
        })?.submenu else { return }
        installNativeSubmenu(in: viewMenu)
    }

    private func installNativeSubmenu(in viewMenu: NSMenu) {
        guard let appearanceItem = viewMenu.items.first(where: {
            $0.title == L10n.tr("外观")
        }) else { return }

        if appearanceItem.identifier?.rawValue == "LacEditor.Appearance",
           let submenu = appearanceItem.submenu {
            updateItems(in: submenu)
            appearanceItem.isEnabled = windowManager?.activeState != nil
            return
        }

        let submenu = NSMenu(title: L10n.tr("外观"))
        submenu.autoenablesItems = false
        appearanceItem.identifier = NSUserInterfaceItemIdentifier(
            "LacEditor.Appearance"
        )
        for theme in AppTheme.allCases {
            let item = NSMenuItem(
                title: L10n.tr(theme.rawValue),
                action: #selector(selectTheme(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = theme.rawValue
            item.identifier = NSUserInterfaceItemIdentifier(
                "LacEditor.Theme.\(theme.id)"
            )
            item.isEnabled = windowManager?.activeState != nil
            item.state = windowManager?.activeState?.theme == theme ? .on : .off
            submenu.addItem(item)
        }
        appearanceItem.submenu = submenu
        appearanceItem.isEnabled = windowManager?.activeState != nil
    }

    private func updateItems(in submenu: NSMenu) {
        for item in submenu.items {
            guard let rawValue = item.representedObject as? String,
                  let theme = AppTheme(rawValue: rawValue) else { continue }
            item.isEnabled = windowManager?.activeState != nil
            item.state = windowManager?.activeState?.theme == theme ? .on : .off
        }
    }

    @objc
    private func selectTheme(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let theme = AppTheme(rawValue: rawValue) else { return }
        windowManager?.activeState?.theme = theme
    }
}

/// SwiftUI's standard command groups inherit the system's English menu names
/// when the app has no localization bundle. Keep the command implementation
/// intact and translate only the visible top-level menu labels.
@MainActor
final class MenuLocalizationController: NSObject {
    private var observers: [NSObjectProtocol] = []
    private var localizationAttempts = 0

    override init() {
        super.init()
        observe(NSMenu.didBeginTrackingNotification)
        observe(NSMenu.didAddItemNotification)
        observe(NSWindow.didBecomeKeyNotification)
        // SwiftUI creates the command menu after the App initializer returns.
        // Retry briefly after launch so the native menu is translated after it
        // actually exists, rather than relying on a single early pass.
        scheduleLocalizationPass()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func observe(_ name: Notification.Name) {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard self != nil else { return }
                    Self.localizeMainMenu()
                    // SwiftUI can replace the menu while a window becomes key
                    // or immediately after menu tracking starts.
                    DispatchQueue.main.async {
                        Self.localizeMainMenu()
                    }
                }
            }
        )
    }

    static func localizeMainMenu() {
        guard let menu = NSApp.mainMenu else { return }
        let translations = [
            "File": L10n.tr("File"),
            "Edit": L10n.tr("Edit"),
            "View": L10n.tr("View"),
            "Window": L10n.tr("Window"),
            "Help": L10n.tr("Help")
        ]
        if let applicationItem = menu.items.first {
            let bundleName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? applicationItem.title
            applicationItem.title = AppEnvironment.displayName
            for item in applicationItem.submenu?.items ?? [] {
                if !bundleName.isEmpty {
                    item.title = item.title.replacingOccurrences(
                        of: bundleName,
                        with: AppEnvironment.displayName
                    )
                }
                if item.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) {
                    item.target = NSApp.delegate
                    item.action = #selector(AppDelegate.showLocalizedAboutPanel(_:))
                }
            }
        }
        for item in menu.items.dropFirst() {
            if let translated = translations[item.title] {
                item.title = translated
            }
        }
    }

    private func scheduleLocalizationPass() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            Self.localizeMainMenu()
            self.localizationAttempts += 1
            if self.localizationAttempts < 40 {
                try? await Task.sleep(for: .milliseconds(100))
                self.scheduleLocalizationPass()
            }
        }
    }
}

struct WindowCloseCoordinator: NSViewRepresentable {
    @ObservedObject var appState: AppState
    let windowManager: WindowManager
    let windowID: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(
            appState: appState,
            windowManager: windowManager,
            windowID: windowID
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.previousDelegate = window.delegate
            window.delegate = context.coordinator
            window.title = appState.windowTitle
            configureEditorWindowChrome(window, appState: appState)
            windowManager.register(windowID: windowID, state: appState, window: window)
            context.coordinator.scheduleChromeUpdate(for: window)
            MenuLocalizationController.localizeMainMenu()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MenuLocalizationController.localizeMainMenu()
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.title = appState.windowTitle
        if let window = nsView.window {
            configureEditorWindowChrome(window, appState: appState)
            context.coordinator.scheduleChromeUpdate(for: window)
        }
        if let window = nsView.window, appState.hostWindow !== window {
            // Registration publishes the active workspace. Never perform it
            // inside SwiftUI's representable update transaction.
            DispatchQueue.main.async { [weak window] in
                guard let window, nsView.window === window,
                      appState.hostWindow !== window else { return }
                windowManager.register(windowID: windowID, state: appState, window: window)
            }
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        let appState: AppState
        let windowManager: WindowManager
        let windowID: UUID
        weak var previousDelegate: NSWindowDelegate?
        private var chromeWorkItem: DispatchWorkItem?
        private var isWaitingForSave = false

        init(appState: AppState, windowManager: WindowManager, windowID: UUID) {
            self.appState = appState
            self.windowManager = windowManager
            self.windowID = windowID
        }

        deinit {
            chromeWorkItem?.cancel()
        }

        func scheduleChromeUpdate(for window: NSWindow) {
            chromeWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak window] in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    configureEditorWindowChrome(window, appState: self.appState)
                }
            }
            chromeWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.2,
                execute: workItem
            )
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if windowManager.terminationApproved { return true }
            guard !isWaitingForSave else { return false }
            isWaitingForSave = true
            let confirm = { [weak self, weak sender] in
                guard let self, let sender else { return }
                self.appState.confirmClosingAllDocuments { [weak self, weak sender] approved in
                    guard let self, let sender else { return }
                    guard approved else {
                        self.isWaitingForSave = false
                        return
                    }
                    // The sheet completion runs while AppKit is unwinding its
                    // modal session. Do not re-enter performClose: a dirty native
                    // tab can reject that second request even after Discard.
                    DispatchQueue.main.async { [weak self, weak sender] in
                        guard let self, let sender else { return }
                        self.appState.prepareForApprovedWindowClose()
                        sender.close()
                    }
                }
            }
            if appState.hasPendingSave {
                appState.waitForPendingSaves(completion: confirm)
            } else {
                confirm()
            }
            return false
        }

        func windowDidBecomeKey(_ notification: Notification) {
            // The retained primary window can reopen from the Dock after it
            // was closed. Rebind the existing session before activating it so
            // menu commands and sidebar state target this window again.
            if let window = notification.object as? NSWindow {
                windowManager.register(
                    windowID: windowID,
                    state: appState,
                    window: window
                )
            }
            windowManager.activate(windowID: windowID)
            previousDelegate?.windowDidBecomeKey?(notification)
        }

        func windowWillClose(_ notification: Notification) {
            isWaitingForSave = false
            windowManager.unregister(windowID: windowID)
            previousDelegate?.windowWillClose?(notification)
        }
    }
}

@MainActor
func configureEditorWindowChrome(_ window: NSWindow, appState: AppState? = nil) {
    window.tabbingIdentifier = "com.laceditor.editor"
    window.tabbingMode = .preferred
    window.tab.title = appState?.selectedDocument?.displayName ?? L10n.tr("未命名")
    window.isDocumentEdited = appState?.selectedDocument?.isDirty == true
    window.representedURL = appState?.selectedDocument?.url
    // This is the same structure used by Finder: the native split sidebar is
    // allowed to extend through the titlebar, while one compact AppKit toolbar
    // owns every titlebar control and tracks the split-view divider.
    window.styleMask.insert(.fullSizeContentView)
    window.toolbarStyle = .unified
    window.titleVisibility = .hidden
    // Use NT2's native titlebar backdrop above the full-height scroll views.
    window.titlebarAppearsTransparent = false
    window.backgroundColor = .windowBackgroundColor
    window.titlebarSeparatorStyle = .none

    if let appState {
        configureEditorWindowToolbar(window, appState: appState)
    }
}

/// AppKit sends the native tab bar's plus action down the responder chain.
extension AppDelegate {
    @objc func newWindowForTab(_ sender: Any?) {
        Self.sharedManager?.openNativeTab()
    }
}
