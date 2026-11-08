import AppKit
import CoreGraphics

/// 基于 CGWindowList 的窗口枚举服务。
/// 返回顺序保持 z 序（从最前到最后），命中测试取第一个包含点的窗口即为最前窗口。
enum WindowListService {
    struct FilterOptions {
        /// 过滤过小窗口（图标、残留提示框等）。
        var minimumSize = CGSize(width: 50, height: 50)
    }

    /// 当前屏幕上的常规窗口（从最前到最后）。
    /// 仅保留 layer 0 的在屏窗口，排除自身进程与桌面元素。
    static func currentWindows(options: FilterOptions = .init()) -> [WindowInfo] {
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        let primaryHeight = WindowFrameConverter.primaryDisplayHeight()
        let ownPID = getpid()

        var result: [WindowInfo] = []
        for info in list {
            // layer 0 = 常规窗口；菜单栏/状态栏/Dock/悬浮面板均为更高 layer，天然排除。
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pidNumber.int32Value
            guard pid != pid_t(ownPID) else { continue }
            guard let boundsValue = info[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary),
                  bounds.width >= options.minimumSize.width,
                  bounds.height >= options.minimumSize.height else { continue }

            // kCGWindowName 需要屏幕录制权限；无权限时为 nil，不阻断流程。
            let title = info[kCGWindowName as String] as? String
            let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0

            result.append(
                WindowInfo(
                    windowID: CGWindowID(windowID),
                    ownerPID: pid,
                    title: title,
                    cgBounds: bounds,
                    appKitFrame: WindowFrameConverter.appKitFrame(
                        fromCGRect: bounds,
                        primaryDisplayHeight: primaryHeight
                    )
                )
            )
        }
        Log.capture.info("窗口枚举：\(result.count) 个常规窗口")
        return result
    }

    /// 命中测试：返回光标下最前面的窗口（数组顺序即 z 序）。
    static func topWindow(at globalPoint: CGPoint, in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.appKitFrame.contains(globalPoint) }
    }
}
