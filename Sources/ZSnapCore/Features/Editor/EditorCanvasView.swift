import AppKit
import Combine

/// 编辑器画布：图片展示（适配/缩放）、标注实时预览、选中/移动、文字输入。
/// 非翻转视图（y 向上）；图片/标注绘制经由 AnnotationRenderer 的 displayRect 变换，
/// 鼠标坐标统一换算到图片像素空间（y 向下）参与命中与存储。
@MainActor
final class EditorCanvasView: NSView {
    private let state: EditorState
    private var cancellables: Set<AnyCancellable> = []

    /// 图片显示区域（视图坐标，y 向上）。
    private var displayRect: CGRect = .zero
    private var displayScale: CGFloat = 1

    // 进行中绘制（图片像素坐标，y 向下）。
    private var draftStart: CGPoint?
    private var draftEnd: CGPoint?

    // 拖动选中标注。
    private var movingAnnotation: Annotation?
    private var moveOrigin: CGPoint?

    // 文字输入。
    private var activeTextField: NSTextField?
    private var pendingTextOrigin: CGPoint?
    private var discardPendingText = false

    init(state: EditorState) {
        self.state = state
        super.init(frame: .zero)

        // 状态/引擎变化 → 重绘。
        // 必须异步执行：objectWillChange 是 willSet 通知，同步读取发布属性会拿到旧值
        //（表现为"点两次才生效"）；下一轮主循环时新值已提交。
        state.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.handleStateChange()
                }
            }
            .store(in: &cancellables)
        state.engine.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.needsDisplay = true
                }
            }
            .store(in: &cancellables)

        let magnification = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnification(_:)))
        addGestureRecognizer(magnification)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("未支持 IB 初始化")
    }

    override var acceptsFirstResponder: Bool { true }

    private var clipViewFrameObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clipViewFrameObserver {
            NotificationCenter.default.removeObserver(clipViewFrameObserver)
            self.clipViewFrameObserver = nil
        }
        guard let scrollView = enclosingScrollView else { return }
        // 窗口/分栏尺寸变化 → 重新适配（监听裁剪视图 frame 变化；滚动不触发）。
        scrollView.contentView.postsFrameChangedNotifications = true
        clipViewFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateDisplayRect()
            }
        }
        updateDisplayRect()
    }

    deinit {
        if let clipViewFrameObserver {
            NotificationCenter.default.removeObserver(clipViewFrameObserver)
        }
    }

    /// 状态变化（工具/颜色/缩放等）→ 重绘并按新参数重排显示区域。
    /// 注意：绝不在该路径写回任何 @Published 属性——objectWillChange 发出时新值尚未写入，
    /// 同步写回会造成守卫失效 + 无限递归（Phase 2 首版崩溃根因）。
    private func handleStateChange() {
        needsDisplay = true
        updateDisplayRect()
    }

    // MARK: - 布局

    /// 翻转视图（y 向下）：长图在滚动视图内从顶部开始展示。
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(1, displayRect.width), height: max(1, displayRect.height))
    }

    override func layout() {
        super.layout()
        updateDisplayRect()
    }

    private func updateDisplayRect() {
        let pixelSize = state.document.pixelSize
        // 适配基准 = 滚动视图可视区域（NSScrollView 不会自动设定 documentView 尺寸，
        // 必须由此处显式管理 frame，否则画布为 0 尺寸 → 黑屏）。
        var visible = enclosingScrollView?.contentSize ?? .zero
        if visible.width < 2 || visible.height < 2 {
            visible = bounds.size
        }
        guard pixelSize.width > 0, pixelSize.height > 0, visible.width > 1, visible.height > 1 else { return }

        let fit = min(visible.width / pixelSize.width, visible.height / pixelSize.height)
        state.updateFitScale(fit)
        // 显示比例为绝对值（适应模式下由 updateFitScale 跟随窗口，手动缩放后固定）。
        let scale = state.displayScale
        let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)

        // 文档视图尺寸 = max(图片显示尺寸, 可视区域)：图小于视口时居中，大图可滚动。
        let newSize = NSSize(
            width: max(size.width, visible.width),
            height: max(size.height, visible.height)
        )
        if frame.size != newSize {
            setFrameSize(newSize) // 触发 layout，重入时尺寸相同自然收敛。
        }

        // 绘制统一在 y-up 空间：图片在文档视图中居中。
        displayRect = CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        displayScale = scale
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 背景（图片外区域）。
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()

        guard displayRect.width > 0 else { return }

        // 翻转视图 → 统一切换到"y 向上"空间绘制，后续逻辑与坐标不变。
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        defer { context.restoreGState() }

        // 1. 原始图片（非翻转上下文直接绘制即正立）。
        context.interpolationQuality = .high
        context.draw(state.document.image, in: displayRect)

        // 2. 标注 + 进行中绘制（共用渲染器，保证所见即所得）。
        let imageSize = state.document.pixelSize
        let mosaic = state.mosaicImage()
        AnnotationRenderer.draw(
            state.engine.annotations,
            in: context,
            imageSize: imageSize,
            mosaicImage: mosaic,
            displayRect: displayRect
        )
        if let draft = draftAnnotation() {
            AnnotationRenderer.draw(
                [draft],
                in: context,
                imageSize: imageSize,
                mosaicImage: mosaic,
                displayRect: displayRect
            )
        }

        // 3. 选中框。
        if let selected = state.selectedAnnotation,
           let boundsInImage = AnnotationRenderer.annotationBounds(selected, imageSize: imageSize) {
            drawSelectionFrame(boundsInImage)
        }
    }

    private func drawSelectionFrame(_ boundsInImage: CGRect) {
        let viewRect = CGRect(
            x: displayRect.minX + boundsInImage.minX * displayScale,
            y: displayRect.maxY - boundsInImage.maxY * displayScale,
            width: boundsInImage.width * displayScale,
            height: boundsInImage.height * displayScale
        )
        let path = NSBezierPath(rect: viewRect)
        path.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        path.stroke()

        // 四角控制点（视觉提示；本阶段仅支持移动）。
        let handleSize: CGFloat = 7
        NSColor.controlAccentColor.setFill()
        for corner in [viewRect.origin, CGPoint(x: viewRect.maxX, y: viewRect.minY),
                       CGPoint(x: viewRect.minX, y: viewRect.maxY), CGPoint(x: viewRect.maxX, y: viewRect.maxY)] {
            let handleRect = CGRect(
                x: corner.x - handleSize / 2,
                y: corner.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            NSBezierPath(roundedRect: handleRect, xRadius: 2, yRadius: 2).fill()
        }
    }

    // MARK: - 坐标换算

    /// 事件 → 图片像素坐标（y 向下）。翻转视图的 y-down 局部坐标先转回 y-up 再映射。
    private func imagePoint(for event: NSEvent) -> CGPoint {
        let flippedPoint = convert(event.locationInWindow, from: nil)
        let yUp = bounds.height - flippedPoint.y
        return CGPoint(
            x: (flippedPoint.x - displayRect.minX) / displayScale,
            y: (displayRect.maxY - yUp) / displayScale
        )
    }

    private func normalize(_ imagePoint: CGPoint) -> CGPoint {
        let size = state.document.pixelSize
        return CGPoint(x: imagePoint.x / size.width, y: imagePoint.y / size.height)
    }

    /// 图片像素坐标 → 视图 y-up 坐标（用于绘制空间计算）。
    private func viewPoint(fromImage imagePoint: CGPoint) -> CGPoint {
        CGPoint(
            x: displayRect.minX + imagePoint.x * displayScale,
            y: displayRect.maxY - imagePoint.y * displayScale
        )
    }

    /// y-up 视图坐标 → 翻转视图坐标（用于子视图摆放）。
    private func flippedPoint(fromUp point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: bounds.height - point.y)
    }

    // MARK: - 鼠标交互

    override func mouseDown(with event: NSEvent) {
        // 文字输入中：先结束输入。
        if activeTextField != nil {
            commitTextInput()
            return
        }
        let point = imagePoint(for: event)

        switch state.tool {
        case .select:
            if let hit = hitTestAnnotation(at: point) {
                state.selectedAnnotationID = hit.id
                movingAnnotation = hit
                moveOrigin = point
                state.engine.beginBatch()
            } else {
                state.selectedAnnotationID = nil
            }
        case .text:
            beginTextInput(at: point)
        case .arrow, .rectangle, .ellipse, .mosaic:
            draftStart = point
            draftEnd = point
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(for: event)

        if let moving = movingAnnotation, let origin = moveOrigin {
            let imageSize = state.document.pixelSize
            var updated = moving
            let dx = (point.x - origin.x) / imageSize.width
            let dy = (point.y - origin.y) / imageSize.height
            updated.normalizedPoints = moving.normalizedPoints.map {
                CGPoint(x: $0.x + dx, y: $0.y + dy)
            }
            state.engine.updateWithoutHistory(updated)
        } else if draftStart != nil {
            draftEnd = point
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = imagePoint(for: event)

        if movingAnnotation != nil {
            movingAnnotation = nil
            moveOrigin = nil
        } else if let start = draftStart {
            draftStart = nil
            draftEnd = nil
            let distance = hypot(point.x - start.x, point.y - start.y)
            if distance >= 3, let draft = draftAnnotation(start: start, end: point) {
                state.engine.add(draft)
            }
        }
        needsDisplay = true
    }

    private func draftAnnotation(start: CGPoint? = nil, end: CGPoint? = nil) -> Annotation? {
        let s = start ?? draftStart
        let e = end ?? draftEnd
        guard let s, let e else { return nil }
        let type: AnnotationType
        switch state.tool {
        case .arrow: type = .arrow
        case .rectangle: type = .rectangle
        case .ellipse: type = .ellipse
        case .mosaic: type = .mosaic
        default: return nil
        }
        return Annotation(
            type: type,
            color: state.color,
            lineWidth: state.currentLineWidthPx,
            normalizedPoints: [normalize(s), normalize(e)],
            text: nil,
            fontSize: nil
        )
    }

    // MARK: - 命中测试

    private func hitTestAnnotation(at point: CGPoint) -> Annotation? {
        let imageSize = state.document.pixelSize
        // 从最上层（数组末尾）向下查找。
        for annotation in state.engine.annotations.reversed() {
            if AnnotationRenderer.isHit(annotation, at: point, imageSize: imageSize) {
                return annotation
            }
        }
        return nil
    }

    // MARK: - 文字输入

    private func beginTextInput(at imagePoint: CGPoint) {
        guard activeTextField == nil else { return }
        let fontSizePx = state.currentFontSizePx
        let fieldFontSize = max(10, fontSizePx * displayScale)
        let fieldWidth: CGFloat = 260
        // 高度收紧贴字：避免 NSTextField 垂直居中导致输入所见与最终渲染错位。
        let fieldHeight = ceil(fieldFontSize * 1.4) + 2
        let viewOrigin = viewPoint(fromImage: imagePoint)

        // 输入框顶边对齐点击点（翻转坐标 y 向下），与渲染规则一致：
        // 点击点 = 文字块左上角。
        let field = NSTextField(frame: CGRect(
            x: viewOrigin.x,
            y: flippedPoint(fromUp: viewOrigin).y,
            width: fieldWidth,
            height: fieldHeight
        ))
        field.isBordered = true
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: fieldFontSize, weight: .medium)
        field.placeholderString = "输入文字，回车确认"
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)

        activeTextField = field
        pendingTextOrigin = imagePoint
        discardPendingText = false
    }

    private func commitTextInput() {
        guard let field = activeTextField else { return }
        let text = field.stringValue
        let origin = pendingTextOrigin
        activeTextField = nil
        pendingTextOrigin = nil
        field.removeFromSuperview()

        guard !discardPendingText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let origin else { return }
        state.engine.add(Annotation(
            type: .text,
            color: state.color,
            lineWidth: 0,
            normalizedPoints: [normalize(origin)],
            text: text,
            fontSize: state.currentFontSizePx
        ))
        needsDisplay = true
    }

    private func discardTextInput() {
        discardPendingText = true
        activeTextField?.removeFromSuperview()
        activeTextField = nil
        pendingTextOrigin = nil
        window?.makeFirstResponder(self)
    }

    // MARK: - 缩放

    @objc private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
        state.applyZoomDelta(1 + gesture.magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        // ⌘+滚轮缩放；普通滚轮交给滚动视图（长图浏览）。
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = -event.scrollingDeltaY * 0.002
        if abs(delta) > 0.0001 {
            state.applyZoomDelta(1 + delta)
        }
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased()

        switch event.keyCode {
        case 53: // Esc
            handleEscape()
        case 51, 117: // Delete / Forward Delete
            state.deleteSelected()
        default:
            if hasCommand, key == "z" {
                if flags.contains(.shift) {
                    state.redo()
                } else {
                    state.undo()
                }
            } else if hasCommand, key == "c" {
                state.copyFinalImage()
            } else if hasCommand, key == "s" {
                state.savePNG(parentWindow: window)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func handleEscape() {
        if activeTextField != nil {
            discardTextInput()
        } else if draftStart != nil {
            draftStart = nil
            draftEnd = nil
            needsDisplay = true
        } else if state.selectedAnnotationID != nil {
            state.selectedAnnotationID = nil
            needsDisplay = true
        } else {
            window?.performClose(nil)
        }
    }
}

// MARK: - 文字输入代理

extension EditorCanvasView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        if discardPendingText {
            discardTextInput()
        } else {
            commitTextInput()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            discardPendingText = true
            return false // 让字段正常结束编辑，随后走 discard 路径
        }
        return false
    }
}
