import AppKit

/// 贴图管理器：多贴图实例的创建、持有与释放（需求 6.2 / 6.4）。
/// 贴图是常驻旁路对象：存在期间不进入阻塞式状态机，可继续截图/贴图。
@MainActor
final class PinWindowManager {
    private(set) var pins: [PinWindowController] = []

    var pinCount: Int { pins.count }

    func createPin(image: CGImage, logicalSize: CGSize, on screen: NSScreen?) {
        let controller = PinWindowController(
            image: image,
            logicalSize: logicalSize,
            onClose: { [weak self] controller in
                self?.remove(controller)
            }
        )
        controller.show(on: screen)
        pins.append(controller)
        Log.pin.info("创建贴图，当前共 \(self.pins.count) 张")
    }

    private func remove(_ controller: PinWindowController) {
        pins.removeAll { $0 === controller }
        Log.pin.info("移除贴图，剩余 \(self.pins.count) 张")
    }

    /// 应用退出等场景的兜底清理。
    func closeAll() {
        for pin in pins {
            pin.close()
        }
        pins.removeAll()
    }
}
