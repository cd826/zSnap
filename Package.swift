// swift-tools-version: 5.10
import PackageDescription

// zSnap — macOS 截图效率工具
// 最低系统 macOS 14（Sonoma）：SCScreenshotManager 等现代截图 API 的下限（技术选型结论，见 docs/phase0-report.md）。
let package = Package(
    name: "zSnap",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // 核心库：截图、选区、坐标、权限、快捷键、应用协调等全部逻辑。
        .target(name: "ZSnapCore"),
        // 可执行入口：仅包含 App 启动引导。
        .executableTarget(
            name: "zSnap",
            dependencies: ["ZSnapCore"]
        ),
        .testTarget(
            name: "ZSnapCoreTests",
            dependencies: ["ZSnapCore"]
        )
    ]
)
