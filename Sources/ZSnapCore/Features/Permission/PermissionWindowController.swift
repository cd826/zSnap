import AppKit
import SwiftUI

/// 屏幕录制权限引导窗口（需求 3.2 截图权限）：
/// 首次使用提供清晰说明、提供跳转系统设置入口、授权后可重新检测、不假装截图成功。
@MainActor
final class PermissionWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onDismissed: () -> Void

    init(onDismissed: @escaping () -> Void) {
        self.onDismissed = onDismissed
        super.init()
    }

    func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = PermissionGuidanceView(
            initialGranted: ScreenRecordingPermission.isGranted,
            onOpenSettings: {
                // 首次调用会触发系统授权弹窗（应用仅一次），随后跳转系统设置。
                _ = ScreenRecordingPermission.request()
                Self.openPrivacySettings()
            },
            onRecheck: { ScreenRecordingPermission.isGranted },
            onRelaunch: { Self.relaunch() }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "zSnap 需要屏幕录制权限"
        window.contentView = NSHostingView(rootView: rootView)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Log.app.info("显示权限引导窗口")
    }

    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// 授权在部分场景下需要重启应用后才对截图 API 生效。
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            NSWorkspace.shared.open(bundleURL)
        }
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard window != nil else { return }
        window = nil
        onDismissed()
    }
}

/// 权限引导界面（SwiftUI，宿主于 NSHostingView；同时验证 AppKit + SwiftUI 混合桥接）。
struct PermissionGuidanceView: View {
    let initialGranted: Bool
    let onOpenSettings: () -> Void
    let onRecheck: () -> Bool
    let onRelaunch: () -> Void

    @State private var granted: Bool = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: granted ? "checkmark.seal.fill" : "lock.shield")
                .font(.system(size: 46))
                .foregroundStyle(granted ? Color.green : Color.accentColor)

            Text(granted ? "屏幕录制权限已获取" : "zSnap 需要屏幕录制权限")
                .font(.title3.weight(.semibold))

            Text(granted
                ? "若截图仍提示无权限，请重启应用使授权生效。"
                : "只有授权后 zSnap 才能截取屏幕内容。\n截图仅在本机处理，不会被上传。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if granted {
                Button("重启应用", action: onRelaunch)
                    .keyboardShortcut(.defaultAction)
            } else {
                HStack(spacing: 12) {
                    Button("打开系统设置", action: onOpenSettings)
                        .keyboardShortcut(.defaultAction)
                    Button("我已授权，重新检测") {
                        granted = onRecheck()
                    }
                }
            }
        }
        .padding(30)
        .frame(width: 440)
        .onAppear { granted = initialGranted }
    }
}
