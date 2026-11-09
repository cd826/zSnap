import AppKit
import SwiftUI

/// 统一编辑器窗口（需求 4.1）：图片展示 + 标注工具栏 + 输出操作。
/// 普通截图与长截图最终进入同一编辑器（需求 7.2）。
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private let state: EditorState
    private let onClose: () -> Void
    /// 贴图：携带最终渲染图与逻辑尺寸交由协调器创建悬浮窗（需求 6.1）。
    private let onPin: (CGImage, CGSize) -> Void

    init(
        document: ScreenshotDocument,
        onClose: @escaping () -> Void,
        onPin: @escaping (CGImage, CGSize) -> Void
    ) {
        self.state = EditorState(document: document)
        self.onClose = onClose
        self.onPin = onPin

        let window = NSWindow(
            contentRect: Self.fittedContentRect(aspect: document.pixelSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "zSnap 编辑"
        window.minSize = NSSize(width: 880, height: 460)
        window.center()
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        super.init(window: window)
        window.delegate = self

        let rootView = EditorRootView(state: state, onClose: { [weak window] in
            window?.performClose(nil)
        }, onPin: { [weak self] in
            self?.pinAndClose()
        })
        window.contentView = NSHostingView(rootView: rootView)
    }

    /// 渲染最终图 → 创建贴图 → 关闭编辑器（需求 6.1）。
    private func pinAndClose() {
        guard let image = state.renderFinalImage() else {
            state.flash("贴图失败：无法生成图片")
            return
        }
        onPin(image, state.document.logicalSize)
        window?.performClose(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("未支持 IB 初始化")
    }

    func show() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// 进入编辑器时的一次性提示（如长截图缺口告警）。
    func showNotice(_ text: String) {
        state.flash(text)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    /// 窗口初始尺寸：贴合图片比例，不超过可见区 85%。
    private static func fittedContentRect(aspect: CGSize) -> NSRect {
        guard aspect.width > 0, aspect.height > 0,
              let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: 960, height: 640)
        }
        let visible = screen.visibleFrame
        let maxWidth = visible.width * 0.85
        let maxHeight = (visible.height - 80) * 0.85
        let imageAspect = aspect.width / aspect.height
        var width = maxWidth
        var height = width / imageAspect
        if height > maxHeight {
            height = maxHeight
            width = height * imageAspect
        }
        return NSRect(x: 0, y: 0, width: max(880, width), height: max(460, height + 56))
    }
}

// MARK: - SwiftUI 根视图

struct EditorRootView: View {
    @ObservedObject var state: EditorState
    let onClose: () -> Void
    let onPin: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            EditorCanvasRepresentable(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            EditorToolbarView(state: state, onClose: onClose, onPin: onPin)
        }
        .overlay(alignment: .top) {
            if let message = state.statusMessage {
                Text(message)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 3, y: 1)
                    .transition(.opacity)
                    .task(id: message) {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        state.clearStatus()
                    }
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.statusMessage)
    }
}

struct EditorCanvasRepresentable: NSViewRepresentable {
    let state: EditorState

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.allowsMagnification = false

