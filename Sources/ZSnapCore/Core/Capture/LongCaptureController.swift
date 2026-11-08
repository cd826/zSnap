import AppKit
import ScreenCaptureKit

/// 长截图会话：手动滚动 + 定时抓帧 + 帧间匹配增量拼接（Phase 4）。
///
/// 流程：框选区域 → 用户滚动页面 → 每隔 interval 抓取显示器帧并裁剪区域 →
/// 与上一帧做模板匹配得到滚动位移 → 增量拼接到结果画布 → 用户点击"完成"。
/// HUD 面板在截图时通过 SCK 窗口排除，不会进入画面。
@MainActor
final class LongCaptureController {
    /// 拼接结果上限（图片像素），防止内存失控。
    static let maxStitchedPixels: Int = 18_000
    /// 抓帧间隔。
    static let interval: TimeInterval = 0.35

    private let regionRect: CGRect          // 全局逻辑坐标
    private let geometry: DisplayGeometry
    private let screen: NSScreen
    private let onFinish: (CGImage?, String?) -> Void  // 结果图（nil=取消）+ 错误信息

    private var timer: Timer?
    private var isCapturingFrame = false
    private var canvasImage: CGImage?
    private var coveredRows = 0             // 内容方向已覆盖行数（图片像素）
    private var lastFrameGray: ScrollStitcher.GrayImage?
    private var lastFrame: CGImage?
    private var frameCount = 0
    private var gapDetected = false
    private var hasFinished = false
    private var hudController: LongCaptureHUDController?

    init(regionRect: CGRect, geometry: DisplayGeometry, screen: NSScreen, onFinish: @escaping (CGImage?, String?) -> Void) {
        self.regionRect = regionRect
        self.geometry = geometry
        self.screen = screen
        self.onFinish = onFinish
    }

    func start() {
        let hud = LongCaptureHUDController(
            regionRect: self.regionRect,
            onComplete: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() }
        )
        hudController = hud
        hud.show()

        tick()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        let widthPt = Int(regionRect.width)
        let heightPt = Int(regionRect.height)
        let displayID = geometry.displayID
        Log.capture.info("长截图会话开始：区域 \(widthPt)×\(heightPt) pt @ 显示器 \(displayID)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hudController?.close()
        hudController = nil
    }

    func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        stop()
        let frames = frameCount
        let height = coveredRows
        let gap = gapDetected
        Log.capture.info("长截图完成：\(frames) 帧，高度 \(height) px，出现缺口 \(gap)")
        onFinish(canvasImage, gapDetected ? "滚动过快出现缺口，长图可能存在缺失" : nil)
    }

    func cancel() {
        guard !hasFinished else { return }
        hasFinished = true
        stop()
        Log.capture.info("长截图取消")
        onFinish(nil, nil)
    }

    // MARK: - 抓帧

    private func tick() {
        guard !hasFinished, !isCapturingFrame, let hudFrame = hudController?.panelFrame else { return }
        isCapturingFrame = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let fullFrame = try await self.captureService.captureFullScreen(of: self.screen, excludingPanelFrame: hudFrame)
                self.appendFrame(fullFrame)
            } catch {
                Log.capture.error("长截图抓帧失败：\(error.localizedDescription, privacy: .public)")
            }
            self.isCapturingFrame = false
        }
    }

    private let captureService = ScreenCaptureService()

    private func appendFrame(_ fullFrame: CGImage) {
        let pixelRect = ImageCoordinateConverter.pixelRect(fromGlobalRect: regionRect, in: geometry)
        guard pixelRect.width > 0, pixelRect.height > 0,
              let frame = fullFrame.cropping(to: pixelRect) else {
            return
        }
        frameCount += 1

        guard let gray = ScrollStitcher.grayscale(from: frame) else { return }
        defer { lastFrameGray = gray; lastFrame = frame }

        // 首帧：直接作为拼接画布。
        guard let previous = lastFrameGray, canvasImage != nil else {
            canvasImage = frame
            coveredRows = frame.height
            updateHUD()
            return
        }

        // 锚定式分析：上一帧底带在当前帧中的位置决定新内容起点。
        // 注意：匹配在灰度降采样空间进行，fromRow 已换算回全分辨率。
        switch ScrollStitcher.analyzeScroll(previous: previous, current: gray, downscale: 2) {
        case .append(let fromRow):
            let appendCount = frame.height - fromRow
            let newTotal = coveredRows + appendCount
            // 超高保护。
            if newTotal > Self.maxStitchedPixels {
                Log.capture.warning("长截图达到高度上限 \(Self.maxStitchedPixels) px，自动完成")
                finish()
                return
            }
            appendSlice(
                from: frame,
                rect: CGRect(x: 0, y: fromRow, width: frame.width, height: appendCount)
            )
            gapDetected = false
        case .noNewContent:
            gapDetected = false
        case .unreliable:
            // 底带滚出画面（滚动过快）或画面突变：跳过并提示，回滚可补拍。
            gapDetected = true
        }
        updateHUD()
    }

    /// 把 frame 中的 rect 区域增量拼接到画布底部（重建画布）。
    private func appendSlice(from frame: CGImage, rect: CGRect) {
        guard rect.width > 0, rect.height > 0,
              let slice = frame.cropping(to: rect) else { return }
        let newTotal = coveredRows + Int(rect.height)
        let width = frame.width
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: newTotal, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return }

        // 位图上下文 y 向上：内容第 0 行对应位图最顶行。
        context.interpolationQuality = .high
        context.draw(canvasImage!, in: CGRect(x: 0, y: CGFloat(newTotal - coveredRows), width: CGFloat(width), height: CGFloat(coveredRows)))
        context.draw(slice, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: rect.height))

        canvasImage = context.makeImage()
        coveredRows = newTotal
    }

    private func updateHUD() {
        let status: String
        if gapDetected {
            status = "滚动过快出现缺口，请向上回滚一点"
        } else if frameCount <= 1 {
            status = "请开始滚动页面…"
        } else {
            status = "滚动页面，完成后点击「完成」"
        }
        hudController?.update(height: coveredRows, frames: frameCount, status: status)
    }
}

