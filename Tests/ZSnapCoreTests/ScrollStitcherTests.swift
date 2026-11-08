import XCTest

@testable import ZSnapCore

/// 长截图拼接算法测试：合成图 + 已知位移的滚动匹配。
final class ScrollStitcherTests: XCTestCase {
    /// 生成带噪声的合成灰度图（保证匹配唯一性）。
    private func syntheticGray(width: Int, height: Int, seed: UInt64) -> ScrollStitcher.GrayImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var state = seed
        for index in 0..<pixels.count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            // 叠加行梯度，模拟真实页面内容（纯噪声在同列上易产生歧义）。
            let rowGradient = UInt8((index / width) % 256)
            let noise = UInt8(truncatingIfNeeded: state >> 32) & 0x3F
            pixels[index] = rowGradient &+ noise &- 0x20
        }
        return ScrollStitcher.GrayImage(width: width, height: height, pixels: pixels)
    }

    /// 模拟向下滚动 shift 行：新帧 = 旧帧内容整体上移 shift 行，底部补新内容。
    private func scrolledDown(from source: ScrollStitcher.GrayImage, by shift: Int) -> ScrollStitcher.GrayImage {
        var pixels = [UInt8](repeating: 0, count: source.width * source.height)
        for row in 0..<source.height {
            let sourceRow = row + shift
            for x in 0..<source.width {
                if sourceRow < source.height {
                    pixels[row * source.width + x] = source.pixels[sourceRow * source.width + x]
                } else {
                    pixels[row * source.width + x] = UInt8((sourceRow * 7 + x) % 256)
                }
            }
        }
        return ScrollStitcher.GrayImage(width: source.width, height: source.height, pixels: pixels)
    }

    func testEstimateScrollOffsetDownward() {
        let previous = syntheticGray(width: 200, height: 400, seed: 1)
        let shift = 37
        let current = scrolledDown(from: previous, by: shift)
        let offset = ScrollStitcher.estimateScrollOffset(previous: previous, current: current)
        XCTAssertEqual(offset, shift)
    }

    func testEstimateScrollOffsetLargeShift() {
        let previous = syntheticGray(width: 200, height: 400, seed: 2)
        let shift = 160
        let current = scrolledDown(from: previous, by: shift)
        let offset = ScrollStitcher.estimateScrollOffset(previous: previous, current: current)
        XCTAssertEqual(offset, shift)
    }

    func testEstimateScrollOffsetNoMovement() {
        let frame = syntheticGray(width: 200, height: 400, seed: 3)
        let offset = ScrollStitcher.estimateScrollOffset(previous: frame, current: frame)
        XCTAssertEqual(offset, 0)
    }

    func testEstimateScrollOffsetRejectsUnrelatedFrames() {
        // 亮/暗强对比画面：任何对齐位置差异都远超阈值。
        let previous = ScrollStitcher.GrayImage(
            width: 200, height: 400,
            pixels: [UInt8](repeating: 40, count: 200 * 400)
        )
        let current = ScrollStitcher.GrayImage(
            width: 200, height: 400,
            pixels: [UInt8](repeating: 220, count: 200 * 400)
        )
        let offset = ScrollStitcher.estimateScrollOffset(previous: previous, current: current)
        XCTAssertNil(offset, "完全不相关画面应判定为不可信")
    }

    func testGrayscaleDownscaleDimensions() throws {
        let image = try XCTUnwrap(syntheticCGImage(width: 400, height: 200))
        let gray = try XCTUnwrap(ScrollStitcher.grayscale(from: image, downscale: 4))
        XCTAssertEqual(gray.width, 100)
        XCTAssertEqual(gray.height, 50)
    }

    private func syntheticCGImage(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
