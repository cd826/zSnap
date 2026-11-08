import XCTest

@testable import ZSnapCore

/// 导出渲染测试：验证"原图 + 标注"统一渲染的正确性（像素级校验）。
final class ImageExportServiceTests: XCTestCase {
    /// 生成纯色测试图。
    private func solidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 读取渲染结果中某个图片像素的颜色（x, y 为图片空间，y 向下）。
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        let buffer = data.assumingMemoryBound(to: UInt8.self)
        // CGBitmapContext 内存首行对应上下文 y 最大（图片顶部）。
        let row = image.height - 1 - y
        let offset = row * context.bytesPerRow + x * 4
        return (buffer[offset], buffer[offset + 1], buffer[offset + 2])
    }

    func testRenderedAnnotationIncluded() throws {
        // 白底 20×10，红色矩形 (0.2,0.2)-(0.8,0.8)，线宽 2px。
        let white = try XCTUnwrap(solidImage(width: 20, height: 10, red: 255, green: 255, blue: 255))
        let document = ScreenshotDocument(image: white, logicalSize: CGSize(width: 20, height: 10))
        let annotation = Annotation(
            type: .rectangle,
            color: .red,
            lineWidth: 2,
            normalizedPoints: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)],
            text: nil,
            fontSize: nil
        )

        let rendered = try XCTUnwrap(
            ImageExportService.renderedImage(from: document, annotations: [annotation], mosaicImage: nil)
        )
        XCTAssertEqual(rendered.width, 20)
        XCTAssertEqual(rendered.height, 10)

        // 中心点在矩形内部（空心边框不覆盖）→ 应仍为白色。
        let center = try XCTUnwrap(pixel(rendered, x: 10, y: 5))
        XCTAssertEqual(center.r, 255)
        XCTAssertEqual(center.g, 255)

        // 边框中点 → 应为红色（annotated）。
        let edge = try XCTUnwrap(pixel(rendered, x: 4, y: 2))
        XCTAssertGreaterThan(edge.r, 200, "边框像素应为红色")
        XCTAssertLessThan(edge.g, 100, "边框像素绿色分量应显著低于红色")
    }

    func testRenderedWithoutAnnotationsMatchesOriginalSize() throws {
        let original = try XCTUnwrap(solidImage(width: 40, height: 30, red: 10, green: 20, blue: 30))
        let document = ScreenshotDocument(image: original, logicalSize: CGSize(width: 40, height: 30))
        let rendered = try XCTUnwrap(
            ImageExportService.renderedImage(from: document, annotations: [], mosaicImage: nil)
        )
        XCTAssertEqual(rendered.width, 40)
        XCTAssertEqual(rendered.height, 30)
    }

    func testDefaultFileNameHasTimestamp() {
        let date = Date(timeIntervalSince1970: 1_799_000_000)
        let name = ImageExportService.defaultFileName(date: date)
        XCTAssertTrue(name.hasPrefix("zSnap "))
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertFalse(name.contains("/"))
    }

    func testSegmentDistance() {
        // 线段中点正上方距离（线段 y=3，点在 y=6 → 距离 3）。
        XCTAssertEqual(RectMath.distance(from: CGPoint(x: 5, y: 6), toSegment: CGPoint(x: 0, y: 3), CGPoint(x: 10, y: 3)), 3, accuracy: 0.0001)
        // 端点外投影应收敛到端点。
        XCTAssertEqual(RectMath.distance(from: CGPoint(x: -4, y: 0), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)), 4, accuracy: 0.0001)
        // 零长度线段退化为点距。
        XCTAssertEqual(RectMath.distance(from: CGPoint(x: 3, y: 4), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0)), 5, accuracy: 0.0001)
    }
}
