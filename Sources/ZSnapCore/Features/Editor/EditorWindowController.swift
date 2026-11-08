import AppKit
import SwiftUI

/// 统一编辑器窗口（需求 4.1）：图片展示 + 标注工具栏 + 输出操作。
/// 普通截图与长截图最终进入同一编辑器（需求 7.2）。
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private let state: EditorState
    private let onClose: () -> Void

    init(document: ScreenshotDocument, onClose: @escaping () -> Void) {
        self.state = EditorState(document: document)
        self.onClose = onClose

        let window = NSWindow(
            contentRect: Self.fittedContentRect(aspect: document.pixelSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "zSnap 编辑"
        window.minSize = NSSize(width: 720, height: 460)
        window.center()
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        super.init(window: window)
        window.delegate = self

        let rootView = EditorRootView(state: state, onClose: { [weak window] in
            window?.performClose(nil)
        })
        window.contentView = NSHostingView(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("未支持 IB 初始化")
    }

    func show() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
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
        return NSRect(x: 0, y: 0, width: max(720, width), height: max(460, height + 56))
    }
}

// MARK: - SwiftUI 根视图

struct EditorRootView: View {
    @ObservedObject var state: EditorState
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            EditorCanvasRepresentable(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            EditorToolbarView(state: state, onClose: onClose)
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

    func makeNSView(context: Context) -> EditorCanvasView {
        let view = EditorCanvasView(state: state)
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: EditorCanvasView, context: Context) {}
}

// MARK: - 工具栏

struct EditorToolbarView: View {
    @ObservedObject var state: EditorState
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            toolButtons
            toolbarDivider
            colorButtons
            toolbarDivider
            sizeControls
            toolbarDivider
            historyButtons
            toolbarDivider
            outputButtons
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.bar)
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

    // MARK: 颜色

    private var colorButtons: some View {
        HStack(spacing: 6) {
            ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { _, paletteColor in
                Button {
                    state.color = paletteColor
                    state.applyColorToSelected()
                } label: {
                    Circle()
                        .fill(Color(red: paletteColor.red, green: paletteColor.green, blue: paletteColor.blue))
                        .frame(width: 19, height: 19)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    state.color == paletteColor ? Color.primary.opacity(0.8) : Color.clear,
                                    lineWidth: 1.5
                                )
                        )
                }
                .buttonStyle(.plain)
                .help("标注颜色")
            }
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
            .help("自定义颜色")
            .frame(width: 34)
        }
    }

    // MARK: 线宽 / 字号

    @ViewBuilder
    private var sizeControls: some View {
        if state.tool == .text {
            HStack(spacing: 5) {
                ForEach(Array(EditorState.fontSizePresets.enumerated()), id: \.offset) { index, _ in
                    let titles = ["小", "中", "大"]
                    Button {
                        state.fontSizeIndex = index
                        state.applyFontSizeToSelected()
                    } label: {
                        Text(titles[index])
                            .font(.body)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help("文字大小")
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(state.fontSizeIndex == index ? Color.accentColor.opacity(0.28) : Color.clear)
                    )
                }
            }
        } else {
            HStack(spacing: 5) {
                ForEach(Array(EditorState.lineWidthPresets.enumerated()), id: \.offset) { index, width in
                    Button {
                        state.lineWidthIndex = index
                        state.applyLineWidthToSelected()
                    } label: {
                        Capsule()
                            .fill(Color.primary)
                            .frame(width: 20, height: 4 + CGFloat(index) * 3.5)
                            .frame(width: 34, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help("线宽 \(Int(width)) pt")
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(state.lineWidthIndex == index ? Color.accentColor.opacity(0.28) : Color.clear)
                    )
                }
            }
        }
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

            Button("贴图") {}
                .disabled(true)
                .help("贴图（Phase 3 提供）")

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
