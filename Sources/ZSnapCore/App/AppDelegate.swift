import AppKit

/// 应用代理：装配菜单栏入口与全局快捷键。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        coordinator.shortcutManager.registerRegionCapture(
            keyCode: SettingsManager.regionHotkeyKeyCode,
            modifiers: SettingsManager.regionHotkeyModifiers
        ) { [weak self] in
            self?.coordinator.startRegionCapture()
        }

        // 设置页修改快捷键 → 重建菜单显示。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshMenu),
            name: .zSnapMenuShouldRefresh,
            object: nil
        )

        Log.app.info("zSnap 启动完成")
    }

    @objc private func refreshMenu() {
        statusItem?.menu = MenuBuilder.buildMenu(coordinator: coordinator)
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
