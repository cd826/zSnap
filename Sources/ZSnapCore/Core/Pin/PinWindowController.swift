import AppKit

/// 贴图窗口：无边框置顶悬浮图片（需求 6.1 / 6.2）。
///
/// 关键设计：
/// - `NSPanel` + `.nonactivatingPanel`：点击贴图不激活 zSnap，不抢当前应用焦点（需求 6.2）。
/// - `.floating` 层 + `canJoinAllSpaces` + `fullScreenAuxiliary`：跨 Space 置顶。
/// - 拖动与缩放由内容视图手动接管：四角拖拽等比缩放（对角固定），其余区域按住拖动。
/// - 悬停工具栏：关闭 / 缩小 / 放大 / 复制 / 保存（需求 6.3），鼠标离开隐藏。
/// - 滚轮缩放（0.1×~8×，保持比例）；双击关闭。
@MainActor
final class PinWindowController: NSWindowController, NSWindowDelegate {
    /// 缩放上下限（相对逻辑尺寸）。
    static let zoomRange: ClosedRange<CGFloat> = 0.1...8

    private let image: CGImage
    private let logicalSize: CGSize
    private var zoomScale: CGFloat = 1
    private let onClose: (PinWindowController) -> Void
    private var toolbarView: PinToolbarView?
    private var toolbarHideWorkItem: DispatchWorkItem?

    init(image: CGImage, logicalSize: CGSize, onClose: @escaping (PinWindowController) -> Void) {
        self.image = image
        self.logicalSize = logicalSize
        self.onClose = onClose

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.initialSize(logicalSize: logicalSize, screen: nil)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 拖动由内容视图手动处理（需要区分四角缩放手势），不启用背景自动拖动。
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true

        super.init(window: panel)
        panel.delegate = self

        let contentView = PinContentView(image: image, controller: self)
        panel.contentView = contentView
        let toolbar = PinToolbarView(controller: self)
        contentView.addSubview(toolbar)
        toolbarView = toolbar
        layoutToolbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("未支持 IB 初始化")
    }

    /// 在指定屏幕居中显示（贴图时通常为编辑器所在屏幕）。
    func show(on screen: NSScreen?) {
        guard let window else { return }
        let targetScreen = screen ?? NSScreen.main
        // 按目标屏重新核定初始尺寸与缩放。
        let initial = Self.initialSize(logicalSize: logicalSize, screen: targetScreen)
        if logicalSize.width > 0 {
            zoomScale = initial.width / logicalSize.width
        }
        window.setContentSize(initial)

        let visible = targetScreen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        window.setFrameOrigin(CGPoint(
            x: visible.midX - initial.width / 2,
            y: visible.midY - initial.height / 2
        ))
        window.orderFrontRegardless()
        Log.pin.info("贴图上屏：\(Int(initial.width))×\(Int(initial.height)) pt @ \(targetScreen?.localizedName ?? "主屏", privacy: .public)")
    }

    /// 初始尺寸：按逻辑尺寸，不超过目标屏可见区 65%。
    static func initialSize(logicalSize: CGSize, screen: NSScreen?) -> CGSize {
        guard logicalSize.width > 0, logicalSize.height > 0 else { return CGSize(width: 320, height: 200) }
        let visible = screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        let scale = min(1, visible.width * 0.65 / logicalSize.width, visible.height * 0.65 / logicalSize.height)
        return CGSize(width: logicalSize.width * scale, height: logicalSize.height * scale)
    }

    // MARK: - 缩放

    func applyZoom(factor: CGFloat) {
        applyScale(zoomScale * factor)
    }

