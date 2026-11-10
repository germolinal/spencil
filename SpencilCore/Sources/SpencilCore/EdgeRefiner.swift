import Foundation
import simd

/// Read-only view over an 8-bit grayscale plane (e.g. the Y plane of a camera frame).
public struct LumaImage {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let base: UnsafePointer<UInt8>

    public init(width: Int, height: Int, bytesPerRow: Int, base: UnsafePointer<UInt8>) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.base = base
    }

    @inline(__always)
    func px(_ x: Int, _ y: Int) -> Double { Double(base[y * bytesPerRow + x]) }

    /// Bilinear sample, nil outside the image. Pixel `i` covers [i, i+1],
    /// i.e. its centre is at i + 0.5 (same convention as Vision / Core Image).
    @inline(__always)
    public func sample(_ p: Vec2) -> Double? {
        let x = p.x - 0.5, y = p.y - 0.5
        guard x >= 0, y >= 0, x < Double(width - 1), y < Double(height - 1) else { return nil }
        let x0 = Int(x), y0 = Int(y)
        let fx = x - Double(x0), fy = y - Double(y0)
        let a = px(x0, y0), b = px(x0 + 1, y0), c = px(x0, y0 + 1), d = px(x0 + 1, y0 + 1)
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }
}

/// Snaps a rough paper quad onto the real paper edges.
///
/// Each side is fitted as a straight line from many edge samples (RANSAC +
/// least squares), and corners are the intersections of adjacent lines.
/// That means a corner hidden under your hand is still located precisely as
/// long as enough of the two edges meeting there is visible.
public struct EdgeRefiner: Sendable {
    public var samplesPerEdge = 48
    /// Minimum luma step (over 2 px) to count as an edge.
    public var minContrast = 10.0
    public var inlierThreshold = 1.5

    public init() {}

    public struct Result: Sendable {
        public var quad: Quad
        /// Which edges (TL→TR, TR→BR, BR→BL, BL→TL) were actually fitted.
        public var fittedEdges: [Bool]
        public var goodEdges: Int { fittedEdges.filter { $0 }.count }
    }

    private typealias Line = (p: Vec2, d: Vec2)

    public func refine(_ rough: Quad, in img: LumaImage) -> Result? {
        guard rough.isConvex else { return nil }
        let meanEdge = (0..<4).map(rough.edgeLength).reduce(0, +) / 4
        let r1 = min(max(meanEdge * 0.04, 6), 40)
        let bright = paperIsBright(rough, radius: r1, img)
        guard let first = pass(rough, radius: r1, bright: bright, img) else { return nil }
        return pass(first.quad, radius: 4, bright: bright, img) ?? first
    }

    /// Compares luma just inside vs just outside the quad's edges.
    private func paperIsBright(_ q: Quad, radius r: Double, _ img: LumaImage) -> Bool {
        let c = q.center
        var inside = [Double](), outside = [Double]()
        for i in 0..<4 {
            for t in [0.3, 0.5, 0.7] {
                let a = q[i], b = q[i + 1]
                let p = a + (b - a) * t
                let dir = simd_normalize(p - c)
                if let v = img.sample(p - dir * r * 1.5) { inside.append(v) }
                if let v = img.sample(p + dir * r * 1.5) { outside.append(v) }
            }
        }
        guard !inside.isEmpty, !outside.isEmpty else { return true }
        func median(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }
        return median(inside) >= median(outside)
    }

