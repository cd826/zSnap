import AppKit

/// 剪贴板服务：复制渲染后的最终图片（需求 5.1）。
enum ClipboardService {
    /// 复制图片（PNG 数据 + NSImage 双类型，兼容不同接收方）。
    @discardableResult
    static func copyImage(_ image: CGImage) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard let png = ImageExportService.pngData(image) else { return false }
        guard pasteboard.setData(png, forType: .png) else { return false }
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        pasteboard.writeObjects([nsImage])
        return true
    }
}
