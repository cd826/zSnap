import XCTest

@testable import ZSnapCore

/// 坐标转换单元测试：覆盖 Retina、非 Retina、多屏拼接（上下/左右布局）、越界钳制、取整。
final class ImageCoordinateConverterTests: XCTestCase {
    /// 主显示器：2560×1440 pt，Retina 2x，快照 5120×2880 px。
    private let mainDisplay = DisplayGeometry(
        displayID: 1,
        logicalFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        scaleFactor: 2,
        pixelSize: CGSize(width: 5120, height: 2880)
    )

    func testFullFrameOnMainDisplay() {
        let rect = ImageCoordinateConverter.pixelRect(fromGlobalRect: mainDisplay.logicalFrame, in: mainDisplay)
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 5120, height: 2880))
    }

    func testSubRegionYFlip() {
        // 逻辑 (100, 1300, 200×100)（左下原点）：选区顶边距显示器顶边 140 pt × 2 = 280 px，
        // 像素矩形顶边 y = 2880 - 2800 = 80。
        let global = CGRect(x: 100, y: 1300, width: 200, height: 100)
        let rect = ImageCoordinateConverter.pixelRect(fromGlobalRect: global, in: mainDisplay)
        XCTAssertEqual(rect, CGRect(x: 200, y: 80, width: 400, height: 200))
    }

    func testExternalDisplayOneXSideBySide() {
        // 外接屏在主屏右侧：1x 缩放
        let external = DisplayGeometry(
            displayID: 2,
            logicalFrame: CGRect(x: 2560, y: 0, width: 1920, height: 1080),
            scaleFactor: 1,
            pixelSize: CGSize(width: 1920, height: 1080)
        )
        let global = CGRect(x: 3000, y: 500, width: 100, height: 80)
        let rect = ImageCoordinateConverter.pixelRect(fromGlobalRect: global, in: external)
        XCTAssertEqual(rect, CGRect(x: 440, y: 500, width: 100, height: 80))
    }

    func testDisplayAboveMain() {
        // 外接屏在主屏上方：逻辑原点 y = 1440
        let upper = DisplayGeometry(
            displayID: 2,
            logicalFrame: CGRect(x: 0, y: 1440, width: 1920, height: 1080),
            scaleFactor: 1,
            pixelSize: CGSize(width: 1920, height: 1080)
        )
        let global = CGRect(x: 100, y: 2000, width: 50, height: 60)
        let rect = ImageCoordinateConverter.pixelRect(fromGlobalRect: global, in: upper)
        XCTAssertEqual(rect, CGRect(x: 100, y: 460, width: 50, height: 60))
    }

    func testClampBeyondDisplay() {
        // 选区越界时钳制到显示器范围内
        let global = CGRect(x: -100, y: -50, width: 400, height: 300)
        let rect = ImageCoordinateConverter.pixelRect(fromGlobalRect: global, in: mainDisplay)
        XCTAssertEqual(rect, CGRect(x: 0, y: 2380, width: 600, height: 500))
    }

    func testFractionalCoordsProduceIntegralPixels() {
        // 小数逻辑坐标 → 像素取整，无小数像素坐标
        let global = CGRect(x: 10.4, y: 10.6, width: 100.4, height: 100.2)
        let rect = ImageCoordinateConverter.pixelRect(fromGlobalRect: global, in: mainDisplay)
        XCTAssertEqual(rect, CGRect(x: 21, y: 2658, width: 201, height: 201))
    }

    func testActualPixelRatioMismatch() {
        // SCK 返回尺寸与 points×scaleFactor 不一致时，以实际像素尺寸反推比例（防御性设计）
        let odd = DisplayGeometry(
            displayID: 3,
            logicalFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            scaleFactor: 2,
            pixelSize: CGSize(width: 1000, height: 800)
        )
        let global = CGRect(x: 100, y: 100, width: 200, height: 100)
        let rect = ImageCoordinateConverter.pixelRect(fromGlobalRect: global, in: odd)
        XCTAssertEqual(rect, CGRect(x: 100, y: 600, width: 200, height: 100))
    }

    func testRectOutsideDisplayReturnsZero() {
        let global = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        let rect = ImageCoordinateConverter.pixelRect(fromGlobalRect: global, in: mainDisplay)
        XCTAssertEqual(rect, .zero)
    }

    func testPixelPointTopLeftCorner() {
        // 主屏左上角：逻辑 (0, 1440) → 像素 (0, 0)
        let point = ImageCoordinateConverter.pixelPoint(fromGlobalPoint: CGPoint(x: 0, y: 1440), in: mainDisplay)
        XCTAssertEqual(point, CGPoint(x: 0, y: 0))
    }

    func testPixelPointBottomLeftCorner() {
        // 主屏左下角：逻辑 (0, 0) → 像素 (0, 2880)
        let point = ImageCoordinateConverter.pixelPoint(fromGlobalPoint: CGPoint(x: 0, y: 0), in: mainDisplay)
        XCTAssertEqual(point, CGPoint(x: 0, y: 2880))
    }
}
