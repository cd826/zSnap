import AppKit
import CoreGraphics

/// CG 全局坐标（主屏左上原点，y 向下）与 AppKit 全局坐标（主屏左下原点，y 向上）之间的转换。
/// CGWindowList 的 kCGWindowBounds 与 ScreenCaptureKit 的 SCWindow.frame 均为 CG 坐标；
/// 覆盖层绘制与命中测试使用 AppKit 坐标。禁止混用两套坐标系。
enum WindowFrameConverter {
    /// 主屏逻辑高度（AppKit 全局坐标系的总高；主屏 frame 恒为 (0, 0, w, h)）。
    static func primaryDisplayHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func appKitFrame(fromCGRect cgRect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: cgRect.origin.x,
            y: primaryDisplayHeight - cgRect.maxY,
            width: cgRect.width,
            height: cgRect.height
        )
    }

    static func appKitPoint(fromCGPoint cgPoint: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: cgPoint.x, y: primaryDisplayHeight - cgPoint.y)
    }

    static func cgPoint(fromAppKitPoint appKitPoint: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: appKitPoint.x, y: primaryDisplayHeight - appKitPoint.y)
    }
}
