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
        state.objectWillChange
            .sink { [weak self] _ in self?.handleStateChange() }
            .store(in: &cancellables)
        state.engine.objectWillChange
            .sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &cancellables)

        let magnification = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnification(_:)))
        addGestureRecognizer(magnification)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("未支持 IB 初始化")
    }

    override var acceptsFirstResponder: Bool { true }

    /// 状态变化（工具/颜色/缩放等）→ 重绘并按新参数重排显示区域。
    /// 注意：绝不在该路径写回任何 @Published 属性——objectWillChange 发出时新值尚未写入，
    /// 同步写回会造成守卫失效 + 无限递归（Phase 2 首版崩溃根因）。
    private func handleStateChange() {
        needsDisplay = true
        updateDisplayRect(updateFitScale: false)
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        // 仅真实布局变化（bounds 改变）时回写 fitScale，供"100%"按钮换算。
        updateDisplayRect(updateFitScale: true)
    }

    private func updateDisplayRect(updateFitScale: Bool) {
        let pixelSize = state.document.pixelSize
        guard pixelSize.width > 0, pixelSize.height > 0, bounds.width > 1, bounds.height > 1 else { return }
        let fit = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        let scale = fit * state.userZoom
        let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        displayRect = CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        displayScale = scale
        if updateFitScale {
            state.updateFitScale(fit)
        }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 背景（图片外区域）。
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()

        guard displayRect.width > 0 else { return }

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

    /// 事件 → 图片像素坐标（y 向下）。越界点不裁剪，便于拖拽连续性。
    private func imagePoint(for event: NSEvent) -> CGPoint {
        let windowPoint = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: (windowPoint.x - displayRect.minX) / displayScale,
            y: (displayRect.maxY - windowPoint.y) / displayScale
        )
    }

    private func normalize(_ imagePoint: CGPoint) -> CGPoint {
        let size = state.document.pixelSize
        return CGPoint(x: imagePoint.x / size.width, y: imagePoint.y / size.height)
    }

    /// 图片像素坐标 → 视图坐标（y 向上）。
    private func viewPoint(fromImage imagePoint: CGPoint) -> CGPoint {
        CGPoint(
            x: displayRect.minX + imagePoint.x * displayScale,
            y: displayRect.maxY - imagePoint.y * displayScale
        )
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
        let fieldHeight = fieldFontSize + 14
        let viewOrigin = viewPoint(fromImage: imagePoint)

        let field = NSTextField(frame: CGRect(
            x: viewOrigin.x,
            y: viewOrigin.y - fieldHeight,
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
        // 滚轮缩放（截图编辑器惯例）。
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
