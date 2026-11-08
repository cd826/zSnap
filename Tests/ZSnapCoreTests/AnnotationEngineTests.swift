import XCTest

@testable import ZSnapCore

/// 标注引擎测试：增删改、撤销/重做、批量操作压栈。
@MainActor
final class AnnotationEngineTests: XCTestCase {
    private func makeAnnotation(color: RGBAColor = .red) -> Annotation {
        Annotation(
            type: .rectangle,
            color: color,
            lineWidth: 4,
            normalizedPoints: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5)],
            text: nil,
            fontSize: nil
        )
    }

    func testAddAndUndoRedo() {
        let engine = AnnotationEngine()
        let annotation = makeAnnotation()

        engine.add(annotation)
        XCTAssertEqual(engine.annotations.count, 1)
        XCTAssertTrue(engine.canUndo)
        XCTAssertFalse(engine.canRedo)

        engine.undo()
        XCTAssertEqual(engine.annotations.count, 0)
        XCTAssertFalse(engine.canUndo)
        XCTAssertTrue(engine.canRedo)

        engine.redo()
        XCTAssertEqual(engine.annotations.count, 1)
        XCTAssertEqual(engine.annotations[0].id, annotation.id)
    }

    func testRemoveAndUndo() {
        let engine = AnnotationEngine()
        let annotation = makeAnnotation()
        engine.add(annotation)

        engine.remove(id: annotation.id)
        XCTAssertEqual(engine.annotations.count, 0)

        engine.undo()
        XCTAssertEqual(engine.annotations.count, 1)
        XCTAssertEqual(engine.annotations[0].id, annotation.id)
    }

    func testUpdateCreatesHistoryEntry() {
        let engine = AnnotationEngine()
        let annotation = makeAnnotation()
        engine.add(annotation)

        var updated = annotation
        updated.color = .blue
        engine.update(updated)
        XCTAssertEqual(engine.annotations[0].color, .blue)

        engine.undo()
        XCTAssertEqual(engine.annotations[0].color, .red)
    }

    func testMoveBatchOnlyPushesOnce() {
        let engine = AnnotationEngine()
        let annotation = makeAnnotation()
        engine.add(annotation)

        // 模拟拖拽移动：beginBatch 压栈一次，过程内多次 updateWithoutHistory。
        engine.beginBatch()
        for offset in 1...5 {
            var moved = annotation
            moved.normalizedPoints = annotation.normalizedPoints.map {
                CGPoint(x: $0.x + CGFloat(offset) * 0.01, y: $0.y)
            }
            engine.updateWithoutHistory(moved)
        }
        XCTAssertEqual(engine.annotations[0].normalizedPoints[0].x, 0.15, accuracy: 0.0001)

        // 一次 undo 应回到移动前的状态。
        engine.undo()
        XCTAssertEqual(engine.annotations[0].normalizedPoints[0].x, 0.1, accuracy: 0.0001)
    }

    func testNewMutationClearsRedoStack() {
        let engine = AnnotationEngine()
        engine.add(makeAnnotation())
        engine.undo()
        XCTAssertTrue(engine.canRedo)

        engine.add(makeAnnotation(color: .blue))
        XCTAssertFalse(engine.canRedo, "新变更后 redo 栈必须清空")
    }

    func testHistoryCap() {
        let engine = AnnotationEngine()
        for index in 0..<(110) {
            var annotation = makeAnnotation()
            annotation.lineWidth = CGFloat(index)
            engine.add(annotation)
        }
        XCTAssertEqual(engine.annotations.count, 110)
        // 连续撤销最多到初始空状态为止。
        var undoCount = 0
        while engine.canUndo {
            engine.undo()
            undoCount += 1
        }
        XCTAssertLessThanOrEqual(undoCount, 100)
        XCTAssertEqual(engine.annotations.count, 10, "超出栈容量的最早历史被丢弃")
    }
}
