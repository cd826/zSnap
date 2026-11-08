// swift make_icon.swift — 生成 zSnap 应用图标（Resources/AppIcon.icns）。
// 设计：蓝色渐变圆角底 + 白色取景框四角 + 标注箭头元素。
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetURL = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let s = size / 1024

        // 渐变圆角底。
        let bgRect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 185 * s, yRadius: 185 * s)
        bgPath.addClip()
        let gradient = NSGradient(
            starting: NSColor(srgbRed: 0.36, green: 0.66, blue: 1.0, alpha: 1),
            ending: NSColor(srgbRed: 0.13, green: 0.38, blue: 0.93, alpha: 1)
        )!
        gradient.draw(in: bgPath, angle: -90)

        // 取景框四角。
        let bracketInset: CGFloat = 250 * s
        let arm: CGFloat = 130 * s
        let bracketRect = CGRect(
            x: bracketInset, y: bracketInset,
            width: bgRect.width - bracketInset * 2,
            height: bgRect.height - bracketInset * 2
        )
        let white = NSColor.white.withAlphaComponent(0.96)
        white.setStroke()
        let bracketPath = NSBezierPath()
        bracketPath.lineWidth = 46 * s
        bracketPath.lineCapStyle = .round
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: bracketRect.minX, y: bracketRect.maxY), CGPoint(x: bracketRect.minX + arm, y: bracketRect.maxY), CGPoint(x: bracketRect.minX, y: bracketRect.maxY - arm)),
            (CGPoint(x: bracketRect.maxX, y: bracketRect.maxY), CGPoint(x: bracketRect.maxX - arm, y: bracketRect.maxY), CGPoint(x: bracketRect.maxX, y: bracketRect.maxY - arm)),
            (CGPoint(x: bracketRect.minX, y: bracketRect.minY), CGPoint(x: bracketRect.minX + arm, y: bracketRect.minY), CGPoint(x: bracketRect.minX, y: bracketRect.minY + arm)),
            (CGPoint(x: bracketRect.maxX, y: bracketRect.minY), CGPoint(x: bracketRect.maxX - arm, y: bracketRect.minY), CGPoint(x: bracketRect.maxX, y: bracketRect.minY + arm))
        ]
        for (corner, h, v) in corners {
            bracketPath.move(to: h)
            bracketPath.line(to: corner)
            bracketPath.line(to: v)
        }
        bracketPath.stroke()

        // 标注箭头（左下 → 右上），点出"标注"主题。
        let tail = CGPoint(x: 380 * s, y: 380 * s)
        let tip = CGPoint(x: 660 * s, y: 660 * s)
        let angle = CGFloat.pi / 4
        let headLength: CGFloat = 90 * s
        let arrowPath = NSBezierPath()
        arrowPath.lineWidth = 40 * s
        arrowPath.lineCapStyle = .round
        arrowPath.move(to: tail)
        arrowPath.line(to: CGPoint(x: tip.x - cos(angle) * headLength * 0.7, y: tip.y - sin(angle) * headLength * 0.7))
        arrowPath.stroke()
        let arrowHead = NSBezierPath()
        arrowHead.move(to: tip)
        arrowHead.line(to: CGPoint(x: tip.x - headLength * cos(angle - 0.35), y: tip.y - headLength * sin(angle - 0.35)))
        arrowHead.line(to: CGPoint(x: tip.x - headLength * cos(angle + 0.35), y: tip.y - headLength * sin(angle + 0.35)))
        arrowHead.close()
        white.setFill()
        arrowHead.fill()

        return true
    }
}

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, pixel) in variants {
    let image = drawIcon(size: pixel)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
    print("渲染失败：\(name)")
            continue
    }
    try png.write(to: iconsetURL.appendingPathComponent("\(name).png"))
    print("生成 \(name).png (\(pixel)px)")
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
print("iconutil exit: \(process.terminationStatus)")
