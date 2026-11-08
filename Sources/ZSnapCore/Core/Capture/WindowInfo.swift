import CoreGraphics
import Foundation

/// 可捕获的常规窗口信息（来自 CGWindowList 快照）。
struct WindowInfo: Equatable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    /// 窗口标题（需要屏幕录制权限，无权限或无标题时为 nil）。
    let title: String?
    /// CG 全局坐标（主屏左上原点，y 向下；不含阴影）。与 ScreenCaptureKit 的 SCWindow.frame 同坐标系。
    let cgBounds: CGRect
    /// AppKit 全局坐标（主屏左下原点，y 向上）。用于覆盖层绘制与命中测试。
    let appKitFrame: CGRect

    /// 高亮标签显示名。
    var displayName: String {
        if let title, !title.isEmpty { return title }
        return "窗口"
    }
}
