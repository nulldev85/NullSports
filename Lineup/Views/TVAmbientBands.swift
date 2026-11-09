import Foundation

/// Geometry in the full-screen host's coordinates. The player first fits the
/// movie inside its fixed drawable, then fits that drawable inside the host.
struct TVAmbientBands: Equatable {
    let horizontal: Bool
    let first: CGRect
    let second: CGRect

    init?(video: CGSize, drawable: CGSize, host: CGSize) {
        guard [video, drawable, host].allSatisfy({
            $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
        }) else { return nil }
        let scale = min(host.width / drawable.width, host.height / drawable.height)
        let canvas = CGSize(width: drawable.width * scale, height: drawable.height * scale)
        let origin = CGPoint(x: (host.width - canvas.width) / 2, y: (host.height - canvas.height) / 2)
        let fit = min(canvas.width / video.width, canvas.height / video.height)
        let picture = CGSize(width: video.width * fit, height: video.height * fit)
        let side = (canvas.width - picture.width) / 2
        let end = (canvas.height - picture.height) / 2
        horizontal = end > side
        let depth = floor((horizontal ? end : side) / 2)
        guard depth >= 1 else { return nil }
        if horizontal {
            first = CGRect(x: origin.x, y: floor(origin.y + end) - depth, width: canvas.width, height: depth)
            second = CGRect(x: origin.x, y: ceil(origin.y + canvas.height - end), width: canvas.width, height: depth)
        } else {
            first = CGRect(x: floor(origin.x + side) - depth, y: origin.y, width: depth, height: canvas.height)
            second = CGRect(x: ceil(origin.x + canvas.width - side), y: origin.y, width: depth, height: canvas.height)
        }
    }
}
