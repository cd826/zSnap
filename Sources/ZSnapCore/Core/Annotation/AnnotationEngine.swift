import Foundation
import Combine

/// 标注引擎：持有标注数组与撤销/重做栈（快照式，需求 4.3 / 9.3）。
/// 原则：任何变更前压栈当前状态；图片数据不进入本层。
@MainActor
final class AnnotationEngine: ObservableObject {
    @Published private(set) var annotations: [Annotation] = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private let maxHistory = 100

    // MARK: - 变更（自动进入撤销栈）

    func add(_ annotation: Annotation) {
        pushUndo()
        annotations.append(annotation)
    }

    func update(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        pushUndo()
        annotations[index] = annotation
    }

    func remove(id: UUID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        pushUndo()
        annotations.removeAll { $0.id == id }
    }

    /// 连续操作（如拖拽移动）开始时压栈一次，过程中用 updateWithoutHistory 实时刷新。
    func beginBatch() {
        pushUndo()
    }

    /// 不进入撤销栈的实时更新（拖拽预览用）。
    func updateWithoutHistory(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
    }

    // MARK: - 撤销 / 重做

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        refreshFlags()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        refreshFlags()
    }

    // MARK: - Private

    private func pushUndo() {
        undoStack.append(annotations)
        if undoStack.count > maxHistory {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        refreshFlags()
    }

    private func refreshFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}
