import AppKit

/// 应用代理：装配菜单栏入口与全局快捷键。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        coordinator.shortcutManager.registerRegionCapture { [weak self] in
            self?.coordinator.startRegionCapture()
        }

        Log.app.info("zSnap 启动完成（Phase 0 技术验证版）")
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "camera.viewfinder",
                accessibilityDescription: "zSnap"
            )
        }
        item.menu = MenuBuilder.buildMenu(coordinator: coordinator)
        statusItem = item
    }
}