    /// 设置缩放比例，保持指定对角屏幕点固定（四角拖拽用）。
    fileprivate func applyScale(_ newScale: CGFloat, anchoredTo corner: PinContentView.Corner? = nil) {
        guard let window else { return }
        let clamped = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, newScale))
        guard abs(clamped - zoomScale) > 0.0001 || corner != nil else { return }
        zoomScale = clamped
        let newSize = NSSize(width: logicalSize.width * clamped, height: logicalSize.height * clamped)

        guard let corner else {
            window.setContentSize(newSize)
            return
        }
        // 对角锚定：移动角缩放时，对角屏幕位置保持不动。
        let frame = window.frame
        let origin: CGPoint
        switch corner {
        case .topLeft:
            origin = CGPoint(x: frame.maxX - newSize.width, y: frame.minY)
        case .topRight:
            origin = CGPoint(x: frame.minX, y: frame.minY)
        case .bottomLeft:
            origin = CGPoint(x: frame.maxX - newSize.width, y: frame.maxY - newSize.height)
        case .bottomRight:
            origin = CGPoint(x: frame.minX, y: frame.maxY - newSize.height)
        }
        window.setFrame(NSRect(origin: origin, size: newSize), display: true)
    }

    // MARK: - 输出

    func copyToPasteboard() {
        if ClipboardService.copyImage(image) {
            let width = image.width
            let height = image.height
            Log.pin.info("贴图已复制到剪贴板（\(width)×\(height) px）")
            showTransientMessage("已复制到剪贴板")
        } else {
            Log.pin.error("贴图复制失败：剪贴板写入不成功")
            showTransientMessage("复制失败")
        }
    }

    func savePNG() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ImageExportService.defaultFileName()
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return } // 用户取消不算失败
            guard let data = ImageExportService.pngData(self.image) else {
                self.presentSaveError("无法生成图片数据。")
                return
            }
            do {
                try data.write(to: url)
                Log.pin.info("贴图已保存：\(url.lastPathComponent, privacy: .public)")
            } catch {
                self.presentSaveError("写入文件失败：\(error.localizedDescription)")
            }
        }
    }

    private func presentSaveError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "保存失败"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - 轻量反馈

    /// 在贴图左上角短暂显示操作结果（贴图本身无其他反馈通道）。
    private var transientMessageView: NSTextField?
    private var transientMessageWorkItem: DispatchWorkItem?

    func showTransientMessage(_ text: String) {
        guard let contentView = window?.contentView else { return }
        transientMessageWorkItem?.cancel()

        if let existing = transientMessageView {
            existing.removeFromSuperview()
            transientMessageView = nil
        }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        label.layer?.cornerRadius = 5
        // NSTextField 自带约 2pt 内边距不足，包一层边距。
        let padding: CGFloat = 8
        let textSize = label.intrinsicContentSize
        label.frame = CGRect(x: 10, y: contentView.bounds.maxY - textSize.height - padding * 2 - 8,
                             width: textSize.width + padding * 2,
                             height: textSize.height + padding * 2)
        label.autoresizingMask = [.minXMargin, .minYMargin]
        contentView.addSubview(label)
        transientMessageView = label

        let item = DispatchWorkItem { [weak label] in
            label?.removeFromSuperview()
        }
        transientMessageWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: item)
    }

    // MARK: - 关闭

    /// 无边框窗口没有关闭按钮，performClose 会静默无效；必须直接 close。
    override func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        toolbarHideWorkItem?.cancel()
        toolbarView?.removeFromSuperview()
        toolbarView = nil
        Log.pin.info("贴图关闭，释放图像资源")
        onClose(self)
    }

    func windowDidResize(_ notification: Notification) {
        layoutToolbar()
    }

    // MARK: - 悬停工具栏

    fileprivate func setToolbarHidden(_ hiddenFlag: Bool) {
        guard let toolbar = toolbarView else { return }
        toolbarHideWorkItem?.cancel()
        if hiddenFlag {
            toolbar.animator().alphaValue = 0
            let item = DispatchWorkItem { [weak toolbar] in
                toolbar?.isHidden = true
            }
            toolbarHideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
        } else {
            toolbar.isHidden = false
            toolbar.animator().alphaValue = 1
        }
    }

    private func layoutToolbar() {
        guard let toolbar = toolbarView, let window, let contentView = window.contentView else { return }
        let size = toolbar.fittingSize
        toolbar.frame = CGRect(
            x: contentView.bounds.maxX - size.width - 8,
            y: contentView.bounds.maxY - size.height - 8,
            width: size.width,
            height: size.height
        )
        toolbar.autoresizingMask = [.minXMargin, .minYMargin]
    }
}

// MARK: - 贴图内容视图（拖动 / 四角缩放 / 悬停）

@MainActor
private final class PinContentView: NSView {
    enum Corner {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// 拖动窗口会话。
    private struct DragSession {
        let startMouseScreen: CGPoint
        let startWindowOrigin: CGPoint
    }

    /// 四角缩放会话。
    private struct ResizeSession {
        let corner: Corner
        let fixedScreenPoint: CGPoint
        let startDistance: CGFloat
        let startScale: CGFloat
    }

    private let image: CGImage
    private weak var controller: PinWindowController?
    private var trackingArea: NSTrackingArea?
    private var dragSession: DragSession?
    private var resizeSession: ResizeSession?
    private var isMouseInside = false

