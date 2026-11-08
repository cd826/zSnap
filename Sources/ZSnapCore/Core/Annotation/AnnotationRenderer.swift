import AppKit
import CoreText

/// 标注渲染器：编辑器画布预览与复制/保存导出共用同一实现，保证所见即所得（需求 4.4）。
///
/// 坐标约定：`draw(_:in:imageSize:mosaicImage:)` 工作在"图片像素空间"
/// （1 单位 = 1 图片像素，原点在图片左上角，y 向下）。
/// 外部 CGContext 通过 `displayRect` 版本自动完成到显示空间的变换。
enum AnnotationRenderer {
    // MARK: - 入口

    /// 在任意 CGContext 的 displayRect 区域渲染标注（内部完成到图片空间的变换）。
    /// displayRect 为标注图片在上下文中的显示矩形（含缩放），坐标系为上下文本征方向。
    static func draw(
        _ annotations: [Annotation],
        in context: CGContext,
        imageSize: CGSize,
        mosaicImage: CGImage?,
        displayRect: CGRect
    ) {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: displayRect.minX, y: displayRect.maxY)
        let scaleX = displayRect.width / imageSize.width
        let scaleY = displayRect.height / imageSize.height
        context.scaleBy(x: scaleX, y: -scaleY)
        draw(annotations, in: context, imageSize: imageSize, mosaicImage: mosaicImage)
        context.restoreGState()
    }

    /// 在"图片像素空间"渲染全部标注（调用方须已把上下文变换到该空间：y 向下）。
    static func draw(
        _ annotations: [Annotation],
        in context: CGContext,
        imageSize: CGSize,
        mosaicImage: CGImage?
    ) {
        for annotation in annotations {
            switch annotation.type {
            case .arrow:
                drawArrow(annotation, in: context, imageSize: imageSize)
            case .rectangle:
                drawStrokedRect(annotation, in: context, imageSize: imageSize)
            case .ellipse:
                drawEllipse(annotation, in: context, imageSize: imageSize)
            case .text:
                drawText(annotation, in: context, imageSize: imageSize)
            case .mosaic:
                drawMosaic(annotation, in: context, imageSize: imageSize, mosaicImage: mosaicImage)
            }
        }
    }

    // MARK: - 各类型绘制（图片像素空间，y 向下）

    /// 两点标注的图片空间端点。保持原始点序：箭头 p0=尾、p1=头，方向不可被重排。
    private static func imagePoints(_ annotation: Annotation, _ imageSize: CGSize) -> (CGPoint, CGPoint)? {
        guard annotation.normalizedPoints.count >= 2 else { return nil }
        let a = annotation.normalizedPoints[0]
        let b = annotation.normalizedPoints[1]
        let p0 = CGPoint(x: a.x * imageSize.width, y: a.y * imageSize.height)
        let p1 = CGPoint(x: b.x * imageSize.width, y: b.y * imageSize.height)
        return (p0, p1)
    }

    private static func arrowHeadLength(lineWidth: CGFloat) -> CGFloat {
        // 头部大小与线宽协调（需求 4.2）。
        max(lineWidth * 3.2, lineWidth + 6)
    }

    private static func drawArrow(_ annotation: Annotation, in context: CGContext, imageSize: CGSize) {
        guard let (p0, p1) = imagePoints(annotation, imageSize) else { return }
        let width = max(annotation.lineWidth, 1)
        let headLength = arrowHeadLength(lineWidth: width)
        let color = cgColor(annotation.color)
        let angle = atan2(p1.y - p0.y, p1.x - p0.x)

        // 箭杆（止于头部根部）。
        let shaftEnd = CGPoint(
            x: p1.x - cos(angle) * headLength * 0.72,
            y: p1.y - sin(angle) * headLength * 0.72
        )
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.move(to: p0)
        context.addLine(to: shaftEnd)
        context.strokePath()

        // 实心三角头。
        let halfAngle: CGFloat = .pi / 9
        let wing1 = CGPoint(
            x: p1.x - headLength * cos(angle - halfAngle),
            y: p1.y - headLength * sin(angle - halfAngle)
        )
        let wing2 = CGPoint(
            x: p1.x - headLength * cos(angle + halfAngle),
            y: p1.y - headLength * sin(angle + halfAngle)
        )
        context.move(to: p1)
        context.addLine(to: wing1)
        context.addLine(to: wing2)
        context.closePath()
        context.fillPath()
    }

    private static func drawStrokedRect(_ annotation: Annotation, in context: CGContext, imageSize: CGSize) {
        guard let rect = imageRect(annotation, imageSize) else { return }
        let path = CGPath(rect: rect, transform: nil)
        context.addPath(path)
        context.setStrokeColor(cgColor(annotation.color))
        context.setLineWidth(max(annotation.lineWidth, 1))
        context.setLineCap(.round)
        context.strokePath()
    }

    private static func drawEllipse(_ annotation: Annotation, in context: CGContext, imageSize: CGSize) {
        guard let rect = imageRect(annotation, imageSize) else { return }
        let path = CGPath(ellipseIn: rect, transform: nil)
        context.addPath(path)
        context.setStrokeColor(cgColor(annotation.color))
        context.setLineWidth(max(annotation.lineWidth, 1))
        context.setLineCap(.round)
        context.strokePath()
    }

    /// 两点标注对应的图片空间矩形（y 向下空间内的 min/min/max/max 已由 normalizedRect 保证）。
    private static func imageRect(_ annotation: Annotation, _ imageSize: CGSize) -> CGRect? {
        guard let normalized = annotation.normalizedRect() else { return nil }
        return CGRect(
            x: normalized.minX * imageSize.width,
            y: normalized.minY * imageSize.height,
            width: normalized.width * imageSize.width,
            height: normalized.height * imageSize.height
        )
    }

    private static func drawMosaic(
        _ annotation: Annotation,
        in context: CGContext,
        imageSize: CGSize,
        mosaicImage: CGImage?
    ) {
        guard let rect = imageRect(annotation, imageSize), let mosaicImage else { return }
        context.saveGState()
        context.clip(to: rect)
        // 回到 y 向上绘制图片（CG 图片绘制按本征方向放置，翻转空间内需局部再翻转）。
        context.translateBy(x: 0, y: imageSize.height)
        context.scaleBy(x: 1, y: -1)
        let previousInterpolation = context.interpolationQuality
        context.interpolationQuality = .none // 像素块状放大（需求 4.2：真实像素化，非半透明色块）
        context.draw(mosaicImage, in: CGRect(origin: .zero, size: imageSize))
        context.interpolationQuality = previousInterpolation
        context.restoreGState()
    }

    private static func drawText(_ annotation: Annotation, in context: CGContext, imageSize: CGSize) {
        guard let text = annotation.text, !text.isEmpty,
              let origin = annotation.normalizedPoints.first else { return }
        let fontSize = annotation.fontSize ?? max(20, imageSize.height * 0.03)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: cgColor(annotation.color)) ?? .black
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)

        let px = origin.x * imageSize.width
        let py = origin.y * imageSize.height
        // 图片空间 y 向下；CoreText 按 y 向上绘制 → 局部翻转，使文字顶边对齐插入点。
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: px, y: py + ascent)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: - 命中测试与包围盒（图片像素空间，y 向下）

    /// 标注的包围盒（含线宽/头部外扩），用于选中框与命中测试。
    static func annotationBounds(_ annotation: Annotation, imageSize: CGSize) -> CGRect? {
        switch annotation.type {
        case .arrow:
            guard let (p0, p1) = imagePoints(annotation, imageSize) else { return nil }
            let margin = arrowHeadLength(lineWidth: max(annotation.lineWidth, 1)) + annotation.lineWidth
            return CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                          width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
                .insetBy(dx: -margin, dy: -margin)
        case .rectangle, .ellipse, .mosaic:
            guard let rect = imageRect(annotation, imageSize) else { return nil }
            return rect.insetBy(dx: -annotation.lineWidth, dy: -annotation.lineWidth)
        case .text:
            return textBounds(annotation, imageSize)
        }
    }

    /// 文字包围盒（顶边 = 插入点）。
    static func textBounds(_ annotation: Annotation, _ imageSize: CGSize) -> CGRect? {
        guard let text = annotation.text, !text.isEmpty,
              let origin = annotation.normalizedPoints.first else { return nil }
        let fontSize = annotation.fontSize ?? max(20, imageSize.height * 0.03)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let size = (text as NSString).size(
            withAttributes: [.font: font]
        )
        return CGRect(
            x: origin.x * imageSize.width,
            y: origin.y * imageSize.height,
            width: size.width,
            height: size.height
        )
    }

    /// 命中测试（图片像素空间）。tolerance 为额外容差（图片像素）。
    static func isHit(_ annotation: Annotation, at point: CGPoint, imageSize: CGSize, tolerance: CGFloat = 6) -> Bool {
        switch annotation.type {
        case .arrow:
            guard let (p0, p1) = imagePoints(annotation, imageSize) else { return false }
            let threshold = max(annotation.lineWidth * 1.5, 6) + tolerance
            return RectMath.distance(from: point, toSegment: p0, p1) <= threshold
        case .rectangle, .mosaic:
            guard let rect = imageRect(annotation, imageSize) else { return false }
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .ellipse:
            guard let rect = imageRect(annotation, imageSize) else { return false }
            guard rect.width > 0, rect.height > 0 else { return false }
            // 椭圆方程判定，允许轻微外扩。
            let dx = (point.x - rect.midX) / (rect.width / 2)
            let dy = (point.y - rect.midY) / (rect.height / 2)
            return dx * dx + dy * dy <= 1.08
        case .text:
            return textBounds(annotation, imageSize)?.insetBy(dx: -tolerance, dy: -tolerance).contains(point) ?? false
        }
    }

    // MARK: - 工具

    static func cgColor(_ color: RGBAColor) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

/// 马赛克数据源：把原图按块缩小（渲染时以 .none 插值放大成块状）。
enum MosaicMaker {
    static func pixelatedImage(from image: CGImage, blockSize: CGFloat) -> CGImage? {
        guard blockSize >= 1 else { return nil }
        let smallWidth = max(1, Int((CGFloat(image.width) / blockSize).rounded()))
        let smallHeight = max(1, Int((CGFloat(image.height) / blockSize).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: smallWidth,
                  height: smallHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        return context.makeImage()
    }
}
