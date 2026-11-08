import AppKit

/// 一次选区会话：在每个显示器上放置覆盖窗口，聚合鼠标事件，
/// 以全局逻辑坐标维护选区，并支持悬停高亮窗口（智能点击）。
///
/// 结束方式：
/// - 拖拽后松开 → onFinish（区域截图，钳制在起始显示器内）
/// - 点击命中悬停窗口 → onWindowCapture（窗口截图）
/// - 点击空白处 → onFinish（该屏全屏）
/// - Esc → onCancel
@MainActor
final class SelectionOverlayController {
    /// 区域/全屏完成：选区（全局逻辑坐标）+ 该显示器快照。
    let onFinish: (CGRect, ScreenCaptureService.DisplaySnapshot) -> Void
    /// 点击命中窗口：交给协调器走 SCK 独立窗口截图。
    let onWindowCapture: (WindowInfo) -> Void
    let onCancel: () -> Void

    private let snapshots: [ScreenCaptureService.DisplaySnapshot]
    /// 会话开始时的窗口快照（z 序：从最前到最后）。
    private let windowList: [WindowInfo]
    private var windows: [OverlayWindow] = []
    private var views: [SelectionOverlayView] = []
    private var dragStartGlobal: CGPoint?
    private var hoveredWindow: WindowInfo?
    private var mouseMovedMonitor: Any?
    private var hasFinished = false

    init(
        snapshots: [ScreenCaptureService.DisplaySnapshot],
        windows: [WindowInfo],
        onFinish: @escaping (CGRect, ScreenCaptureService.DisplaySnapshot) -> Void,
        onWindowCapture: @escaping (WindowInfo) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.snapshots = snapshots
        self.windowList = windows
        self.onFinish = onFinish
        self.onWindowCapture = onWindowCapture
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
        installHoverMonitor()
        Log.selection.info("选区会话开始，覆盖 \(self.windows.count) 个显示器，常规窗口 \(self.windowList.count) 个")
    }

    func cancel() {
        guard !hasFinished else { return }
        hasFinished = true
        Log.selection.info("选区会话取消")
        teardown()
        onCancel()
    }

    // MARK: - 悬停高亮（智能点击）

    /// 鼠标移动事件经本应用分发；转换为全局逻辑坐标后做窗口命中测试。
    /// 仅 key window 能收到 mouseMoved，但坐标是全局的，跨屏命中不受影响。
    private func installHoverMonitor() {
        mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleHover(with: event)
            return event
        }
    }

    private func handleHover(with event: NSEvent) {
        // 拖拽过程中不更新高亮，保持选区视觉稳定。
        guard dragStartGlobal == nil, !hasFinished, let window = event.window else { return }
        // mouseMoved 的 locationInWindow 即窗口坐标（可能越界），直接换算全局坐标。
        let globalPoint = window.convertToScreen(CGRect(origin: event.locationInWindow, size: .zero)).origin

        let hit = WindowListService.topWindow(at: globalPoint, in: windowList)
        guard hit?.windowID != hoveredWindow?.windowID else { return }
        hoveredWindow = hit
        views.forEach { $0.setHovered(hit) }
    }

    // MARK: - 事件聚合

    private func handleMouseDown(_ point: CGPoint) {
        dragStartGlobal = point
        // 立即命中测试：光标未移动（无 mouseMoved）直接点击时也能命中窗口。
        let hit = WindowListService.topWindow(at: point, in: windowList)
        if hit?.windowID != hoveredWindow?.windowID {
            hoveredWindow = hit
            views.forEach { $0.setHovered(hit) }
        }
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
            // 智能点击：命中窗口 → 窗口截图；空白处 → 该屏全屏。
            // 注意：必须在 teardown() 之前取值，teardown 会清空悬停状态。
            let tappedWindow = hoveredWindow
            hasFinished = true
            teardown()
            if let hovered = tappedWindow {
                Log.selection.info("点击命中窗口：\(hovered.displayName, privacy: .public)")
                onWindowCapture(hovered)
            } else if let snapshot = snapshots.first(where: { $0.geometry.displayID == geometry.displayID }) {
                Log.selection.info("点击空白处 → 截取显示器 \(geometry.displayID) 全屏")
                onFinish(geometry.logicalFrame, snapshot)
            }
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
        if let monitor = mouseMovedMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMovedMonitor = nil
        }
        hoveredWindow = nil
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