    /// 角落命中半径（pt）。
    private static let cornerHitRadius: CGFloat = 18

    init(image: CGImage, controller: PinWindowController) {
        self.image = image
        self.controller = controller
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("未支持 IB 初始化")
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)

        // 悬停时绘制四角拉手（视觉提示）。
        if isMouseInside {
            drawCornerHandles()
        }
    }

    private func drawCornerHandles() {
        let inset: CGFloat = 5
        let arm: CGFloat = 14
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: bounds.minX + inset, y: bounds.maxY - inset), CGPoint(x: bounds.minX + inset + arm, y: bounds.maxY - inset), CGPoint(x: bounds.minX + inset, y: bounds.maxY - inset - arm)),
            (CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset), CGPoint(x: bounds.maxX - inset - arm, y: bounds.maxY - inset), CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset - arm)),
            (CGPoint(x: bounds.minX + inset, y: bounds.minY + inset), CGPoint(x: bounds.minX + inset + arm, y: bounds.minY + inset), CGPoint(x: bounds.minX + inset, y: bounds.minY + inset + arm)),
            (CGPoint(x: bounds.maxX - inset, y: bounds.minY + inset), CGPoint(x: bounds.maxX - inset - arm, y: bounds.minY + inset), CGPoint(x: bounds.maxX - inset, y: bounds.minY + inset + arm))
        ]
        let path = NSBezierPath()
        path.lineWidth = 2.5
        path.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        for (cornerPoint, horizontalEnd, verticalEnd) in corners {
            path.move(to: horizontalEnd)
            path.line(to: cornerPoint)
            path.line(to: verticalEnd)
        }
        path.stroke()
    }

    // MARK: 跟踪区

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        // 四角按对角方向给缩放光标（系统无内置对角光标，用符号图自绘）。
        let radius = Self.cornerHitRadius
        addCursorRect(CGRect(x: 0, y: bounds.maxY - radius, width: radius, height: radius), cursor: Self.nwseCursor)
        addCursorRect(CGRect(x: bounds.maxX - radius, y: bounds.minY, width: radius, height: radius), cursor: Self.nwseCursor)
        addCursorRect(CGRect(x: bounds.maxX - radius, y: bounds.maxY - radius, width: radius, height: radius), cursor: Self.neswCursor)
        addCursorRect(CGRect(x: 0, y: 0, width: radius, height: radius), cursor: Self.neswCursor)
    }

    // MARK: 自定义对角缩放光标

    private static let nwseCursor = makeDiagonalCursor(symbol: "arrow.up.left.and.arrow.down.right")
    private static let neswCursor = makeDiagonalCursor(symbol: "arrow.up.right.and.arrow.down.left")

    private static func makeDiagonalCursor(symbol name: String) -> NSCursor {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) else {
                return false
            }
            // 黑色符号 + 白色柔边，保证深浅背景上都可见。
            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.white
            shadow.shadowOffset = .zero
            shadow.shadowBlurRadius = 2
            shadow.set()
            NSColor.black.set()
            symbol.draw(in: NSRect(x: 2, y: 2, width: 14, height: 14))
            NSGraphicsContext.current?.restoreGraphicsState()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
    }

    // MARK: 命中

    private func corner(at point: CGPoint) -> Corner? {
        let radius = Self.cornerHitRadius
        let candidates: [(Corner, CGPoint)] = [
            (.topLeft, CGPoint(x: bounds.minX, y: bounds.maxY)),
            (.topRight, CGPoint(x: bounds.maxX, y: bounds.maxY)),
            (.bottomLeft, CGPoint(x: bounds.minX, y: bounds.minY)),
            (.bottomRight, CGPoint(x: bounds.maxX, y: bounds.minY))
        ]
        for (corner, cornerPoint) in candidates where hypot(point.x - cornerPoint.x, point.y - cornerPoint.y) <= radius {
            return corner
        }
        return nil
    }

    private func screenPoint(forViewPoint point: CGPoint) -> CGPoint {
        guard let window else { return .zero }
        return window.convertToScreen(CGRect(origin: point, size: .zero)).origin
    }

    private func viewPoint(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        let point = viewPoint(for: event)

        // 双击图像区域关闭（工具栏按钮的点击不会进入本方法；四角留给缩放）。
        if event.clickCount >= 2, corner(at: point) == nil {
            dragSession = nil
            resizeSession = nil
            controller?.close()
            return
        }

        if let corner = corner(at: point) {
            // 四角缩放：对角锚定。
            let fixedViewPoint: CGPoint
            switch corner {
            case .topLeft: fixedViewPoint = CGPoint(x: bounds.maxX, y: bounds.minY)
            case .topRight: fixedViewPoint = CGPoint(x: bounds.minX, y: bounds.minY)
            case .bottomLeft: fixedViewPoint = CGPoint(x: bounds.maxX, y: bounds.maxY)
            case .bottomRight: fixedViewPoint = CGPoint(x: bounds.minX, y: bounds.maxY)
            }
            let fixedScreen = screenPoint(forViewPoint: fixedViewPoint)
            let mouseScreen = screenPoint(forViewPoint: point)
            let distance = hypot(mouseScreen.x - fixedScreen.x, mouseScreen.y - fixedScreen.y)
            guard distance > 1, let controller else { return }
            resizeSession = ResizeSession(
                corner: corner,
                fixedScreenPoint: fixedScreen,
                startDistance: distance,
                startScale: controller.zoomScaleForResize
            )
        } else {
            // 整窗拖动。
            dragSession = DragSession(
                startMouseScreen: screenPoint(forViewPoint: point),
                startWindowOrigin: window?.frame.origin ?? .zero
            )
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = viewPoint(for: event)

        if let session = resizeSession {
            let mouseScreen = screenPoint(forViewPoint: point)
            let distance = hypot(mouseScreen.x - session.fixedScreenPoint.x, mouseScreen.y - session.fixedScreenPoint.y)
            guard session.startDistance > 1, let controller else { return }
            controller.applyScale(session.startScale * (distance / session.startDistance), anchoredTo: session.corner)
        } else if let session = dragSession {
            let mouseScreen = screenPoint(forViewPoint: point)
            let deltaX = mouseScreen.x - session.startMouseScreen.x
            let deltaY = mouseScreen.y - session.startMouseScreen.y
            window?.setFrameOrigin(CGPoint(
                x: session.startWindowOrigin.x + deltaX,
                y: session.startWindowOrigin.y + deltaY
            ))
        }
    }

    override func mouseUp(with event: NSEvent) {
        resizeSession = nil
        dragSession = nil
    }

    // MARK: 悬停

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        needsDisplay = true
        controller?.setToolbarHidden(false)
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        needsDisplay = true
        controller?.setToolbarHidden(true)
    }

    override func scrollWheel(with event: NSEvent) {
        let factor = pow(1.1, -event.scrollingDeltaY)
        if abs(factor - 1) > 0.001 {
            controller?.applyZoom(factor: factor)
        }
    }
}

