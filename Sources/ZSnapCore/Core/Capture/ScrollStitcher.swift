import CoreGraphics
import Foundation

/// 长截图拼接核心（纯逻辑，可单元测试）。
///
/// 锚定式拼接：取上一帧底部横带（= 已拼接内容的最后一行）在新帧中垂直定位，
/// 该位置以下的行即为新内容。每帧直接锚定已拼内容，误差不逐帧累积；
/// 静止帧天然判定为"无新内容"（零追加），上滚由顶部横带回溯判定。
///
/// 已知边界（记录于 Phase 4 报告）：
/// - 纯平移假设：吸顶/悬浮元素会造成重复带；
/// - 大面积空白区的定位存在歧义（视觉上通常无缝，但内容重现时可能错位）；
/// - 底带完全滚出画面 = 缺口（.unreliable），需回滚补拍。
enum ScrollStitcher {
    /// 8-bit 灰度图（内存行 0 = 图片顶部，y 向下）。
    struct GrayImage {
        var width: Int
        var height: Int
        var pixels: [UInt8]
    }

    /// 单帧分析结果。
    enum AppendResult: Equatable {
        /// 从该行到帧底都是新内容（行号基于当前帧，y 向下）。
        case append(fromRow: Int)
        /// 静止或上滚，无新内容。
        case noNewContent
        /// 定位不可信（底带滚出画面 / 画面突变）→ 缺口，建议回滚。
        case unreliable
    }

    /// 把 CGImage 降采样为灰度图（匹配用，降低计算量）。
    static func grayscale(from image: CGImage, downscale: Int = 2) -> GrayImage? {
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

    /// 分析当前帧相对上一帧的新内容位置。
    ///
    /// 多横带一致性校验：在上一帧 45%/60%/75% 高度取三条横带分别在新帧中定位，
    /// 三者推得的滚动位移必须一致才采纳。平滑纹理区域（纯色/木纹/渐变）的单带
    /// 匹配存在歧义，但多条横带各自乱配出的位移几乎不可能互相一致——以此把
    /// "误配"转化为"跳帧"（宁缺勿重），配合控制器冻结锚点支持回滚补拍。
    ///
    /// - Parameter downscale: 灰度图降采样系数，用于把结果换算回全分辨率行号。
    /// - Returns: `append(fromRow:)` 行号基于**全分辨率**帧（y 向下）。
    static func analyzeScroll(previous: GrayImage, current: GrayImage, downscale: Int = 1, bandRows: Int = 24) -> AppendResult {
        guard previous.width == current.width,
              previous.height >= bandRows * 2,
              current.height >= bandRows,
              downscale >= 1 else { return .unreliable }

        let grayHeight = current.height
        let fullHeight = grayHeight * downscale

        // 主路径：多横带一致性校验。
        var offsets: [Int] = []
        for fraction in [0.45, 0.60, 0.75] {
            let y = Int(Double(previous.height) * fraction)
            guard y + bandRows <= previous.height,
                  let band = band(of: previous, range: y..<(y + bandRows)),
                  let matchedRow = locateBand(band, in: current) else { continue }
            offsets.append(y - matchedRow)
        }
        if offsets.count >= 2, let scrollOffset = consistentValue(offsets, tolerance: 2) {
            let appendStart = min(fullHeight, (grayHeight - scrollOffset) * downscale)
            if appendStart < fullHeight {
                return .append(fromRow: appendStart)
            }
            return .noNewContent
        }

        // 备用路径：当前帧底部横带在上一帧中的位置。
        // 上滚/静止时必然能找到（内容仍在上一帧内）；找不到才是真缺口。
        if let currentBottom = band(of: current, range: (grayHeight - bandRows)..<grayHeight),
           let _ = locateBand(currentBottom, in: previous) {
            return .noNewContent
        }

        return .unreliable
    }

    /// 所有值彼此差 ≤ tolerance 时返回中位值，否则 nil。
    private static func consistentValue(_ values: [Int], tolerance: Int) -> Int? {
        guard let first = values.first else { return nil }
        for value in values where abs(value - first) > tolerance {
            return nil
        }
        return values.sorted()[values.count / 2]
    }

    // MARK: - 内部

    /// 水平横带裁剪。
    static func band(of image: GrayImage, range: Range<Int>) -> GrayImage? {
        guard range.lowerBound >= 0, range.upperBound <= image.height, !range.isEmpty else { return nil }
        let start = range.lowerBound * image.width
        let count = range.count * image.width
        return GrayImage(width: image.width, height: range.count, pixels: Array(image.pixels[start..<(start + count)]))
    }

    /// 在 image 中垂直搜索与 template 逐像素差异最小的行，返回行号；差异过大返回 nil。
    static func locateBand(_ template: GrayImage, in image: GrayImage) -> Int? {
        guard template.width == image.width,
              image.height >= template.height,
              !template.pixels.isEmpty else { return nil }

        let width = template.width
        var bestRow = -1
        var bestDiff = Int.max
        for candidateRow in 0...(image.height - template.height) {
            var diff = 0
            for i in 0..<template.height {
                let templateRow = i * width
                let imageRow = (candidateRow + i) * width
                for x in 0..<width {
                    diff += abs(Int(image.pixels[imageRow + x]) - Int(template.pixels[templateRow + x]))
                }
            }
            if diff < bestDiff {
                bestDiff = diff
                bestRow = candidateRow
            }
        }
        guard bestRow >= 0 else { return nil }

        // 归一化差异过大说明画面突变/无重叠，定位不可信。
        // 真匹配（同内容重采样）差异 ≤8；无关内容噪声底 ≥20。
        let perPixel = Double(bestDiff) / Double(template.height * width)
        guard perPixel < 16 else { return nil }
        return bestRow
    }
}
