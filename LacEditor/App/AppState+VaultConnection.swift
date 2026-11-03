import AppKit
import SwiftUI

extension AppState {
    /// Показывает лист подключения хранилища в этой вкладке (как мастер писательского режима).
    /// По умолчанию `onConnect` входит в режим хранилища в этой вкладке.
    func presentVaultConnectionSheet(preselectedID: UUID? = nil,
                                     onConnect: ((VaultConnection) -> Void)? = nil,
                                     onDeleted: ((UUID) -> Void)? = nil) {
        guard vaultConnectionSheet == nil, let window = hostWindow else { return }
        let request = VaultConnectionSheetRequest(
            preselectedID: preselectedID,
            onConnect: onConnect ?? { [weak self] connection in
                guard let self else { return }
                self.windowManager?.enterVault(connection, from: self)
            },
            onDeleted: onDeleted ?? { [weak self] id in
                // Подключение удалено: очередь запросов уходит вместе с ним, активная сессия закрывается.
                VaultRequestsStore.removeAll(vaultID: id)
                guard let manager = self?.windowManager, manager.activeVaultSession?.connection.id == id else { return }
                Task { @MainActor in await manager.leaveVault() }
            })
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: VaultConnectionSheet(
            request: request,
            close: { [weak self] in self?.dismissVaultConnectionSheet() })))
        sheet.styleMask.remove(.closable)
        vaultConnectionSheet = sheet
        window.beginSheet(sheet)
    }

    func dismissVaultConnectionSheet() {
        guard let sheet = vaultConnectionSheet else { return }
        vaultConnectionSheet = nil
        sheet.sheetParent?.endSheet(sheet)
    }
}
