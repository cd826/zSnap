# zSnap

面向 macOS 的轻量级截图效率工具：区域 / 窗口 / 全屏截图、标注编辑、悬浮贴图、长截图。

- 最低系统：**macOS 14 (Sonoma)**
- 技术栈：Swift + SwiftUI + AppKit + ScreenCaptureKit（详见 `docs/` 各阶段报告）
- 形态：菜单栏常驻应用（无 Dock 图标）

## 构建与运行

```bash
./scripts/bundle.sh     # 编译 + 组装 build/zSnap.app（稳定签名）
open build/zSnap.app    # 启动（菜单栏出现取景框图标）
swift test              # 运行单元测试
```

- 应用图标重新生成：`swift scripts/make_icon.swift`
- 指定签名身份：`ZSNAP_SIGN_IDENTITY="证书名" ./scripts/bundle.sh`（默认自动使用钥匙串中的 `zSnap Dev` 自签名证书，屏幕录制授权在重建后保留）

## 使用说明

| 功能 | 操作 |
|---|---|
| 区域截图 | 全局快捷键（默认 **⌥A**，可在设置中自定义）或菜单「区域截图」→ 拖拽选区 |
| 窗口截图 | 选区时**悬停**高亮窗口 → **点击**即截取窗口自身内容（被遮挡也可截完整窗口、无阴影） |
| 全屏截图 | 选区时**点击桌面空白处** = 该屏全屏；或菜单「全屏截图」按显示器选择 |
| 长截图 | 菜单「长截图」→ 框选区域 → **手动滚动页面**，zSnap 自动拼接 → 点 HUD「完成」 |
| 标注 | 截图后自动进入编辑器：箭头 / 矩形 / 椭圆 / 文字 / 马赛克，7 色 + 自定义取色、4 档线宽、撤销重做、选中移动删除 |
| 输出 | 复制 ⌘C / 保存 PNG ⌘S / 贴图（悬浮置顶，滚轮或拖角缩放，悬停工具栏） |
| 设置 | 菜单「设置…」：快捷键自定义、遮罩强度、开机启动 |

### 编辑器快捷键

| 键 | 功能 |
|---|---|
| ⌘Z / ⇧⌘Z | 撤销 / 重做 |
| ⌘C / ⌘S | 复制 / 保存 |
| Delete | 删除选中标注 |
| Esc | 逐级退出（文字输入 → 绘制 → 选中 → 关闭） |
| 滚轮 / 捏合 | 滚动 / 缩放（⌘+滚轮缩放，1:1 / 适应窗口按钮在工具栏） |

## 目录结构

```
Sources/ZSnapCore/
├── App/            # AppCoordinator（状态机）/ AppDelegate / 启动引导
├── Core/
│   ├── Capture/    # SCK 截图服务、选区覆盖层、窗口识别、长截图拼接、HUD
│   ├── Annotation/ # 标注模型 / 引擎（撤销重做）/ 渲染器（预览与导出共用）
│   ├── Image/      # 坐标转换（四层坐标 + 翻转）、导出
│   ├── Clipboard/  # 剪贴板
│   ├── Pin/        # 贴图窗口与管理
│   ├── Permissions/# 屏幕录制权限
│   └── Shortcut/   # Carbon 全局快捷键
├── Features/       # 编辑器 / 菜单 / 设置 / 权限引导
└── Shared/         # 通用工具 / 设置存储
Tests/               # 41 项单元测试（坐标/拼接/引擎/导出像素校验）
docs/                # 需求文档 + Phase 0-5 验收报告
scripts/             # bundle.sh（打包）/ make_icon.swift（图标）
```

## 已知限制

- 长截图基于帧间平移匹配：吸顶/悬浮元素会产生重复带，动态加载页面可能出现缺口（HUD 会提示回滚补拍）；兼容性以实测为准
- 贴图在全屏 Space 的置顶表现受 macOS 窗口层级机制约束（`fullScreenAuxiliary`，详见 Phase 3 报告实测结论）
- ad-hoc/自签名应用不入 App Store；对外分发需 Apple Developer 证书（评估见 Phase 5 报告）
