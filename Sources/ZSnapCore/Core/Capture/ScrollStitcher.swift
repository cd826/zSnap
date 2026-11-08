import CoreGraphics
import Foundation

/// 长截图拼接核心（纯逻辑，可单元测试）。
///
/// 原理：用户手动滚动页面，按固定间隔抓帧；对相邻两帧做垂直模板匹配
/// （取上一帧中部横带，在新帧中寻找差异最小的位置），得到滚动位移，
/// 再把新帧中"尚未覆盖"的行增量拼接到结果画布上。
///
/// 已知边界（记录于 Phase 4 报告）：
/// - 纯平移假设：吸顶/悬浮元素会造成重复带；
/// - 滚动过快出现内容缺口时，该帧被跳过并提示用户回滚补拍；
/// - 动态加载/渐变空白区可能匹配失败（阈值保护）。
enum ScrollStitcher {
    /// 8-bit 灰度图（内存行 0 = 图片顶部，y 向下）。
    struct GrayImage {
        var width: Int
        var height: Int
        var pixels: [UInt8]
    }

    /// 把 CGImage 降采样为灰度图（匹配用，降低计算量）。
    static func grayscale(from image: CGImage, downscale: Int = 4) -> GrayImage? {
        let width = max(1, image.width / downscale)
        let height = max(1, image.height / downscale)
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let graySpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) else { return nil }
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: graySpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    /// 估算相邻帧的垂直滚动位移。
    /// - Returns: 正值 = 内容上移（用户向下滚动）；负值 = 上滚；nil = 匹配不可信。
    static func estimateScrollOffset(previous: GrayImage, current: GrayImage, templateRows: Int = 24) -> Int? {
        guard previous.width == current.width,
              previous.height >= templateRows * 2,
              current.height >= templateRows else { return nil }

        let width = previous.width
        let y0 = previous.height / 2

        var bestRow = -1
        var bestDiff = Int.max
        for candidateRow in 0...(current.height - templateRows) {
            var diff = 0
            for i in 0..<templateRows {
                let previousRow = (y0 + i) * width
                let currentRow = (candidateRow + i) * width
                for x in 0..<width {
                    diff += abs(Int(current.pixels[currentRow + x]) - Int(previous.pixels[previousRow + x]))
                }
            }
            if diff < bestDiff {
                bestDiff = diff
                bestRow = candidateRow
            }
        }
        guard bestRow >= 0 else { return nil }

        // 归一化差异过大说明画面突变/无重叠，该帧不可信。
        let perPixel = Double(bestDiff) / Double(templateRows * width)
        guard perPixel < 24 else { return nil }
        return y0 - bestRow
    }
}
