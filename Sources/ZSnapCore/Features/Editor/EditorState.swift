import AppKit
import Combine

/// 编辑器工具。
enum EditorTool: String, CaseIterable, Identifiable {
    case select
    case arrow
    case rectangle
    case ellipse
    case text
    case mosaic

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "t.square"
        case .mosaic: return "square.grid.3x3.fill"
        }
    }

    var displayName: String {
        switch self {
        case .select: return "选择/移动"
        case .arrow: return "箭头"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        }
    }
}

/// 编辑器共享状态：SwiftUI 工具栏与 AppKit 画布之间的唯一数据源。
/// 标注数据与原始图片严格分离（需求 4.4 / 9.3）。
@MainActor
final class EditorState: ObservableObject {
    /// 线宽档位（逻辑 pt，按图片像素密度换算）。
    static let lineWidthPresets: [CGFloat] = [2, 4, 6, 8]
    /// 字号档位（相对图片高度）。
    static let fontSizePresets: [CGFloat] = [0.020, 0.030, 0.042]

    let document: ScreenshotDocument
    let engine = AnnotationEngine()

    @Published var tool: EditorTool = .select
    @Published var color: RGBAColor = .red
    @Published var lineWidthIndex = 1
    @Published var fontSizeIndex = 1
    @Published var selectedAnnotationID: UUID?
    @Published var userZoom: CGFloat = 1
    @Published private(set) var fitScale: CGFloat = 1
    @Published var statusMessage: String?

    /// 马赛克像素化缓存（懒加载，与原图独立，不修改原图）。
    private var mosaicCache: CGImage?

    init(document: ScreenshotDocument) {
        self.document = document
    }

    // MARK: - 量纲

    /// 图片像素 / 逻辑点 比（线宽换算）。
    var pixelsPerPoint: CGFloat {
        document.logicalSize.width > 0 ? document.pixelSize.width / document.logicalSize.width : 2
    }

    var currentLineWidthPx: CGFloat {
        let preset = Self.lineWidthPresets[min(lineWidthIndex, Self.lineWidthPresets.count - 1)]
        return max(1, preset * pixelsPerPoint)
    }

    var currentFontSizePx: CGFloat {
        let preset = Self.fontSizePresets[min(fontSizeIndex, Self.fontSizePresets.count - 1)]
        return max(20, preset * document.pixelSize.height)
    }

    var selectedAnnotation: Annotation? {
        guard let id = selectedAnnotationID else { return nil }
        return engine.annotations.first { $0.id == id }
    }

    // MARK: - 画布布局

    func updateFitScale(_ scale: CGFloat) {
        guard abs(fitScale - scale) > 0.0001 else { return }
        fitScale = scale
    }

    func zoomToFit() {
        userZoom = 1
    }

    func zoomToActual() {
        userZoom = fitScale > 0 ? 1 / fitScale : 1
    }

    func applyZoomDelta(_ delta: CGFloat) {
        userZoom = min(4, max(0.2, userZoom * delta))
    }

    // MARK: - 标注操作

    func applyColorToSelected() {
        guard var selected = selectedAnnotation else { return }
        selected.color = color
        engine.update(selected)
    }

    func applyLineWidthToSelected() {
        guard var selected = selectedAnnotation, selected.type != .text, selected.type != .mosaic else { return }
        selected.lineWidth = currentLineWidthPx
        engine.update(selected)
    }

    func applyFontSizeToSelected() {
        guard var selected = selectedAnnotation, selected.type == .text else { return }
        selected.fontSize = currentFontSizePx
        engine.update(selected)
    }

    func deleteSelected() {
        guard let id = selectedAnnotationID else { return }
        engine.remove(id: id)
        selectedAnnotationID = nil
    }

    func undo() {
        engine.undo()
        selectedAnnotationID = nil
    }

    func redo() {
        engine.redo()
        selectedAnnotationID = nil
    }

    /// 马赛克像素化数据源（懒加载；无马赛克标注时不生成）。
    func mosaicImage() -> CGImage? {
        guard engine.annotations.contains(where: { $0.type == .mosaic }) else { return nil }
        if mosaicCache == nil {
            let pixelSize = document.pixelSize
            let blockSize = max(12, min(pixelSize.width, pixelSize.height) / 40)
            mosaicCache = MosaicMaker.pixelatedImage(from: document.image, blockSize: blockSize)
        }
        return mosaicCache
    }

    // MARK: - 输出

    /// 渲染最终图片（原图 + 全部标注），供贴图等下游使用。
    func renderFinalImage() -> CGImage? {
        ImageExportService.renderedImage(
            from: document,
            annotations: engine.annotations,
            mosaicImage: mosaicImage()
        )
    }

    /// 复制最终渲染图片到剪贴板（含全部标注，需求 5.1）。
    func copyFinalImage() {
        guard let image = ImageExportService.renderedImage(
            from: document,
            annotations: engine.annotations,
            mosaicImage: mosaicImage()
        ) else {
            flash("复制失败：无法生成图片")
            return
        }
        flash(ClipboardService.copyImage(image) ? "已复制到剪贴板" : "复制失败")
    }

    /// 保存 PNG（系统原生保存对话框，需求 5.2）。
    func savePNG(parentWindow: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ImageExportService.defaultFileName()
        let parent = parentWindow ?? NSApp.keyWindow
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return } // 用户取消不算失败
            guard let image = ImageExportService.renderedImage(
                from: self.document,
                annotations: self.engine.annotations,
                mosaicImage: self.mosaicImage()
            ), let data = ImageExportService.pngData(image) else {
                self.presentSaveError("无法生成图片数据。")
                return
            }
            do {
                try data.write(to: url)
                self.flash("已保存：\(url.lastPathComponent)")
            } catch {
                self.presentSaveError("写入文件失败：\(error.localizedDescription)")
            }
        }
        if let parent {
            panel.beginSheetModal(for: parent, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func presentSaveError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "保存失败"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - 状态反馈

    func flash(_ message: String) {
        statusMessage = message
    }

    func clearStatus() {
        statusMessage = nil
    }
}