        let canvas = EditorCanvasView(state: state)
        scrollView.documentView = canvas
        DispatchQueue.main.async {
            canvas.window?.makeFirstResponder(canvas)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

// MARK: - 工具栏

struct EditorToolbarView: View {
    @ObservedObject var state: EditorState
    let onClose: () -> Void
    let onPin: () -> Void

    @State private var showingColorPopover = false

    private static let fontSizeTitles = ["小", "中", "大"]
    private static let colorNames = ["红色", "橙色", "黄色", "绿色", "蓝色", "白色", "黑色"]

    var body: some View {
        HStack(spacing: 12) {
            toolButtons
            toolbarDivider
            colorMenuButton
            widthPicker
            fontSizePicker
            toolbarDivider
            zoomButtons
            toolbarDivider
            historyButtons
            toolbarDivider
            outputButtons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: 缩放

    private var zoomButtons: some View {
        HStack(spacing: 4) {
            Button {
                state.zoomToFit()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .imageScale(.large)
                    .frame(width: 34, height: 30)
            }
            .buttonStyle(.plain)
            .help("适应窗口")

            Button {
                state.zoomToActual()
            } label: {
                Text("1:1")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 34, height: 30)
            }
            .buttonStyle(.plain)
            .help("实际大小（1 图片像素 = 1 屏幕点；⌘+滚轮亦可缩放）")
        }
    }

    private var toolbarDivider: some View {
        Divider()
            .frame(height: 24)
    }

    // MARK: 工具

    private var toolButtons: some View {
        HStack(spacing: 5) {
            ForEach(EditorTool.allCases) { tool in
                Button {
                    state.tool = tool
                } label: {
                    Image(systemName: tool.symbolName)
                        .imageScale(.large)
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.plain)
                .help("\(tool.displayName)")
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(state.tool == tool ? Color.accentColor.opacity(0.28) : Color.clear)
                )
            }
        }
    }

    // MARK: 颜色（按钮 + 弹层选色）

    private var colorMenuButton: some View {
        Button {
            showingColorPopover = true
        } label: {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: state.color.red, green: state.color.green, blue: state.color.blue))
                    .frame(width: 20, height: 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
                    )
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 46, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("标注颜色")
        .popover(isPresented: $showingColorPopover, arrowEdge: .bottom) {
            VStack(spacing: 12) {
                Text("标准颜色")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 4), spacing: 8) {
                    ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { index, paletteColor in
                        Button {
                            state.color = paletteColor
                            state.applyColorToSelected()
                            showingColorPopover = false
                        } label: {
                            Circle()
                                .fill(Color(red: paletteColor.red, green: paletteColor.green, blue: paletteColor.blue))
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle().strokeBorder(
                                        state.color == paletteColor ? Color.accentColor : Color.primary.opacity(0.15),
                                        lineWidth: state.color == paletteColor ? 2 : 1
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .help(Self.colorNames[index])
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    Text("自定义")
                        .font(.callout)
                    ColorPicker("", selection: Binding(
                        get: {
                            Color(red: state.color.red, green: state.color.green, blue: state.color.blue)
                        },
                        set: { newValue in
                            if let components = newValue.rgbaComponents {
                                state.color = RGBAColor(
                                    red: Double(components.r),
                                    green: Double(components.g),
                                    blue: Double(components.b)
                                )
                                state.applyColorToSelected()
                            }
                        }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(16)
        }
    }

    // MARK: 线宽 / 字号（原生下拉选择）

    private var widthPicker: some View {
        Picker(selection: Binding(
            get: { state.lineWidthIndex },
            set: { newValue in
                state.lineWidthIndex = newValue
                state.applyLineWidthToSelected()
            }
        )) {
            ForEach(Array(EditorState.lineWidthPresets.enumerated()), id: \.offset) { index, width in
                HStack(spacing: 6) {
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 26, height: 3 + CGFloat(index) * 3)
                    Text("线宽 \(Int(width)) pt")
                }
                .tag(index)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .frame(width: 118)
        .help("线宽粗细")
    }

    private var fontSizePicker: some View {
        Picker(selection: Binding(
            get: { state.fontSizeIndex },
            set: { newValue in
                state.fontSizeIndex = newValue
                state.applyFontSizeToSelected()
            }
        )) {
            ForEach(Array(EditorState.fontSizePresets.enumerated()), id: \.offset) { index, _ in
                Text("字号 \(Self.fontSizeTitles[index])").tag(index)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .frame(width: 96)
        .help("文字大小（配合文字工具）")
    }

    // MARK: 撤销 / 重做 / 删除

    private var historyButtons: some View {
        HStack(spacing: 5) {
            Button {
                state.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .imageScale(.large)
                    .frame(width: 34, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(!state.engine.canUndo)
            .help("撤销 ⌘Z")

            Button {
                state.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .imageScale(.large)
                    .frame(width: 34, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(!state.engine.canRedo)
            .help("重做 ⇧⌘Z")

            Button {
                state.deleteSelected()
            } label: {
                Image(systemName: "trash")
                    .imageScale(.large)
                    .frame(width: 34, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(state.selectedAnnotationID == nil)
            .help("删除选中标注 Delete")
        }
    }

    // MARK: 输出

    private var outputButtons: some View {
        HStack(spacing: 8) {
            Button {
                state.copyFinalImage()
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .help("复制最终图片到剪贴板 ⌘C")

            Button {
                state.savePNG(parentWindow: nil)
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            .help("保存 PNG ⌘S")

            Button(action: onPin) {
                Label("贴图", systemImage: "pin")
            }
            .help("创建悬浮置顶贴图（含全部标注）")

            Button("取消", action: onClose)
                .help("关闭编辑器 Esc")
        }
    }
}

// MARK: - 颜色分量辅助

extension Color {
    /// 取颜色的 sRGBA 分量（ColorPicker 绑定用）。
    var rgbaComponents: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        #if canImport(SwiftUI)
        let nsColor = NSColor(self).usingColorSpace(.sRGB)
        guard let nsColor else { return nil }
        return (nsColor.redComponent, nsColor.greenComponent, nsColor.blueComponent, nsColor.alphaComponent)
        #endif
    }
}
