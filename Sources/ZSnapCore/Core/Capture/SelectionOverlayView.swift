import AppKit
import Carbon.HIToolbox

/// 单个显示器上的选区覆盖视图：
/// 绘制冻结快照、选区外压暗遮罩、选区边框与尺寸标签，并把鼠标/键盘事件上抛给控制器。
@MainActor
final class SelectionOverlayView: NSView {
    /// 选区外压暗强度（0~1）。太透会导致选区与周围内容难以区分。
    private static let dimmingAlpha: CGFloat = 0.65

    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onEscape: (() -> Void)?

    private let snapshot: CGImage
    private let geometry: DisplayGeometry
    /// 控制器统一维护的全局逻辑选区。
    private var globalSelection: CGRect?

    init(snapshot: CGImage, geometry: DisplayGeometry) {
        self.snapshot = snapshot
        self.geometry = geometry
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("未支持 IB 初始化")
    }

    /// 由控制器统一更新选区（全局逻辑坐标）。
    func setSelection(_ globalRect: CGRect?) {
        globalSelection = globalRect
        needsDisplay = true
    }

    override var isFlipped: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 1. 冻结快照打底：视图逻辑尺寸 = 显示器逻辑尺寸，按 backing scale 像素 1:1 呈现。
        context.interpolationQuality = .high
        context.draw(snapshot, in: bounds)

        // 2. 选区外压暗。
        let selection = selectionInLocalCoords()
        NSColor.black.withAlphaComponent(Self.dimmingAlpha).setFill()
        for rect in RectMath.dimmingRects(inside: bounds, excluding: selection ?? .null) {
            rect.fill()
        }

        // 3. 选区边框 + 尺寸标签。
        if let selection, selection.width > 0, selection.height > 0 {
            let path = NSBezierPath(rect: selection)
            path.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            path.stroke()
            drawSizeLabel(for: selection)
        }
    }

    /// 全局逻辑选区 → 本视图局部坐标。内容视图铺满窗口，窗口坐标即视图坐标。
    private func selectionInLocalCoords() -> CGRect? {
        guard let globalSelection, let window else { return nil }
        return window.convertFromScreen(globalSelection)
    }

    /// 尺寸标签显示最终图片的像素尺寸，便于与导出结果核对。
    private func drawSizeLabel(for selection: CGRect) {
        let pixelWidth = Int((selection.width * geometry.scaleX).rounded())
        let pixelHeight = Int((selection.height * geometry.scaleY).rounded())
        let text = NSAttributedString(
            string: "\(pixelWidth) × \(pixelHeight)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white
            ]
        )
        let padding: CGFloat = 6
        let boxSize = CGSize(
            width: text.size().width + padding * 2,
            height: text.size().height + padding * 2
        )
        let boxX = min(max(selection.minX, bounds.minX + 2), bounds.maxX - boxSize.width - 2)
        var boxY = selection.maxY + 8
        if boxY + boxSize.height > bounds.maxY {
            boxY = selection.minY - boxSize.height - 8
        }
        let boxRect = CGRect(origin: CGPoint(x: boxX, y: boxY), size: boxSize)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: boxRect, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: boxRect.minX + padding, y: boxRect.minY + padding))
    }

    // MARK: - 事件

    override func mouseDown(with event: NSEvent) { onMouseDown?(globalPoint(for: event)) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(globalPoint(for: event)) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(globalPoint(for: event)) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// 统一走 convertToScreen（AppKit 左下原点约定）。
    /// 注意：不要用 NSEvent.mouseLocation，其全局坐标为左上原点，约定不同。
    private func globalPoint(for event: NSEvent) -> CGPoint {
        guard let window else { return .zero }
        let windowPoint = convert(event.locationInWindow, from: nil)
        // NSWindow.convertToScreen 仅接受矩形；点包装为 zero-size rect 取 origin。
        return window.convertToScreen(CGRect(origin: windowPoint, size: .zero)).origin
    }
}
