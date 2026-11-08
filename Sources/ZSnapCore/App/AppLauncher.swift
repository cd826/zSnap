import AppKit

/// 应用启动引导（供可执行入口调用）。
@MainActor
public enum AppLauncher {
    public static func run() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // 菜单栏应用：无 Dock 图标。
        // 打包后由 Info.plist 的 LSUIElement 保证；开发态（无 Bundle）由 activation policy 保证。
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
