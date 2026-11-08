import AppKit

/// 菜单栏菜单（需求 3.1）。
/// 区域截图 / 窗口截图共用同一选区会话（悬停高亮 + 智能点击）；全屏截图按显示器子菜单。
/// 设置入口 Phase 5 提供，以禁用状态占位并注明阶段，不做假入口。
@MainActor
enum MenuBuilder {
    static func buildMenu(coordinator: AppCoordinator) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 区域截图 ⌥A（默认，可在设置中自定义）
        let hotkeyDisplay = SettingsManager.regionHotkeyDisplay
        let region = NSMenuItem(
            title: "区域截图（\(hotkeyDisplay)）",
            action: #selector(AppCoordinator.startRegionCaptureFromMenu),
            keyEquivalent: ""
        )
        region.target = coordinator
        region.isEnabled = true
        menu.addItem(region)

        // 长截图：框选区域后滚动页面自动拼接（Phase 4）
        let longCapture = NSMenuItem(
            title: "长截图",
            action: #selector(AppCoordinator.startLongCaptureFromMenu),
            keyEquivalent: ""
        )
        longCapture.target = coordinator
        longCapture.isEnabled = true
        menu.addItem(longCapture)

        // 全屏截图（按显示器列出）
        let fullscreenItem = NSMenuItem(title: "全屏截图", action: nil, keyEquivalent: "")
        let fullscreenMenu = NSMenu(title: "全屏截图")
        for screen in NSScreen.screens {
            let pixelWidth = Int(screen.frame.width * screen.backingScaleFactor)
            let pixelHeight = Int(screen.frame.height * screen.backingScaleFactor)
            let item = NSMenuItem(
                title: "\(screen.localizedName)（\(pixelWidth)×\(pixelHeight) px）",
                action: #selector(AppCoordinator.captureFullScreenFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = coordinator
            item.representedObject = screen
            item.isEnabled = true
            fullscreenMenu.addItem(item)
        }
        fullscreenItem.submenu = fullscreenMenu
        menu.addItem(fullscreenItem)

        // 窗口截图：与区域截图共用同一选区会话（悬停高亮窗口，智能点击分发）。
        let windowCapture = NSMenuItem(
            title: "窗口截图",
            action: #selector(AppCoordinator.startRegionCaptureFromMenu),
            keyEquivalent: ""
        )
        windowCapture.target = coordinator
        windowCapture.isEnabled = true
        menu.addItem(windowCapture)

        menu.addItem(.separator())

        // 设置（Phase 5）
        let settings = NSMenuItem(
            title: "设置…",
            action: #selector(AppCoordinator.showSettingsFromMenu),
            keyEquivalent: ","
        )
        settings.target = coordinator
        settings.isEnabled = true
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出 zSnap",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        return menu
    }
}
