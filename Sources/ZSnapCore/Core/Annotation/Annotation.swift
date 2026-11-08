import CoreGraphics
import Foundation

/// 标注类型。
enum AnnotationType: String, Equatable, CaseIterable {
    case arrow
    case rectangle
    case ellipse
    case text
    case mosaic
}

/// 颜色值（纯数据，渲染与未来序列化共用）。
struct RGBAColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    // 需求 8.2：默认标注色板。
    static let red = RGBAColor(red: 0.96, green: 0.24, blue: 0.21)
    static let orange = RGBAColor(red: 1.0, green: 0.58, blue: 0.0)
    static let yellow = RGBAColor(red: 1.0, green: 0.82, blue: 0.0)
    static let green = RGBAColor(red: 0.20, green: 0.78, blue: 0.35)
    static let blue = RGBAColor(red: 0.05, green: 0.47, blue: 0.95)
    static let white = RGBAColor(red: 1.0, green: 1.0, blue: 1.0)
    static let black = RGBAColor(red: 0.12, green: 0.12, blue: 0.14)

    static let palette: [RGBAColor] = [.red, .orange, .yellow, .green, .blue, .white, .black]
}

/// 单条标注（需求 9.3）。
/// 坐标为相对图片的归一化坐标（0~1，y 向下，与图片像素方向一致），
/// 不随显示缩放/长图尺寸变化（需求 7.2 / 9.4）。
struct Annotation: Equatable, Identifiable {
    var id = UUID()
    var type: AnnotationType
    var color: RGBAColor
    /// 线宽（图片像素单位）。
    var lineWidth: CGFloat
    /// 归一化点集：箭头/矩形/椭圆/马赛克为 [起点, 终点]；文字为 [插入点]。
    var normalizedPoints: [CGPoint]
    /// 文字内容（仅 text）。
    var text: String?
    /// 字号（图片像素单位，仅 text）。
    var fontSize: CGFloat?

    /// 两点标注的归一化矩形（支持反方向拖动）。
    func normalizedRect() -> CGRect? {
        guard normalizedPoints.count >= 2 else { return nil }
        return RectMath.normalizedRect(from: normalizedPoints[0], to: normalizedPoints[1])
    }
}
