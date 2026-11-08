import AppKit

/// 应用协调器：唯一的状态机持有者，负责截图流程编排（需求 9.1 / 9.2）。
/// 正在选区或展示结果时，重复触发会被拒绝并留痕。
@MainActor
final class AppCoordinator: NSObject {
    private(set) var state: AppState = .idle

    let shortcutManager = ShortcutManager()
    private let captureService = ScreenCaptureService()

    private var selectionController: SelectionOverlayController?
    private var previewController: SnapshotPreviewController?
    private var permissionController: PermissionWindowController?

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
        guard state == .idle || state == .presentingResult else {
            Log.app.notice("忽略重复触发，当前状态 \(self.state.description)")
            return
        }
        closePreviewIfNeeded()

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
            let snapshots = try await captureService.captureAllDisplays()
            beginSelection(with: snapshots)
        } catch {
            transition(to: .idle)
            presentError("截图失败：\(error.localizedDescription)")
        }
    }

    private func beginSelection(with snapshots: [ScreenCaptureService.DisplaySnapshot]) {
        let controller = SelectionOverlayController(
            snapshots: snapshots,
            onFinish: { [weak self] globalRect, snapshot in
                self?.completeSelection(globalRect: globalRect, snapshot: snapshot)
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.selectionController = nil
                self.transition(to: .idle)
            }
        )
        selectionController = controller
        controller.begin()
    }

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
        showPreview(image: cropped, logicalSize: globalRect.size)
    }

    // MARK: - 全屏截图（Phase 0 验证入口）

    func captureFullScreen(of screen: NSScreen) {
        guard state == .idle || state == .presentingResult else {
            Log.app.notice("忽略重复触发，当前状态 \(self.state.description)")
            return
        }
        closePreviewIfNeeded()

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
                self.showPreview(image: image, logicalSize: targetScreen.frame.size)
            } catch {
                self.transition(to: .idle)
                self.presentError("全屏截图失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 预览

    private func showPreview(image: CGImage, logicalSize: CGSize) {
        let controller = SnapshotPreviewController(
            image: image,
            title: "zSnap 预览 — \(image.width)×\(image.height) px",
            preferredSize: logicalSize,
            onClose: { [weak self] in
                guard let self else { return }
                self.previewController = nil
                self.transition(to: .idle)
            }
        )
        previewController = controller
        transition(to: .presentingResult)
        controller.show()
    }

    private func closePreviewIfNeeded() {
        guard let preview = previewController else { return }
        previewController = nil
        preview.close()
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

    @objc func captureFullScreenFromMenu(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        captureFullScreen(of: screen)
    }
}
