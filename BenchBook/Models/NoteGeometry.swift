import CoreGraphics

/// Converts note boxes between stored fractions (0...1 of the image) and
/// image pixels, and works out what a click hits.
nonisolated enum NoteGeometry {
    /// Boxes smaller than this, in image pixels, are treated as accidental clicks.
    static let minimumSide: CGFloat = 8

    enum Handle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Fractions → pixel rect in an image of `imageSize` (top-left origin).
    static func pixelRect(x: Double, y: Double, width: Double, height: Double, in imageSize: CGSize) -> CGRect {
        CGRect(
            x: x * imageSize.width,
            y: y * imageSize.height,
            width: width * imageSize.width,
            height: height * imageSize.height
        )
    }

    /// Pixel rect → fractions, clamped so the box stays inside the image.
    static func fractions(of rect: CGRect, in imageSize: CGSize) -> (x: Double, y: Double, width: Double, height: Double) {
        let clamped = clamp(rect, to: imageSize)
        guard imageSize.width > 0, imageSize.height > 0 else { return (0, 0, 0, 0) }
        return (
            clamped.minX / imageSize.width,
            clamped.minY / imageSize.height,
            clamped.width / imageSize.width,
            clamped.height / imageSize.height
        )
    }

    /// Keeps `rect` within the image, preserving its size where possible.
    static func clamp(_ rect: CGRect, to imageSize: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: imageSize)
        var r = rect.standardized
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, 0), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, 0), bounds.maxY - r.height)
        return r
    }

    /// The rect spanned by a drag from `start` to `end`, limited to the image.
    static func rect(from start: CGPoint, to end: CGPoint, in imageSize: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: imageSize)
        func inside(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
        }
        let a = inside(start), b = inside(end)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func isLargeEnough(_ rect: CGRect) -> Bool {
        rect.width >= minimumSide && rect.height >= minimumSide
    }

    static func point(of handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// The handle within `tolerance` of `point`, if any.
    static func handle(at point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> Handle? {
        Handle.allCases.first { handle in
            let p = self.point(of: handle, in: rect)
            return abs(p.x - point.x) <= tolerance && abs(p.y - point.y) <= tolerance
        }
    }

    /// `rect` with `handle` dragged to `point`; the opposite corner stays put.
    static func resize(_ rect: CGRect, moving handle: Handle, to point: CGPoint, in imageSize: CGSize) -> CGRect {
        let anchor: CGPoint = switch handle {
        case .topLeft: CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: CGPoint(x: rect.minX, y: rect.minY)
        }
        return self.rect(from: anchor, to: point, in: imageSize)
    }
}
