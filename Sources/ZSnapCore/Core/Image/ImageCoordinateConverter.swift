import CoreGraphics

/// 统一的坐标转换模块（需求 9.4）。
///
/// 输入：全局逻辑坐标（AppKit，左下原点，y 向上）。
/// 输出：快照图片像素坐标（CGImage 约定，左上原点，y 向下）。
///
/// 禁止把屏幕坐标直接当作图片坐标使用；所有换算必须经过本模块，
/// 且基于 DisplayGeometry 的实际像素尺寸（而非名义 scaleFactor）。
enum ImageCoordinateConverter {
    /// 把全局逻辑矩形转换为快照内的像素矩形。
    /// 会先与显示器逻辑框求交（跨屏/越界选区被限制在该显示器内），再取整到像素边界。
    static func pixelRect(fromGlobalRect globalRect: CGRect, in geometry: DisplayGeometry) -> CGRect {
        let local = globalRect.intersection(geometry.logicalFrame)
        guard !local.isNull else { return .zero }

        let left = (local.minX - geometry.logicalFrame.minX) * geometry.scaleX
        let right = (local.maxX - geometry.logicalFrame.minX) * geometry.scaleX
        // y 轴翻转：逻辑坐标自下而上，像素坐标自上而下。
        let top = (geometry.logicalFrame.maxY - local.maxY) * geometry.scaleY
        let bottom = (geometry.logicalFrame.maxY - local.minY) * geometry.scaleY

        let x0 = left.rounded(.toNearestOrAwayFromZero)
        let x1 = right.rounded(.toNearestOrAwayFromZero)
        let y0 = top.rounded(.toNearestOrAwayFromZero)
        let y1 = bottom.rounded(.toNearestOrAwayFromZero)

        var pixelRect = CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
        // 防御：结果必须落在快照像素范围内。
        pixelRect = pixelRect.intersection(CGRect(origin: .zero, size: geometry.pixelSize))
        return pixelRect.isNull ? .zero : pixelRect
    }

    /// 把全局逻辑点转换为快照内的像素点（左上原点）。
    static func pixelPoint(fromGlobalPoint globalPoint: CGPoint, in geometry: DisplayGeometry) -> CGPoint {
        let x = (globalPoint.x - geometry.logicalFrame.minX) * geometry.scaleX
        let y = (geometry.logicalFrame.maxY - globalPoint.y) * geometry.scaleY
        return CGPoint(x: x, y: y)
    }
}
