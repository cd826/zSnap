import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// 设置窗口（Phase 5）：快捷键、外观（遮罩强度）、开机启动、关于。
@MainActor
final class SettingsWindowController: NSWindowController {
    private let onHotkeyChanged: () -> Void

    init(onHotkeyChanged: @escaping () -> Void) {
        self.onHotkeyChanged = onHotkeyChanged
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "zSnap 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        let rootView = SettingsView(onHotkeyChanged: onHotkeyChanged)
        window.contentView = NSHostingView(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("未支持 IB 初始化")
    }

    func show() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - SwiftUI 设置页

struct SettingsView: View {
    let onHotkeyChanged: () -> Void

    @State private var hotkeyDisplay = SettingsManager.regionHotkeyDisplay
    @State private var dimming = SettingsManager.dimmingAlpha
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("区域截图快捷键").font(.headline)
                    HStack {
                        HotkeyRecorderView(display: $hotkeyDisplay) { keyCode, modifiers, display in
                            SettingsManager.saveRegionHotkey(keyCode: keyCode, modifiers: modifiers, display: display)
                            onHotkeyChanged()
                        }
                        Text("在任意应用中按下即可触发区域截图")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("外观").font(.headline)
                    HStack {
                        Text("遮罩强度")
                        Slider(value: Binding(
                            get: { dimming },
                            set: { newValue in
                                dimming = newValue
                                SettingsManager.dimmingAlpha = newValue
                            }
                        ), in: 0.3...0.85)
                        Text("\(Int(dimming * 100))%")
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("通用").font(.headline)
                    Toggle("登录时启动 zSnap", isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                                launchAtLogin = newValue
                                launchError = nil
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                                launchError = "设置开机启动失败：\(error.localizedDescription)"
                            }
                        }
                    ))
                    if let launchError {
                        Text(launchError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("关于").font(.headline)
                    Text("zSnap 0.4.0 · macOS 截图效率工具")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("区域/窗口/全屏截图 · 标注 · 贴图 · 长截图")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 460, height: 380)
    }
}

// MARK: - 快捷键录制器

/// 点击进入录制态，捕获下一个快捷键组合（需含 ⌃/⌥/⌘ 之一）。
struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var display: String
    let onCommit: (UInt32, UInt32, String) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onDisplayChange = { display = $0 }
        view.onCommit = onCommit
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.currentDisplay = display
        nsView.onCommit = onCommit
    }
}

@MainActor
final class HotkeyRecorderNSView: NSView {
    var onDisplayChange: ((String) -> Void)?
    var onCommit: ((UInt32, UInt32, String) -> Void)?
    var currentDisplay: String = SettingsManager.regionHotkeyDisplay {
        didSet { needsDisplay = true }
    }
    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.quaternaryLabelColor.setFill()
            NSColor.separatorColor.setStroke()
        }
        path.fill()
        path.lineWidth = 1
        path.stroke()

        let text = isRecording ? "按下新快捷键…（Esc 取消）" : currentDisplay
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        // Esc 取消录制。
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 必须包含 ⌃/⌥/⌘ 之一，避免劫持普通按键。
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
            NSSound.beep()
            return
        }
        // 排除纯修饰键按下。
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
              !["shift", "command", "option", "control", "caps lock"].contains(characters.lowercased()) else {
            return
        }
        guard let key = characters.uppercased().first else { return }

        var carbonModifiers: UInt32 = 0
        var display = ""
        if flags.contains(.command) { carbonModifiers |= SettingsManager.carbonCommand; display += "⌘" }
        if flags.contains(.control) { carbonModifiers |= SettingsManager.carbonControl; display += "⌃" }
        if flags.contains(.option) { carbonModifiers |= SettingsManager.carbonOption; display += "⌥" }
        if flags.contains(.shift) { carbonModifiers |= SettingsManager.carbonShift; display += "⇧" }
        display += String(key)

        isRecording = false
        currentDisplay = display
        onDisplayChange?(display)
        onCommit?(UInt32(event.keyCode), carbonModifiers, display)
    }
}
