import CoreGraphics

/// 与选区相关的纯几何工具。不依赖 AppKit，保证可单元测试。
enum RectMath {
    /// 由任意方向的起止点生成规范矩形（支持反方向拖动）。
    static func normalizedRect(from startPoint: CGPoint, to endPoint: CGPoint) -> CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(startPoint.x - endPoint.x),
            height: abs(startPoint.y - endPoint.y)
        )
    }

    /// 点到线段的最短距离（用于箭头等线状标注的命中测试）。
    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let apx = point.x - a.x
        let apy = point.y - a.y
        let abLengthSquared = abx * abx + aby * aby
        guard abLengthSquared > 0 else { return hypot(apx, apy) }
        let t = max(0, min(1, (apx * abx + apy * aby) / abLengthSquared))
        let cx = a.x + abx * t
        let cy = a.y + aby * t
        return hypot(point.x - cx, point.y - cy)
    }

    /// 是否小到应视为点击（用于"点一下即截取该屏全屏"的手势语义）。
    static func isTapTooSmall(_ rect: CGRect, threshold: CGFloat) -> Bool {
        rect.width < threshold || rect.height < threshold
    }

    /// 返回覆盖 bounds 内、selection 之外的遮罩矩形（上、下、左、右）。
    /// selection 允许部分越界或为 .null（此时返回整个 bounds，即全屏压暗）。
    static func dimmingRects(inside bounds: CGRect, excluding selection: CGRect) -> [CGRect] {
        let rect = selection.intersection(bounds)
        guard !rect.isNull else { return [bounds] }

        var rects: [CGRect] = []

        let topHeight = bounds.maxY - rect.maxY
        if topHeight > 0 {
            rects.append(CGRect(x: bounds.minX, y: rect.maxY, width: bounds.width, height: topHeight))
        }
        let bottomHeight = rect.minY - bounds.minY
        if bottomHeight > 0 {
            rects.append(CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bottomHeight))
        }
        let leftWidth = rect.minX - bounds.minX
        if leftWidth > 0 {
            rects.append(CGRect(x: bounds.minX, y: rect.minY, width: leftWidth, height: rect.height))
        }
        let rightWidth = bounds.maxX - rect.maxX
        if rightWidth > 0 {
            rects.append(CGRect(x: rect.maxX, y: rect.minY, width: rightWidth, height: rect.height))
        }
        return rects
    }
}
