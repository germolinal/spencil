import Foundation
import simd

public typealias Vec2 = SIMD2<Double>

@inlinable
public func cross2(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.y - a.y * b.x }

/// Four corners of the sheet, in image coordinates (pixels, y pointing down).
///
/// Order is always the *paper's own* frame: top-left, top-right, bottom-right,
/// bottom-left, where "top-left → top-right" is the paper's short side
/// (paper is modelled as portrait). Rotating the assignment is how the user
/// fixes an orientation mix-up.
public struct Quad: Equatable, Sendable {
    public var corners: [Vec2]

    public init(_ corners: [Vec2]) {
        precondition(corners.count == 4, "A quad needs exactly 4 corners")
        self.corners = corners
    }

    public subscript(i: Int) -> Vec2 { corners[((i % 4) + 4) % 4] }

    /// Shift the corner assignment: new corner i = old corner i + k.
    public func rotated(by k: Int) -> Quad { Quad((0..<4).map { self[$0 + k] }) }

    /// Reverse winding, keeping corner 0.
    public var reversed: Quad { Quad([corners[0], corners[3], corners[2], corners[1]]) }

    /// Positive for visually clockwise order in y-down coordinates.
    public var signedArea: Double {
        var s = 0.0
        for i in 0..<4 { s += cross2(self[i], self[i + 1]) }
        return s / 2
    }

    public var center: Vec2 { corners.reduce(.zero, +) / 4 }

    public var isConvex: Bool {
        var sign = 0.0
        for i in 0..<4 {
            let c = cross2(self[i + 1] - self[i], self[i + 2] - self[i + 1])
            if abs(c) < 1e-9 { return false }
            if sign == 0 { sign = c } else if sign * c < 0 { return false }
        }
        return true
    }

    public func edgeLength(_ i: Int) -> Double { simd_length(self[i + 1] - self[i]) }

    public var diagonal: Double {
        max(simd_length(self[2] - self[0]), simd_length(self[3] - self[1]))
    }

    public func meanCornerDistance(to other: Quad) -> Double {
        (0..<4).map { simd_length(self[$0] - other[$0]) }.reduce(0, +) / 4
    }
}

/// Planar projective transform (3x3, row-vector convention hidden behind `apply`).
public struct Homography: Sendable {
    public var m: simd_double3x3

    public init(_ m: simd_double3x3) { self.m = m }

    public static let identity = Homography(matrix_identity_double3x3)

    public static func scale(_ sx: Double, _ sy: Double) -> Homography {
        Homography(simd_double3x3(rows: [SIMD3(sx, 0, 0), SIMD3(0, sy, 0), SIMD3(0, 0, 1)]))
    }

    public static func translation(_ tx: Double, _ ty: Double) -> Homography {
        Homography(simd_double3x3(rows: [SIMD3(1, 0, tx), SIMD3(0, 1, ty), SIMD3(0, 0, 1)]))
    }

    /// Exact homography mapping 4 source points onto 4 destination points.
    public init?(from src: [Vec2], to dst: [Vec2]) {
        guard src.count == 4, dst.count == 4 else { return nil }
        var a = [[Double]]()
        for i in 0..<4 {
            let x = src[i].x, y = src[i].y, u = dst[i].x, v = dst[i].y
            a.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
            a.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
        }
        guard let h = Self.solve(a) else { return nil }
        m = simd_double3x3(rows: [
            SIMD3(h[0], h[1], h[2]),
            SIMD3(h[3], h[4], h[5]),
            SIMD3(h[6], h[7], 1),
        ])
    }

    public func apply(_ p: Vec2) -> Vec2 {
        let v = m * SIMD3(p.x, p.y, 1)
        return Vec2(v.x / v.z, v.y / v.z)
    }

    /// Like `apply`, but nil for points that land at/behind the horizon.
    public func applyChecked(_ p: Vec2) -> Vec2? {
        let v = m * SIMD3(p.x, p.y, 1)
        guard v.z > 1e-9 else { return nil }
        return Vec2(v.x / v.z, v.y / v.z)
    }

    public var inverse: Homography? {
        guard abs(m.determinant) > 1e-15 else { return nil }
        return Homography(m.inverse)
    }

    /// `a * b` applies `b` first, then `a`.
    public static func * (a: Homography, b: Homography) -> Homography { Homography(a.m * b.m) }

    /// +1 if the map preserves orientation around `p`, -1 if it mirrors.
    public func orientationSign(at p: Vec2) -> Double {
        let o = apply(p), ex = apply(p + Vec2(1, 0)) - o, ey = apply(p + Vec2(0, 1)) - o
        return cross2(ex, ey) >= 0 ? 1 : -1
    }

    /// Gaussian elimination with partial pivoting on an n x (n+1) augmented matrix.
    private static func solve(_ input: [[Double]]) -> [Double]? {
        var a = input
        let n = a.count
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            for r in 0..<n where r != col {
                let f = a[r][col] / a[col][col]
                if f == 0 { continue }
                for c in col...n { a[r][c] -= f * a[col][c] }
            }
        }
        return (0..<n).map { a[$0][n] / a[$0][$0] }
    }
}

/// Maps "content" (the image being shown: camera frame or flattened paper)
/// into the on-screen view, including the virtual zoom and pan.
public struct Viewport: Sendable {
    public var contentSize: Vec2
    public var viewSize: Vec2
    public var zoom: Double
    public var pan: Vec2

    public init(contentSize: Vec2, viewSize: Vec2, zoom: Double, pan: Vec2) {
        self.contentSize = contentSize
        self.viewSize = viewSize
        self.zoom = zoom
        self.pan = pan
    }

    public var scale: Double {
        min(viewSize.x / contentSize.x, viewSize.y / contentSize.y) * zoom
    }

    public var origin: Vec2 { (viewSize - contentSize * scale) / 2 + pan }

    public func toView(_ p: Vec2) -> Vec2 { origin + p * scale }
    public func toContent(_ p: Vec2) -> Vec2 { (p - origin) / scale }

    /// Pan that keeps `contentPoint` under `viewPoint` at the given zoom.
    public func pan(keeping contentPoint: Vec2, at viewPoint: Vec2, zoom newZoom: Double) -> Vec2 {
        var v = self
        v.zoom = newZoom
        v.pan = .zero
        let s = v.scale
        return viewPoint - contentPoint * s - (viewSize - contentSize * s) / 2
    }
}
