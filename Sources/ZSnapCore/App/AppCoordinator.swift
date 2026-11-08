import AppKit
import ScreenCaptureKit

/// 应用协调器：唯一的状态机持有者，负责截图流程编排（需求 9.1 / 9.2）。
/// 正在选区或展示结果时，重复触发会被拒绝并留痕。
@MainActor
final class AppCoordinator: NSObject {
    private(set) var state: AppState = .idle

    let shortcutManager = ShortcutManager()
    private let captureService = ScreenCaptureService()
    private let pinManager = PinWindowManager()

    private var selectionController: SelectionOverlayController?
    private var editorController: EditorWindowController?
    private var permissionController: PermissionWindowController?
    private var settingsController: SettingsWindowController?
    private var longCaptureController: LongCaptureController?
    /// 本次选区是否用于长截图（决定选区完成后的去向）。
    private var longCapturePending = false

    // MARK: - 状态转换

    private func transition(to newState: AppState) {
        guard state != newState else { return }
        let from = state.description
        state = newState
        Log.app.info("状态转换：\(from, privacy: .public) → \(newState.description, privacy: .public)")
    }

    private func presentError(_ message: String) {
        transition(to: .error)
        Log.app.error("\(message, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "zSnap"
        alert.informativeText = message
        alert.runModal()
        transition(to: .idle)
    }

    // MARK: - 区域截图

    func startRegionCapture() {
        guard state == .idle else {
            Log.app.notice("忽略重复触发，当前状态 \(self.state.description)")
            return
        }

        guard ScreenRecordingPermission.isGranted else {
            showPermissionGuidance()
            return
        }
        transition(to: .selecting)
        Task { [weak self] in
            await self?.runRegionCapture()
        }
    }

    private func runRegionCapture() async {
        do {
            let session = try await captureService.captureSession()
            beginSelection(with: session)
        } catch {
            transition(to: .idle)
            presentError("截图失败：\(error.localizedDescription)")
        }
    }

    /// 长截图入口：框选区域后进入滚动拼接会话（Phase 4）。
    func startLongCapture() {
        guard state == .idle else {
            Log.app.notice("忽略重复触发，当前状态 \(self.state.description)")
            return
        }
        guard ScreenRecordingPermission.isGranted else {
            showPermissionGuidance()
            return
        }
        longCapturePending = true
        transition(to: .selecting)
        Task { [weak self] in
            await self?.runRegionCapture()
        }
    }

    private func beginSelection(with session: ScreenCaptureService.CaptureSession) {
        // 窗口列表在覆盖层创建之前枚举（此时自身覆盖窗口还未上屏）。
        let windowList = WindowListService.currentWindows()
        let controller = SelectionOverlayController(
            snapshots: session.snapshots,
            windows: windowList,
            onFinish: { [weak self] globalRect, snapshot in
                guard let self else { return }
                if self.longCapturePending {
                    self.longCapturePending = false
                    let screen = ScreenCaptureService.nsscreen(forDisplayID: snapshot.geometry.displayID) ?? NSScreen.main
                    self.beginLongSession(regionRect: globalRect, geometry: snapshot.geometry, screen: screen)
                } else {
                    self.completeSelection(globalRect: globalRect, snapshot: snapshot)
                }
            },
            onWindowCapture: { [weak self] windowInfo in
                self?.completeWindowCapture(windowInfo, session: session)
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.selectionController = nil
                self.longCapturePending = false
                self.transition(to: .idle)
            }
        )
        selectionController = controller
        controller.begin()
    }

    /// 长截图拼接会话：基于框选区域滚动抓帧（Phase 4）。
    private func beginLongSession(regionRect: CGRect, geometry: DisplayGeometry, screen: NSScreen?) {
        selectionController = nil
        guard let screen else {
            transition(to: .idle)
            presentError("长截图失败：无法定位显示器。")
            return
        }
        let controller = LongCaptureController(
            regionRect: regionRect,
            geometry: geometry,
            screen: screen,
            onFinish: { [weak self] image, warning in
                guard let self else { return }
                self.longCaptureController = nil
                guard let image else {
                    self.transition(to: .idle)
                    return
                }
                Log.app.info("长截图完成：\(image.width)×\(image.height) px")
                if let warning {
                    self.longCaptureWarning = warning
                } else {
                    self.longCaptureWarning = nil
                }
                self.showEditor(image: image, logicalSize: regionRect.size)
            }
        )
        longCaptureController = controller
        controller.start()
    }

    /// 长截图已知告警（如出现缺口），进入编辑器时提示一次。
    private var longCaptureWarning: String?

    private func completeSelection(globalRect: CGRect, snapshot: ScreenCaptureService.DisplaySnapshot) {
        selectionController = nil

        let pixelRect = ImageCoordinateConverter.pixelRect(fromGlobalRect: globalRect, in: snapshot.geometry)
        guard pixelRect.width > 0, pixelRect.height > 0,
              let cropped = snapshot.image.cropping(to: pixelRect) else {
            transition(to: .idle)
            presentError("选区裁剪失败（pixelRect=\(pixelRect)）。")
            return
        }
        Log.app.info(
            "裁剪完成：\(Int(globalRect.width))×\(Int(globalRect.height)) pt → \(cropped.width)×\(cropped.height) px"
        )
        showEditor(image: cropped, logicalSize: globalRect.size)
    }

    // MARK: - 窗口截图

    /// 点击命中窗口：优先用 SCK 独立窗口截图（完整内容、无阴影、可被遮挡）；
    /// 匹配不到 SCWindow 时回退为从显示器快照裁剪（可能包含遮挡内容，已知限制）。
    private func completeWindowCapture(
        _ window: WindowInfo,
        session: ScreenCaptureService.CaptureSession
    ) {
        selectionController = nil
        let boundsText = "\(Int(window.cgBounds.minX)),\(Int(window.cgBounds.minY)) \(Int(window.cgBounds.width))×\(Int(window.cgBounds.height))"
        Log.app.info("窗口截图开始：\(window.displayName, privacy: .public) @ \(boundsText, privacy: .public)")

        Task { [weak self] in
            guard let self else { return }
            do {
                let matched = Self.matchSCWindow(for: window, in: session.windows)
                let image: CGImage
                let logicalSize: CGSize
                if let scWindow = matched {
                    let scale = self.scaleForWindow(cgBounds: window.cgBounds, snapshots: session.snapshots)
                    image = try await self.captureService.captureWindow(scWindow, scale: scale)
                    logicalSize = window.appKitFrame.size
                } else {
                    Log.app.notice("未匹配到 SCWindow，回退为快照裁剪")
                    guard let (cropped, size) = self.cropFallback(for: window, snapshots: session.snapshots) else {
                        self.transition(to: .idle)
                        self.presentError("窗口截图失败：无法定位窗口内容。")
                        return
                    }
                    image = cropped
                    logicalSize = size
                }
                self.showEditor(image: image, logicalSize: logicalSize)
            } catch {
                self.transition(to: .idle)
                self.presentError("窗口截图失败：\(error.localizedDescription)")
            }
        }
    }

    /// 按 pid + frame（CG 坐标系，两者一致）匹配 SCWindow，容差 1pt。
    private static func matchSCWindow(for window: WindowInfo, in scWindows: [SCWindow]) -> SCWindow? {
        scWindows.first { scWindow in
            guard scWindow.owningApplication?.processID == window.ownerPID else { return false }
            let frame = scWindow.frame
            return abs(frame.minX - window.cgBounds.minX) <= 1
                && abs(frame.minY - window.cgBounds.minY) <= 1
                && abs(frame.width - window.cgBounds.width) <= 1
                && abs(frame.height - window.cgBounds.height) <= 1
        }
    }

    /// 用窗口中心所在显示器的缩放系数决定窗口截图的输出像素密度。
    private func scaleForWindow(
        cgBounds: CGRect,
        snapshots: [ScreenCaptureService.DisplaySnapshot]
    ) -> CGFloat {
        let center = WindowFrameConverter.appKitPoint(
            fromCGPoint: CGPoint(x: cgBounds.midX, y: cgBounds.midY),
            primaryDisplayHeight: WindowFrameConverter.primaryDisplayHeight()
        )
        return snapshots
            .first { $0.geometry.logicalFrame.contains(center) }?
            .geometry.scaleFactor ?? 2
    }

    /// 回退路径：从包含窗口的显示器快照中裁剪窗口矩形。
    private func cropFallback(
        for window: WindowInfo,
        snapshots: [ScreenCaptureService.DisplaySnapshot]
    ) -> (CGImage, CGSize)? {
        guard let snapshot = snapshots.first(where: { $0.geometry.logicalFrame.contains(window.appKitFrame) })
            ?? snapshots.first(where: { $0.geometry.logicalFrame.intersects(window.appKitFrame) }) else {
            return nil
        }
        let pixelRect = ImageCoordinateConverter.pixelRect(fromGlobalRect: window.appKitFrame, in: snapshot.geometry)
        guard pixelRect.width > 0, pixelRect.height > 0,
              let cropped = snapshot.image.cropping(to: pixelRect) else {
            return nil
        }
        return (cropped, window.appKitFrame.size)
    }

    // MARK: - 全屏截图

    func captureFullScreen(of screen: NSScreen) {
        guard state == .idle else {
            Log.app.notice("忽略重复触发，当前状态 \(self.state.description)")
            return
        }

        guard ScreenRecordingPermission.isGranted else {
            showPermissionGuidance()
            return
        }
        transition(to: .selecting)
        let targetScreen = screen
        Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await self.captureService.captureFullScreen(of: targetScreen)
                Log.app.info("全屏截图完成：\(image.width)×\(image.height) px")
                self.showEditor(image: image, logicalSize: targetScreen.frame.size)
            } catch {
                self.transition(to: .idle)
                self.presentError("全屏截图失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 编辑器

    /// 截图完成后进入统一编辑器（需求 4.1 / 7.2：普通截图与长截图共用）。
    private func showEditor(image: CGImage, logicalSize: CGSize) {
        let document = ScreenshotDocument(image: image, logicalSize: logicalSize)
        let controller = EditorWindowController(
            document: document,
            onClose: { [weak self] in
                guard let self else { return }
                self.editorController = nil
                self.transition(to: .idle)
            },
            onPin: { [weak self] pinImage, pinLogicalSize in
                // 贴图放置在编辑器所在屏幕（此刻编辑器还是 key window）。
                guard let self else { return }
                self.pinManager.createPin(image: pinImage, logicalSize: pinLogicalSize, on: NSApp.keyWindow?.screen)
            }
        )
        editorController = controller
        transition(to: .editing)
        controller.show()
        if let longCaptureWarning {
            controller.showNotice(longCaptureWarning)
            self.longCaptureWarning = nil
        }
    }

    // MARK: - 权限引导

    func showPermissionGuidance() {
        transition(to: .permissionRequired)
        let controller = permissionController ?? PermissionWindowController(onDismissed: { [weak self] in
            guard let self else { return }
            self.permissionController = nil
            self.transition(to: .idle)
        })
        permissionController = controller
        controller.show()
    }

    // MARK: - 菜单入口（供 MenuBuilder 通过 target-action 调用）

    @objc func startRegionCaptureFromMenu() {
        startRegionCapture()
    }

    @objc func startLongCaptureFromMenu() {
        startLongCapture()
    }

    @objc func showSettingsFromMenu() {
        showSettings()
    }

    @objc func captureFullScreenFromMenu(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        captureFullScreen(of: screen)
    }

    // MARK: - 设置（Phase 5）

    func showSettings() {
        let controller = settingsController ?? SettingsWindowController(onHotkeyChanged: { [weak self] in
            self?.applyHotkeySettings()
        })
        settingsController = controller
        controller.show()
    }

    /// 设置页修改快捷键后：重新注册全局热键并刷新菜单显示。
    func applyHotkeySettings() {
        shortcutManager.registerRegionCapture(
            keyCode: SettingsManager.regionHotkeyKeyCode,
            modifiers: SettingsManager.regionHotkeyModifiers
        ) { [weak self] in
            self?.startRegionCapture()
        }
        NotificationCenter.default.post(name: .zSnapMenuShouldRefresh, object: nil)
        Log.app.info("区域截图快捷键已更新为 \(SettingsManager.regionHotkeyDisplay, privacy: .public)")
    }
}

extension Notification.Name {
    static let zSnapMenuShouldRefresh = Notification.Name("com.cd826.zSnap.menuShouldRefresh")
}
