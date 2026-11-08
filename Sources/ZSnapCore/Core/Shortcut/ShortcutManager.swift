import AppKit
import Carbon.HIToolbox

/// 全局快捷键管理。
///
/// 技术选型：Carbon RegisterEventHotKey —— 无需辅助功能权限、可拦截按键、
/// macOS 14+ 稳定可用（对比：NSEvent.addGlobalMonitorForEvents 无法拦截按键且需要辅助功能授权）。
final class ShortcutManager {
    private enum HotKeyID {
        static let regionCapture: UInt32 = 1
    }

    /// 自定义签名，用于在事件回调中识别 zSnap 注册的热键。
    private static let signature: FourCharCode = {
        var value: FourCharCode = 0
        for scalar in "ZSNP".unicodeScalars {
            value = (value << 8) &+ FourCharCode(scalar.value)
        }
        return value
    }()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]

    /// 注册"区域截图"快捷键，默认 ⌥A。
    func registerRegionCapture(
        keyCode: UInt32 = UInt32(kVK_ANSI_A),
        modifiers: UInt32 = UInt32(optionKey),
        action: @escaping () -> Void
    ) {
        actions[HotKeyID.regionCapture] = action

        if eventHandler == nil {
            installEventHandler()
        }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: HotKeyID.regionCapture)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
            Log.shortcut.info("已注册区域截图快捷键（默认 ⌥A）")
        } else {
            Log.shortcut.error("RegisterEventHotKey 失败 status=\(status)")
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return noErr }
            let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            manager.dispatch(eventRef: eventRef)
            return noErr
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, userData, &eventHandler)
        if status != noErr {
            Log.shortcut.error("InstallEventHandler 失败 status=\(status)")
        }
    }

    private func dispatch(eventRef: EventRef) {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == Self.signature else { return }
        guard let action = actions[hotKeyID.id] else { return }
        // 热键事件固定在主线程回调；跳回主队列执行以规避并发隔离问题。
        DispatchQueue.main.async(execute: action)
    }
}
