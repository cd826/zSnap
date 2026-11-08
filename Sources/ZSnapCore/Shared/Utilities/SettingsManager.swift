import Foundation

/// 设置存取（UserDefaults 持久化，需求 Phase 5）。
/// 快捷键存储 Carbon 语义：keyCode + 修饰键掩码（cmdKey/optionKey/...）。
enum SettingsManager {
    static let hotkeyChangedNotification = Notification.Name("com.cd826.zSnap.hotkeyChanged")

    private enum Keys {
        static let hotkeyKeyCode = "regionHotkeyKeyCode"
        static let hotkeyModifiers = "regionHotkeyModifiers"
        static let hotkeyDisplay = "regionHotkeyDisplay"
        static let dimmingAlpha = "selectionDimmingAlpha"
    }

    // Carbon 修饰键掩码（与 RegisterEventHotKey 一致）。
    static let carbonCommand: UInt32 = 1 << 8
    static let carbonShift: UInt32 = 1 << 9
    static let carbonOption: UInt32 = 1 << 11
    static let carbonControl: UInt32 = 1 << 12

    private static let defaults = UserDefaults.standard

    /// 区域截图快捷键 keyCode（默认 kVK_ANSI_A = 0）。
    static var regionHotkeyKeyCode: UInt32 {
        get { UInt32(defaults.object(forKey: Keys.hotkeyKeyCode) as? Int ?? 0) }
        set { defaults.set(Int(newValue), forKey: Keys.hotkeyKeyCode) }
    }

    /// 区域截图快捷键修饰键（默认 ⌥）。
    static var regionHotkeyModifiers: UInt32 {
        get { UInt32(defaults.object(forKey: Keys.hotkeyModifiers) as? Int ?? Int(carbonOption)) }
        set { defaults.set(Int(newValue), forKey: Keys.hotkeyModifiers) }
    }

    /// 快捷键显示文本（如 "⌥A"，录制时生成）。
    static var regionHotkeyDisplay: String {
        get { defaults.string(forKey: Keys.hotkeyDisplay) ?? "⌥A" }
        set { defaults.set(newValue, forKey: Keys.hotkeyDisplay) }
    }

    /// 选区遮罩压暗强度（0.3 ~ 0.85，默认 0.65）。
    static var dimmingAlpha: Double {
        get {
            let value = defaults.double(forKey: Keys.dimmingAlpha)
            return value == 0 ? 0.65 : min(0.85, max(0.3, value))
        }
        set { defaults.set(min(0.85, max(0.3, newValue)), forKey: Keys.dimmingAlpha) }
    }

    static func saveRegionHotkey(keyCode: UInt32, modifiers: UInt32, display: String) {
        regionHotkeyKeyCode = keyCode
        regionHotkeyModifiers = modifiers
        regionHotkeyDisplay = display
        NotificationCenter.default.post(name: hotkeyChangedNotification, object: nil)
    }
}