/// 长截图 HUD：悬浮提示面板（截图时被 SCK 排除，不入帧）。
@MainActor
final class LongCaptureHUDController: NSWindowController {
    private let onComplete: () -> Void
    private let onCancel: () -> Void
    private let hudView: LongCaptureHUDView

    init(regionRect: CGRect, onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onCancel = onCancel
        let view = LongCaptureHUDView(onComplete: onComplete, onCancel: onCancel)
        self.hudView = view

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.contentView = view
        // 优先放在区域上方，其次下方，最后区域内左上角。
        let size = window.frame.size
        let screenVisible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var origin = CGPoint(x: regionRect.midX - size.width / 2, y: regionRect.maxY + 10)
        if origin.y + size.height > screenVisible.maxY {
            origin = CGPoint(x: regionRect.midX - size.width / 2, y: regionRect.minY - size.height - 10)
        }
        if origin.y < screenVisible.minY {
            origin = CGPoint(x: regionRect.minX + 12, y: regionRect.maxY - size.height - 12)
        }
        window.setFrameOrigin(origin)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("未支持 IB 初始化")
    }

    var panelFrame: CGRect { window?.frame ?? .zero }

    func show() {
        window?.orderFrontRegardless()
    }

    override func close() {
        window?.orderOut(nil)
    }

    func update(height: Int, frames: Int, status: String) {
        hudView.update(height: height, frames: frames, status: status)
    }
}

@MainActor
private final class LongCaptureHUDView: NSView {
    private let titleLabel: NSTextField
    private let statusLabel: NSTextField
    private let completeButton: NSButton
    private let cancelButton: NSButton
    // NSControl.target 为弱引用，桥对象须由视图持有。
    private let completeActionTarget: ClosureTarget
    private let cancelActionTarget: ClosureTarget

    init(onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        titleLabel = NSTextField(labelWithString: "长截图进行中")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel = NSTextField(labelWithString: "请开始滚动页面…")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        completeButton = NSButton(title: "完成", target: nil, action: nil)
        completeButton.bezelStyle = .rounded
        completeButton.keyEquivalent = "\r"
        cancelButton = NSButton(title: "取消", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        completeActionTarget = ClosureTarget(action: onComplete)
        cancelActionTarget = ClosureTarget(action: onCancel)

        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 92))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        completeButton.bezelColor = .controlAccentColor
        completeButton.target = completeActionTarget
        completeButton.action = #selector(ClosureTarget.run)
        cancelButton.target = cancelActionTarget
        cancelButton.action = #selector(ClosureTarget.run)

        for view in [titleLabel, statusLabel, completeButton, cancelButton] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            completeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            completeButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            cancelButton.trailingAnchor.constraint(equalTo: completeButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: completeButton.centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("未支持 IB 初始化")
    }

    func update(height: Int, frames: Int, status: String) {
        titleLabel.stringValue = "长截图进行中 · 已拼接 \(height) px（\(frames) 帧）"
        statusLabel.stringValue = status
    }
}

/// 轻量 target/action 桥（避免 HUD 持有控制器强引用）。
@MainActor
private final class ClosureTarget: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
