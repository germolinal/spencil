import Foundation
import simd

/// Keeps a stable, consistently-ordered paper quad across frames.
///
/// - Keeps the corner assignment by matching each new detection to the previous quad.
/// - Smooths small jitter heavily, but follows real movement immediately.
/// - Holds the last position when the paper isn't visible (e.g. hand over it).
public final class PaperTracker {
    public enum Status: Equatable, Sendable { case searching, tracking, holding }
    public enum Event: Equatable, Sendable { case none, continued, acquired }

    public private(set) var quad: Quad?
    public private(set) var status: Status = .searching
    public let paper: PaperSize

    /// Seconds without detections before reporting `.holding`.
    public var holdDelay = 0.4
    /// A detection within this fraction of the diagonal counts as the same sheet.
    public var continuityFraction = 0.15

    private var lastSeen = -Double.infinity

    public init(paper: PaperSize) { self.paper = paper }

    @discardableResult
    public func update(detection: Quad?, time: Double) -> Event {
        guard var det = detection, det.isConvex else {
            if quad == nil {
                status = .searching
            } else if time - lastSeen > holdDelay {
                status = .holding
            }
            return .none
        }
        if det.signedArea < 0 { det = det.reversed }
        lastSeen = time

        if let prev = quad {
            var best = det, bestD = Double.infinity
            for k in 0..<4 {
                let c = det.rotated(by: k)
                let d = c.meanCornerDistance(to: prev)
                if d < bestD { bestD = d; best = c }
            }
            if bestD < continuityFraction * prev.diagonal {
                quad = smooth(prev, best)
                status = .tracking
                return .continued
            }
        }
        quad = canonical(det)
        status = .tracking
        return .acquired
    }

    /// The user's "rotate" button: 180° for rectangular paper, 90° for square.
    public func rotate() { rotate(by: paper.isSquare ? 1 : 2) }

    public func rotate(by k: Int) {
        guard let q = quad else { return }
        quad = q.rotated(by: k)
    }

    public func reset() {
        quad = nil
        status = .searching
        lastSeen = -.infinity
    }

    /// Fresh acquisition: short side on top, paper top facing the image top.
    func canonical(_ q: Quad) -> Quad {
        var candidates = (0..<4).map { q.rotated(by: $0) }
        if !paper.isSquare {
            candidates = candidates.filter {
                $0.edgeLength(0) + $0.edgeLength(2) <= $0.edgeLength(1) + $0.edgeLength(3)
            }
        }
        let ctr = q.center
        return candidates.min { a, b in
            ((a[0] + a[1]) / 2 - ctr).y < ((b[0] + b[1]) / 2 - ctr).y
        }!
    }

    private func smooth(_ old: Quad, _ new: Quad) -> Quad {
        let maxD = (0..<4).map { simd_length(new[$0] - old[$0]) }.max()!
        let alpha = maxD < 1.5 ? 0.25 : (maxD < 6 ? 0.6 : 1)
        return Quad((0..<4).map { old[$0] + (new[$0] - old[$0]) * alpha })
    }
}
