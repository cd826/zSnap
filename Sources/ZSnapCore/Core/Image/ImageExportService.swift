import AppKit

/// 图片导出服务：原始截图 + 标注统一渲染（需求 4.4 / 5.2）。
enum ImageExportService {
    /// 渲染最终图片。原始图片保持不变，结果为新位图。
    static func renderedImage(
        from document: ScreenshotDocument,
        annotations: [Annotation],
        mosaicImage: CGImage?
    ) -> CGImage? {
        let size = document.pixelSize
        guard size.width > 0, size.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: Int(size.width),
                  height: Int(size.height),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        // 1. 原始图（位图上下文本征方向，直接绘制即正立）。
        context.interpolationQuality = .high
        context.draw(document.image, in: CGRect(origin: .zero, size: size))

        // 2. 标注（进入图片像素空间）。
        AnnotationRenderer.draw(
            annotations,
            in: context,
            imageSize: size,
            mosaicImage: mosaicImage,
            displayRect: CGRect(origin: .zero, size: size)
        )
        return context.makeImage()
    }

    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// 默认文件名：含时间信息（需求 5.2）。
    static func defaultFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "zSnap \(formatter.string(from: date)).png"
    }
}
