import Foundation

/// 应用全局状态（需求 9.2）。
/// 单向流转：idle → selecting → presentingResult → idle；权限引导与错误为旁路，处理完回到 idle。
enum AppState: Equatable {
    case idle
    case selecting
    case presentingResult
    case permissionRequired
    case error

    /// 忙碌中（不允许重复启动截图流程）。
    var isBusy: Bool {
        switch self {
        case .selecting, .presentingResult, .permissionRequired:
            return true
        case .idle, .error:
            return false
        }
    }

    var description: String {
        switch self {
        case .idle: return "idle"
        case .selecting: return "selecting"
        case .presentingResult: return "presentingResult"
        case .permissionRequired: return "permissionRequired"
        case .error: return "error"
        }
    }
}
