import AppKit

/// 截图结果预览窗口（Phase 0 验证用：核对裁剪内容、像素尺寸、无错位）。
/// Phase 2 将被统一编辑器取代。
@MainActor
final class SnapshotPreviewController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onClose: () -> Void

    /// - Parameters:
    ///   - image: 已裁剪的截图（像素）。
    ///   - title: 窗口标题（含像素尺寸信息）。
    ///   - preferredSize: 图片对应的逻辑尺寸（决定初始窗口大小）。
    init(image: CGImage, title: String, preferredSize: CGSize, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()

        let fitSize = Self.fittedSize(for: preferredSize)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: fitSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        let imageView = PreviewImageView(frame: NSRect(origin: .zero, size: fitSize))
        imageView.image = NSImage(cgImage: image, size: preferredSize)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        window.contentView = imageView
        self.window = window
    }

    func show() {
        guard let window else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// 关闭预览（经 performClose 触发 windowWillClose → onClose）。
    func close() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard window != nil else { return }
        window = nil
        onClose()
    }

    private static func fittedSize(for imageSize: CGSize) -> CGSize {
        guard let screen = NSScreen.main, imageSize.width > 0, imageSize.height > 0 else {
            return imageSize
        }
        let maxWidth = screen.visibleFrame.width * 0.7
        let maxHeight = screen.visibleFrame.height * 0.7
        let scale = min(1, maxWidth / imageSize.width, maxHeight / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// 支持 Esc 关闭。
    private final class PreviewImageView: NSImageView {
        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // kVK_Escape
                window?.performClose(nil)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
