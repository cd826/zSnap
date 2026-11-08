import XCTest

@testable import ZSnapCore

/// 窗口命中测试：数组顺序即 z 序（从最前到最后），取第一个包含点的窗口。
final class WindowHitTesterTests: XCTestCase {
    private func makeWindow(id: UInt32, frame: CGRect) -> WindowInfo {
        WindowInfo(
            windowID: id,
            ownerPID: 100,
            title: "w\(id)",
            cgBounds: .zero,
            appKitFrame: frame
        )
    }

    func testFrontWindowWins() {
        let back = makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let front = makeWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        let hit = WindowListService.topWindow(at: CGPoint(x: 10, y: 10), in: [front, back])
        XCTAssertEqual(hit?.windowID, 2)
    }

    func testPointOnlyInBackWindow() {
        let back = makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let front = makeWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        let hit = WindowListService.topWindow(at: CGPoint(x: 75, y: 75), in: [front, back])
        XCTAssertEqual(hit?.windowID, 1)
    }

    func testNoHitOutsideAllWindows() {
        let window = makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let hit = WindowListService.topWindow(at: CGPoint(x: 200, y: 200), in: [window])
        XCTAssertNil(hit)
    }

    func testEmptyWindowList() {
        XCTAssertNil(WindowListService.topWindow(at: .zero, in: []))
    }

    func testEdgePointGoesToWindowBehind() {
        // CGRect.contains 对右/上边界为开区间：x=50 恰在前窗右边缘，归后窗。
        let back = makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let front = makeWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        let hit = WindowListService.topWindow(at: CGPoint(x: 50, y: 10), in: [front, back])
        XCTAssertEqual(hit?.windowID, 1)
    }
}