// MARK: - 悬停工具栏（需求 6.3：关闭 / 缩放 / 复制 / 保存）

@MainActor
private final class PinToolbarView: NSVisualEffectView {
    private weak var controller: PinWindowController?

    init(controller: PinWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        material = .hudWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        isHidden = true
        alphaValue = 0

        let stack = NSStackView(views: [
            Self.button(symbol: "xmark", help: "关闭贴图（双击亦可）", controller, #selector(PinWindowController.close)),
            Self.button(symbol: "minus.magnifyingglass", help: "缩小（滚轮/拖角亦可）", controller, #selector(PinWindowController.zoomOut)),
            Self.button(symbol: "plus.magnifyingglass", help: "放大（滚轮/拖角亦可）", controller, #selector(PinWindowController.zoomIn)),
            Self.button(symbol: "doc.on.doc", help: "复制到剪贴板", controller, #selector(PinWindowController.copyAction)),
            Self.button(symbol: "square.and.arrow.down", help: "保存 PNG", controller, #selector(PinWindowController.saveAction))
        ])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 7, bottom: 4, right: 7)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("未支持 IB 初始化")
    }

    private static func button(symbol: String, help: String, _ target: NSWindowController?, _ action: Selector) -> NSButton {
        let button = NSButton(title: "", target: target, action: action)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = help
        button.contentTintColor = .labelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }
}

// MARK: - 控制器动作桥（target/action 入口）

@MainActor
extension PinWindowController {
    /// 供缩放会话读取当前比例。
    fileprivate var zoomScaleForResize: CGFloat { zoomScale }

    @objc func zoomIn() {
        applyZoom(factor: 1.25)
    }

    @objc func zoomOut() {
        applyZoom(factor: 0.8)
    }

    @objc func copyAction() {
        copyToPasteboard()
    }

    @objc func saveAction() {
        savePNG()
    }
}
