import AppKit
import ScreenCaptureKit

/// 基于 ScreenCaptureKit 的截图服务（最低 macOS 14，SCScreenshotManager）。
///
/// 关键约束：
/// - showsCursor = false：光标不得进入截图。
/// - 快照在遮罩层显示之前获取（"冻结快照"方案），从根本上保证遮罩/工具栏不会截入图片。
/// - 优先以 .best 捕获原生像素；若返回尺寸与显示器像素尺寸不符，回退为显式指定像素尺寸重试。
final class ScreenCaptureService {
    /// 一次截图会话的数据：各显示器冻结快照 + 当前可共享窗口列表（用于窗口截图匹配）。
    struct CaptureSession {
        let snapshots: [DisplaySnapshot]
        /// SCWindows 顺序无 z 序保证；窗口匹配需结合 CGWindowList 的命中结果（pid + frame）。
        let windows: [SCWindow]
    }

    struct DisplaySnapshot {
        let geometry: DisplayGeometry
        let image: CGImage
    }

    enum CaptureError: LocalizedError {
        case noDisplayCaptured

        var errorDescription: String? {
            switch self {
            case .noDisplayCaptured:
                return "未能获取任何显示器的截图内容。"
            }
        }
    }

    /// 抓取一次截图会话：所有显示器的冻结快照 + 可共享窗口列表。
    func captureSession() async throws -> CaptureSession {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var snapshots: [DisplaySnapshot] = []

        for display in content.displays {
            guard let screen = Self.nsscreen(forDisplayID: display.displayID) else {
                Log.capture.warning("SCK 显示器 \(display.displayID) 未能匹配到 NSScreen，已跳过")
                continue
            }
            let image = try await Self.captureDisplay(display, screen: screen)
            snapshots.append(
                DisplaySnapshot(
                    geometry: DisplayGeometry(
                        displayID: display.displayID,
                        logicalFrame: screen.frame,
                        scaleFactor: screen.backingScaleFactor,
                        pixelSize: CGSize(width: image.width, height: image.height)
                    ),
                    image: image
                )
            )
            Log.capture.info("已捕获显示器 \(display.displayID)：\(image.width)×\(image.height) px")
        }

        guard !snapshots.isEmpty else { throw CaptureError.noDisplayCaptured }
        return CaptureSession(snapshots: snapshots, windows: content.windows)
    }

    /// 抓取单个显示器的完整快照（全屏截图入口）。
    func captureFullScreen(of screen: NSScreen) async throws -> CGImage {
        guard let displayID = Self.displayID(of: screen) else {
            throw CaptureError.noDisplayCaptured
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplayCaptured
        }
        return try await Self.captureDisplay(display, screen: screen)
    }

    /// 抓取显示器快照并排除指定 AppKit 窗口（长截图 HUD 用，保证 HUD 不入帧）。
    /// - Parameter excludingPanelFrame: 需要排除的自身面板的 AppKit 全局 frame（可为 nil）。
    func captureFullScreen(of screen: NSScreen, excludingPanelFrame: CGRect) async throws -> CGImage {
        guard let displayID = Self.displayID(of: screen) else {
            throw CaptureError.noDisplayCaptured
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplayCaptured
        }
        let cgFrame = WindowFrameConverter.cgFrame(fromAppKitFrame: excludingPanelFrame)
        let excluded = content.windows.filter { window in
            guard window.owningApplication?.processID == pid_t(getpid()) else { return false }
            return abs(window.frame.minX - cgFrame.minX) <= 1
                && abs(window.frame.minY - cgFrame.minY) <= 1
                && abs(window.frame.width - cgFrame.width) <= 1
                && abs(window.frame.height - cgFrame.height) <= 1
        }
        if excluded.isEmpty {
            Log.capture.warning("未能匹配到需排除的自身窗口，该帧可能包含 HUD")
            return try await Self.captureDisplay(display, screen: screen)
        }
        let expectedPixelSize = CGSize(
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor
        )
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = Self.baseConfiguration()
        configuration.width = Int(expectedPixelSize.width)
        configuration.height = Int(expectedPixelSize.height)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// 截取窗口自身内容（desktopIndependentWindow）：
    /// 即使窗口被部分遮挡也能截取完整内容，且不含窗口阴影。
    /// - Parameter scale: 窗口所在显示器的缩放系数，决定输出像素密度。
    func captureWindow(_ window: SCWindow, scale: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.width = max(1, Int((window.frame.width * scale).rounded()))
        configuration.height = max(1, Int((window.frame.height * scale).rounded()))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        Log.capture.info("窗口截图完成：\(image.width)×\(image.height) px")
        return image
    }

    // MARK: - Private

    private static func captureDisplay(_ display: SCDisplay, screen: NSScreen) async throws -> CGImage {
        let expectedPixelSize = CGSize(
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor
        )

        var image = try await captureImage(display: display, width: nil, height: nil)
        if abs(CGFloat(image.width) - expectedPixelSize.width) > 1
            || abs(CGFloat(image.height) - expectedPixelSize.height) > 1 {
            let expectedWidth = Int(expectedPixelSize.width)
            let expectedHeight = Int(expectedPixelSize.height)
            Log.capture.warning("显示器 \(display.displayID) 返回尺寸 \(image.width)×\(image.height)，与预期 \(expectedWidth)×\(expectedHeight) 不符，改用显式像素尺寸重试")
            image = try await captureImage(
                display: display,
                width: Int(expectedPixelSize.width),
                height: Int(expectedPixelSize.height)
            )
        }
        return image
    }

    private static func baseConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return configuration
    }

    private static func captureImage(display: SCDisplay, width: Int?, height: Int?) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = baseConfiguration()
        if let width, let height {
            configuration.width = width
            configuration.height = height
        }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func nsscreen(forDisplayID displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(of: $0) == displayID }
    }
}
