import XCTest

@testable import ZSnapCore

final class RectMathTests: XCTestCase {
    func testNormalizedRectForwardDrag() {
        let rect = RectMath.normalizedRect(
            from: CGPoint(x: 40, y: 80),
            to: CGPoint(x: 100, y: 200)
        )
        XCTAssertEqual(rect, CGRect(x: 40, y: 80, width: 60, height: 120))
    }

    func testNormalizedRectReversedDrag() {
        // 反方向（右上往左下）拖动
        let rect = RectMath.normalizedRect(
            from: CGPoint(x: 100, y: 200),
            to: CGPoint(x: 40, y: 80)
        )
        XCTAssertEqual(rect, CGRect(x: 40, y: 80, width: 60, height: 120))
    }

    func testIsTapTooSmall() {
        XCTAssertTrue(RectMath.isTapTooSmall(CGRect(x: 0, y: 0, width: 3, height: 100), threshold: 6))
        XCTAssertTrue(RectMath.isTapTooSmall(CGRect(x: 0, y: 0, width: 100, height: 3), threshold: 6))
        XCTAssertFalse(RectMath.isTapTooSmall(CGRect(x: 0, y: 0, width: 10, height: 10), threshold: 6))
    }

    func testDimmingRectsCoverExactlyOutsideSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let selection = CGRect(x: 25, y: 25, width: 50, height: 50)
        let rects = RectMath.dimmingRects(inside: bounds, excluding: selection)

        XCTAssertEqual(rects.count, 4)
        let totalArea = rects.reduce(0.0) { $0 + $1.width * $1.height }
        XCTAssertEqual(totalArea, bounds.width * bounds.height - selection.width * selection.height, accuracy: 0.001)
    }

    func testDimmingRectsWithFullBoundsSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rects = RectMath.dimmingRects(inside: bounds, excluding: bounds)
        XCTAssertTrue(rects.isEmpty)
    }

    func testDimmingRectsWithNullSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rects = RectMath.dimmingRects(inside: bounds, excluding: .null)
        XCTAssertEqual(rects, [bounds])
    }

    func testDimmingRectsWithPartiallyOutOfBoundsSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let selection = CGRect(x: 80, y: 80, width: 60, height: 60) // 右上角越界
        let rects = RectMath.dimmingRects(inside: bounds, excluding: selection)
        let totalArea = rects.reduce(0.0) { $0 + $1.width * $1.height }
        XCTAssertEqual(totalArea, bounds.width * bounds.height - 400, accuracy: 0.001)
    }
}
