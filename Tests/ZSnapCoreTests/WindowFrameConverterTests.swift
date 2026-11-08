import XCTest

@testable import ZSnapCore

/// CG（左上原点）↔ AppKit（左下原点）窗口坐标转换测试。
final class WindowFrameConverterTests: XCTestCase {
    func testCGRectToAppKitRect() {
        // CG (100, 50, 200×100)：顶部距主屏顶 50pt
        // AppKit: y = 1440 - (50 + 100) = 1290
        let cg = CGRect(x: 100, y: 50, width: 200, height: 100)
        let appKit = WindowFrameConverter.appKitFrame(fromCGRect: cg, primaryDisplayHeight: 1440)
        XCTAssertEqual(appKit, CGRect(x: 100, y: 1290, width: 200, height: 100))
    }

    func testCGRectToAppKitRectAtBottom() {
        // CG y = 1340（紧贴主屏底边）：1340 + 100 = 1440 → AppKit y = 0
        let cg = CGRect(x: 0, y: 1340, width: 300, height: 100)
        let appKit = WindowFrameConverter.appKitFrame(fromCGRect: cg, primaryDisplayHeight: 1440)
        XCTAssertEqual(appKit, CGRect(x: 0, y: 0, width: 300, height: 100))
    }

    func testPointRoundTrip() {
        let cgPoint = CGPoint(x: 300, y: 700)
        let appKit = WindowFrameConverter.appKitPoint(fromCGPoint: cgPoint, primaryDisplayHeight: 1440)
        XCTAssertEqual(appKit, CGPoint(x: 300, y: 740))
        let back = WindowFrameConverter.cgPoint(fromAppKitPoint: appKit, primaryDisplayHeight: 1440)
        XCTAssertEqual(back, cgPoint)
    }

    func testFrameRoundTrip() {
        let cg = CGRect(x: 42, y: 123, width: 480, height: 320)
        let appKit = WindowFrameConverter.appKitFrame(fromCGRect: cg, primaryDisplayHeight: 1440)
        let back = CGRect(
            x: appKit.origin.x,
            y: 1440 - appKit.maxY,
            width: appKit.width,
            height: appKit.height
        )
        XCTAssertEqual(back, cg)
    }
}
