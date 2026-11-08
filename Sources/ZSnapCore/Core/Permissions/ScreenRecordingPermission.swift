import CoreGraphics

/// 屏幕录制权限检测（需求 3.2 截图权限）。
enum ScreenRecordingPermission {
    /// 预检当前是否已授权。未授权时调用方必须展示引导，不得假装截图成功。
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 触发系统授权弹窗（每个应用仅首次有效，之后系统只返回 false 不再弹窗）。
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
