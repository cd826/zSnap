import CoreGraphics

/// 单个显示器的几何信息，是"屏幕逻辑坐标 ↔ 屏幕像素坐标 ↔ 图片像素坐标"换算的锚点（需求 9.4）。
struct DisplayGeometry: Equatable {
    let displayID: UInt32
    /// 全局逻辑坐标框（AppKit 约定：主屏左下角为原点，y 向上）。
    let logicalFrame: CGRect
    /// NSScreen.backingScaleFactor（Retina 为 2.0）。
    let scaleFactor: CGFloat
    /// 快照 CGImage 的实际像素尺寸。
    /// 可能与 logicalFrame 尺寸 × scaleFactor 存在细微偏差，坐标换算一律以该值为准。
    let pixelSize: CGSize

    /// 横向像素/逻辑比（用实际快照尺寸反推，避免截图输出尺寸差异导致错位）。
    var scaleX: CGFloat {
        logicalFrame.width > 0 ? pixelSize.width / logicalFrame.width : 1
    }

    /// 纵向像素/逻辑比。
    var scaleY: CGFloat {
        logicalFrame.height > 0 ? pixelSize.height / logicalFrame.height : 1
    }
}
