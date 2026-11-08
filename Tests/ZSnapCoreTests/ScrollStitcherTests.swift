import XCTest

@testable import ZSnapCore

/// 长截图拼接算法测试：合成图 + 已知位移的锚定式分析。
final class ScrollStitcherTests: XCTestCase {
    private let width = 200
    private let height = 400

    /// 生成带噪声的合成灰度图（保证匹配唯一性）。
    private func syntheticGray(seed: UInt64) -> ScrollStitcher.GrayImage {
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
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let sourceRow = row + shift
            for x in 0..<width {
                if sourceRow < height {
                    pixels[row * width + x] = source.pixels[sourceRow * width + x]
                } else {
                    pixels[row * width + x] = UInt8((sourceRow * 7 + x) % 256)
                }
            }
        }
        return ScrollStitcher.GrayImage(width: width, height: height, pixels: pixels)
    }

    /// 模拟向上滚动 shift 行：新帧 = 旧帧内容整体下移 shift 行，顶部补新内容。
    private func scrolledUp(from source: ScrollStitcher.GrayImage, by shift: Int) -> ScrollStitcher.GrayImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let sourceRow = row - shift
            for x in 0..<width {
                if sourceRow >= 0 {
                    pixels[row * width + x] = source.pixels[sourceRow * width + x]
                } else {
                    let value = ((sourceRow * 13 + x) % 256 + 256) % 256
                    pixels[row * width + x] = UInt8(value)
                }
            }
        }
        return ScrollStitcher.GrayImage(width: width, height: height, pixels: pixels)
    }

    func testScrollDownDetectsNewContent() {
        let previous = syntheticGray(seed: 1)
        let shift = 37
        let current = scrolledDown(from: previous, by: shift)
        let result = ScrollStitcher.analyzeScroll(previous: previous, current: current)
        XCTAssertEqual(result, .append(fromRow: height - shift), "新内容应从 帧高-位移 行开始")
    }

    func testScrollDownLargeShift() {
        let previous = syntheticGray(seed: 2)
        let shift = 160
        let current = scrolledDown(from: previous, by: shift)
        let result = ScrollStitcher.analyzeScroll(previous: previous, current: current)
        XCTAssertEqual(result, .append(fromRow: height - shift))
    }

    func testNoMovementAppendsNothing() {
        let frame = syntheticGray(seed: 3)
        let result = ScrollStitcher.analyzeScroll(previous: frame, current: frame)
        XCTAssertEqual(result, .noNewContent, "静止帧必须零追加（旧版重合问题根因）")
    }

    func testScrollUpAppendsNothing() {
        let previous = syntheticGray(seed: 4)
        let current = scrolledUp(from: previous, by: 50)
        let result = ScrollStitcher.analyzeScroll(previous: previous, current: current)
        XCTAssertEqual(result, .noNewContent, "上滚时已拼内容不受影响")
    }

    func testUnrelatedFramesAreUnreliable() {
        let previous = ScrollStitcher.GrayImage(
            width: width, height: height,
            pixels: [UInt8](repeating: 40, count: width * height)
        )
        let current = ScrollStitcher.GrayImage(
            width: width, height: height,
            pixels: [UInt8](repeating: 220, count: width * height)
        )
        let result = ScrollStitcher.analyzeScroll(previous: previous, current: current)
        XCTAssertEqual(result, .unreliable, "完全不相关画面应判定为缺口/不可信")
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