    private func pass(_ q: Quad, radius r: Double, bright: Bool, _ img: LumaImage) -> Result? {
        let c = q.center
        let steps = Int(r.rounded(.up))
        let polarity: Double = bright ? -1 : 1  // bright paper → luma drops going outward
        var lines = [Line]()
        var fitted = [Bool]()

        for i in 0..<4 {
            let a = q[i], b = q[i + 1]
            let e = b - a
            let len = simd_length(e)
            guard len > 10 else { return nil }
            let d = e / len
            var n = Vec2(d.y, -d.x)
            if simd_dot(n, (a + b) / 2 - c) < 0 { n = -n }

            var pts = [Vec2]()
            var prof = [Double](repeating: 0, count: 2 * steps + 3)
            var grad = [Double](repeating: 0, count: prof.count)
            for k in 0..<samplesPerEdge {
                let t = 0.04 + 0.92 * Double(k) / Double(samplesPerEdge - 1)
                let s = a + e * t
                var ok = true
                for j in 0..<prof.count {
                    guard let v = img.sample(s + n * Double(j - steps - 1)) else { ok = false; break }
                    prof[j] = v
                }
                guard ok else { continue }
                var best = 0.0, bestJ = -1
                for j in 1..<(prof.count - 1) {
                    grad[j] = polarity * (prof[j + 1] - prof[j - 1])
                    if grad[j] > best { best = grad[j]; bestJ = j }
                }
                guard bestJ > 1, bestJ < prof.count - 2, best >= minContrast else { continue }
                // Sub-pixel peak via parabola through neighbours.
                let gm = grad[bestJ - 1], g0 = grad[bestJ], gp = grad[bestJ + 1]
                let denom = gm - 2 * g0 + gp
                var delta = 0.0
                if abs(denom) > 1e-9 { delta = max(-0.5, min(0.5, 0.5 * (gm - gp) / denom)) }
                pts.append(s + n * (Double(bestJ - steps - 1) + delta))
            }

            let minInliers = max(6, Int(Double(samplesPerEdge) * 0.3))
            if let line = fitLine(pts, minInliers: minInliers) {
                lines.append(line)
                fitted.append(true)
            } else {
                lines.append((a, d))
                fitted.append(false)
            }
        }

        var corners = [Vec2]()
        for i in 0..<4 {
            guard let p = intersect(lines[(i + 3) % 4], lines[i]) else { return nil }
            corners.append(p)
        }
        let out = Quad(corners)
        guard out.isConvex, (out.signedArea > 0) == (q.signedArea > 0) else { return nil }
        for i in 0..<4 where simd_length(out[i] - q[i]) > max(3 * r, 12) { return nil }
        return Result(quad: out, fittedEdges: fitted)
    }

    private func intersect(_ l1: Line, _ l2: Line) -> Vec2? {
        let den = cross2(l1.d, l2.d)
        guard abs(den) > 1e-6 else { return nil }
        let t = cross2(l2.p - l1.p, l2.d) / den
        return l1.p + l1.d * t
    }

    private func fitLine(_ pts: [Vec2], minInliers: Int) -> Line? {
        guard pts.count >= minInliers else { return nil }
        var rng = SplitMix64(seed: 0x5EED ^ UInt64(pts.count))
        var bestInliers = [Int]()
        for _ in 0..<64 {
            let i = Int(rng.next() % UInt64(pts.count))
            let j = Int(rng.next() % UInt64(pts.count))
            guard i != j else { continue }
            let d = pts[j] - pts[i]
            let l = simd_length(d)
            guard l > 1e-6 else { continue }
            let n = Vec2(-d.y, d.x) / l
            var inl = [Int]()
            for (k, p) in pts.enumerated() where abs(simd_dot(p - pts[i], n)) < inlierThreshold {
                inl.append(k)
            }
            if inl.count > bestInliers.count { bestInliers = inl }
        }
        guard bestInliers.count >= minInliers else { return nil }
        var line = tls(bestInliers.map { pts[$0] })
        let n = Vec2(-line.d.y, line.d.x)
        let again = pts.filter { abs(simd_dot($0 - line.p, n)) < inlierThreshold }
        if again.count >= minInliers { line = tls(again) }
        return line
    }

    /// Total-least-squares line through points.
    private func tls(_ pts: [Vec2]) -> Line {
        let mean = pts.reduce(.zero, +) / Double(pts.count)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in pts {
            let q = p - mean
            sxx += q.x * q.x; sxy += q.x * q.y; syy += q.y * q.y
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        return (mean, Vec2(cos(angle), sin(angle)))
    }
}

/// Small deterministic RNG so refinement is reproducible frame to frame.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
