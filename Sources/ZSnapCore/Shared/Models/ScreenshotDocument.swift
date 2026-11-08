import CoreGraphics
import Foundation

/// 截图文档：原始图片 + 独立标注数据（需求 9.3）。
/// 原始图片只读；最终图片由 原图 + 标注 + 图像处理效果 统一渲染生成（需求 4.4）。
/// 编辑器不依赖固定屏幕尺寸，为长截图预留（需求 7.2）。
struct ScreenshotDocument {
    /// 原始截图（渲染时绝不修改）。
    let image: CGImage
    /// 截图区域对应的逻辑尺寸（pt），用于线宽/字号等 UI 量纲换算。
    let logicalSize: CGSize

    var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }
}
