import os

/// 统一日志入口。
/// 状态转换、截图流程、快捷键注册等关键路径必须留痕（需求 9.2：状态转换可追踪）。
enum Log {
    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let selection = Logger(subsystem: subsystem, category: "selection")
    static let shortcut = Logger(subsystem: subsystem, category: "shortcut")
    static let pin = Logger(subsystem: subsystem, category: "pin")

    private static let subsystem = "com.cd826.zSnap"
}
