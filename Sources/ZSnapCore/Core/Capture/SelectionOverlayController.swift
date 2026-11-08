import AppKit

/// 一次选区会话：在每个显示器上放置覆盖窗口，聚合各窗口的鼠标事件，
/// 以全局逻辑坐标维护选区，结束后回调选区矩形与起始显示器的快照。
@MainActor
final class SelectionOverlayController {
    /// 完成：选区（全局逻辑坐标，已限制在起始显示器逻辑框内）+ 该显示器快照。
    let onFinish: (CGRect, ScreenCaptureService.DisplaySnapshot) -> Void
    let onCancel: () -> Void

    private let snapshots: [ScreenCaptureService.DisplaySnapshot]
    private var windows: [OverlayWindow] = []
    private var views: [SelectionOverlayView] = []
    private var dragStartGlobal: CGPoint?
    private var hasFinished = false

    init(
        snapshots: [ScreenCaptureService.DisplaySnapshot],
        onFinish: @escaping (CGRect, ScreenCaptureService.DisplaySnapshot) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.snapshots = snapshots
        self.onFinish = onFinish
        self.onCancel = onCancel
    }

    func begin() {
        for snapshot in snapshots {
            let window = OverlayWindow(
                contentRect: snapshot.geometry.logicalFrame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.hidesOnDeactivate = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.isReleasedWhenClosed = false

            let view = SelectionOverlayView(snapshot: snapshot.image, geometry: snapshot.geometry)
            view.frame = NSRect(origin: .zero, size: snapshot.geometry.logicalFrame.size)
            view.onMouseDown = { [weak self] in self?.handleMouseDown($0) }
            view.onMouseDragged = { [weak self] in self?.handleMouseDragged($0) }
            view.onMouseUp = { [weak self] in self?.handleMouseUp($0, in: snapshot.geometry) }
            view.onEscape = { [weak self] in self?.cancel() }
            window.contentView = view
            window.initialFirstResponder = view

            windows.append(window)
            views.append(view)
        }

        windows.forEach { $0.orderFrontRegardless() }
        windows.first?.makeKeyAndOrderFront(nil)
        if let firstWindow = windows.first, let firstView = views.first {
            firstWindow.makeFirstResponder(firstView)
        }
        NSApp.activate()
        NSCursor.crosshair.push()
        Log.selection.info("选区会话开始，覆盖 \(self.windows.count) 个显示器")
    }

    func cancel() {
        guard !hasFinished else { return }
        hasFinished = true
        Log.selection.info("选区会话取消")
        teardown()
        onCancel()
    }

    // MARK: - 事件聚合

    private func handleMouseDown(_ point: CGPoint) {
        dragStartGlobal = point
        updateSelection(RectMath.normalizedRect(from: point, to: point))
    }

    private func handleMouseDragged(_ point: CGPoint) {
        guard let start = dragStartGlobal else { return }
        updateSelection(RectMath.normalizedRect(from: start, to: point))
    }

    private func handleMouseUp(_ point: CGPoint, in geometry: DisplayGeometry) {
        guard let start = dragStartGlobal else { return }
        dragStartGlobal = nil

        let rect = RectMath.normalizedRect(from: start, to: point)
        guard !RectMath.isTapTooSmall(rect, threshold: 6) else {
            // 点击无拖拽 → 截取该显示器全屏（交互约定，参考微信截图）。
            guard let snapshot = snapshots.first(where: { $0.geometry.displayID == geometry.displayID }) else {
                cancel()
                return
            }
            hasFinished = true
            Log.selection.info("点击无拖拽 → 截取显示器 \(geometry.displayID) 全屏")
            teardown()
            onFinish(geometry.logicalFrame, snapshot)
            return
        }
        guard let snapshot = snapshots.first(where: { $0.geometry.displayID == geometry.displayID }) else {
            cancel()
            return
        }

        hasFinished = true
        // 当前版本：选区限制在起始显示器内（跨屏选区先钳制，跨屏拼接属后续阶段）。
        let clamped = rect.intersection(geometry.logicalFrame)
        Log.selection.info(
            "选区完成：\(Int(clamped.minX)),\(Int(clamped.minY)) \(Int(clamped.width))×\(Int(clamped.height)) pt @ 显示器 \(geometry.displayID)"
        )
        teardown()
        onFinish(clamped, snapshot)
    }

    private func updateSelection(_ rect: CGRect?) {
        views.forEach { $0.setSelection(rect) }
    }

    private func teardown() {
        views.removeAll()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.pop()
    }

    /// 无边框窗口默认不能成为 key window，必须重写才能接收 Esc 等键盘事件。
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
}
