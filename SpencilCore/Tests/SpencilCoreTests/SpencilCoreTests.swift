import XCTest
import simd
@testable import SpencilCore

/// Synthetic grayscale frame: dark mat, bright sheet (anti-aliased), optional blobs.
final class SyntheticFrame {
    let width: Int, height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, background: UInt8 = 40) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: background, count: width * height)
    }

    func fillQuad(_ q: Quad, value: Double, background: Double = 40) {
        let xs = q.corners.map(\.x), ys = q.corners.map(\.y)
        let x0 = max(0, Int(xs.min()!) - 1), x1 = min(width - 1, Int(xs.max()!) + 1)
        let y0 = max(0, Int(ys.min()!) - 1), y1 = min(height - 1, Int(ys.max()!) + 1)
        for y in y0...y1 {
            for x in x0...x1 {
                var cov = 0.0
                for sy in 0..<4 { for sx in 0..<4 {
                    let p = Vec2(Double(x) + (Double(sx) + 0.5) / 4, Double(y) + (Double(sy) + 0.5) / 4)
                    if inside(q, p) { cov += 1 / 16 }
                } }
                if cov > 0 {
                    let old = Double(pixels[y * width + x])
                    pixels[y * width + x] = UInt8(old * (1 - cov) + value * cov)
                }
            }
        }
    }

    func fillCircle(center: Vec2, radius: Double, value: UInt8) {
        for y in 0..<height { for x in 0..<width
            where simd_length(Vec2(Double(x), Double(y)) - center) < radius {
            pixels[y * width + x] = value
        } }
    }

    private func inside(_ q: Quad, _ p: Vec2) -> Bool {
        let s = q.signedArea > 0 ? 1.0 : -1.0
        for i in 0..<4 where cross2(q[i + 1] - q[i], p - q[i]) * s < 0 { return false }
        return true
    }

    func withLuma<T>(_ body: (LumaImage) -> T) -> T {
        pixels.withUnsafeBufferPointer {
            body(LumaImage(width: width, height: height, bytesPerRow: width, base: $0.baseAddress!))
        }
    }
}

final class GeometryTests: XCTestCase {
    func testHomographyMapsCornersAndInverts() throws {
        let src = PaperSize.a4.corners
        let dst = [Vec2(100, 80), Vec2(520, 95), Vec2(560, 700), Vec2(70, 680)]
        let h = try XCTUnwrap(Homography(from: src, to: dst))
        for i in 0..<4 { XCTAssertLessThan(simd_length(h.apply(src[i]) - dst[i]), 1e-6) }
        let inv = try XCTUnwrap(h.inverse)
        let p = Vec2(33, 120)
        XCTAssertLessThan(simd_length(inv.apply(h.apply(p)) - p), 1e-6)
        XCTAssertEqual(h.orientationSign(at: Vec2(100, 100)), 1)
    }

    func testViewportRoundTripAndAnchoredZoom() {
        let vp = Viewport(contentSize: Vec2(1080, 1920), viewSize: Vec2(390, 844), zoom: 1, pan: .zero)
        let c = Vec2(500, 900)
        XCTAssertLessThan(simd_length(vp.toContent(vp.toView(c)) - c), 1e-9)
        let anchor = vp.toView(c)
        var z = vp
        z.pan = vp.pan(keeping: c, at: anchor, zoom: 4)
        z.zoom = 4
        XCTAssertLessThan(simd_length(z.toView(c) - anchor), 1e-9)
    }

    func testPlacementFitsInsidePaper() {
        let p = Placement.fitted(paper: .a4, imageAspect: 0.5)
        for c in p.corners(imageAspect: 0.5) {
            XCTAssert(c.x >= 0 && c.x <= 210 && c.y >= 0 && c.y <= 297)
        }
        let r = Placement(centerX: 0, centerY: 0, width: 10, rotationDegrees: 90).corners(imageAspect: 1)
        // Rotating 90° clockwise (y down) sends top-left (-5,-5) to (5,-5).
        XCTAssertLessThan(simd_length(r[0] - Vec2(5, -5)), 1e-9)
    }
}

final class EdgeRefinerTests: XCTestCase {
    let truth = Quad([Vec2(180.3, 90.7), Vec2(470.6, 110.2), Vec2(500.1, 520.4), Vec2(150.8, 500.9)])

    func testRefinesRoughQuadToSubpixel() throws {
        let f = SyntheticFrame(width: 640, height: 640)
        f.fillQuad(truth, value: 225)
        let offsets = [Vec2(7, -5), Vec2(-6, 8), Vec2(5, 6), Vec2(-8, -4)]
        let rough = Quad((0..<4).map { truth[$0] + offsets[$0] })
        let r = try XCTUnwrap(f.withLuma { EdgeRefiner().refine(rough, in: $0) })
        XCTAssertEqual(r.goodEdges, 4)
        for i in 0..<4 { XCTAssertLessThan(simd_length(r.quad[i] - truth[i]), 0.5, "corner \(i)") }
    }

    func testFindsCornerHiddenUnderHand() throws {
        let f = SyntheticFrame(width: 640, height: 640)
        f.fillQuad(truth, value: 225)
        // A skin-toned "hand" sitting right on the bottom-right corner.
        f.fillCircle(center: truth[2] + Vec2(-10, -5), radius: 70, value: 150)
        let r = try XCTUnwrap(f.withLuma { EdgeRefiner().refine(truth.rotated(by: 0), in: $0) })
        XCTAssertGreaterThanOrEqual(r.goodEdges, 3)
        XCTAssertLessThan(simd_length(r.quad[2] - truth[2]), 1.0)
    }

    func testDarkPaperOnLightSurface() throws {
        let f = SyntheticFrame(width: 640, height: 640, background: 210)
        f.fillQuad(truth, value: 30)
        let r = try XCTUnwrap(f.withLuma { EdgeRefiner().refine(truth, in: $0) })
        for i in 0..<4 { XCTAssertLessThan(simd_length(r.quad[i] - truth[i]), 0.5) }
    }
}

final class TrackerTests: XCTestCase {
    // Portrait-ish sheet, slightly tilted.
    let sheet = Quad([Vec2(100, 100), Vec2(310, 110), Vec2(300, 400), Vec2(95, 390)])

    func testCanonicalPutsShortSideOnTop() throws {
        let t = PaperTracker(paper: .a4)
        // Detection arrives with an arbitrary starting corner.
        XCTAssertEqual(t.update(detection: sheet.rotated(by: 3), time: 0), .acquired)
        let q = try XCTUnwrap(t.quad)
        XCTAssertEqual(q[0], sheet[0])
    }

    func testKeepsAssignmentAcrossFramesAndRotates() throws {
        let t = PaperTracker(paper: .a4)
        t.update(detection: sheet, time: 0)
        t.rotate()  // user says it's upside down
        let flipped = try XCTUnwrap(t.quad)
        XCTAssertEqual(flipped[0], sheet[2])
        // New detection comes in with a different order; assignment must stick.
        XCTAssertEqual(t.update(detection: sheet.rotated(by: 1), time: 0.03), .continued)
        XCTAssertLessThan(try XCTUnwrap(t.quad).meanCornerDistance(to: flipped), 1e-9)
    }

    func testHoldsWhenPaperDisappears() {
        let t = PaperTracker(paper: .a4)
        t.update(detection: sheet, time: 0)
        t.update(detection: nil, time: 0.2)
        XCTAssertEqual(t.status, .tracking)
        t.update(detection: nil, time: 1.0)
        XCTAssertEqual(t.status, .holding)
        XCTAssertNotNil(t.quad)
        XCTAssertEqual(t.update(detection: sheet, time: 1.1), .continued)
    }
}

final class SnapshotTests: XCTestCase {
    let sheet = Quad([Vec2(150, 80), Vec2(460, 95), Vec2(480, 540), Vec2(130, 520)])

    func testDetectsUpsideDownSheetFromDrawing() throws {
        let f = SyntheticFrame(width: 640, height: 640)
        f.fillQuad(sheet, value: 225)
        // "Drawing": a couple of marks off-centre.
        f.fillCircle(center: Vec2(230, 180), radius: 30, value: 60)
        f.fillCircle(center: Vec2(380, 300), radius: 12, value: 90)
        let ref = try XCTUnwrap(f.withLuma { PaperSnapshot.capture($0, quad: self.sheet, paper: .a4) })
        // Tracker re-acquired with the wrong orientation:
        let wrong = sheet.rotated(by: 2)
        let k = f.withLuma { PaperSnapshot.bestRotation($0, quad: wrong, paper: .a4, reference: ref) }
        XCTAssertEqual(k, 2)
        let right = f.withLuma { PaperSnapshot.bestRotation($0, quad: self.sheet, paper: .a4, reference: ref) }
        XCTAssertEqual(right, 0)
    }

    func testBlankPaperIsUndecided() throws {
        let f = SyntheticFrame(width: 640, height: 640)
        f.fillQuad(sheet, value: 225)
        let ref = try XCTUnwrap(f.withLuma { PaperSnapshot.capture($0, quad: self.sheet, paper: .a4) })
        XCTAssertNil(f.withLuma { PaperSnapshot.bestRotation($0, quad: self.sheet.rotated(by: 2), paper: .a4, reference: ref) })
    }
}

final class SessionStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(root: dir)
        var s = try store.create(name: "Cat", paper: .a4, imageData: Data([1, 2, 3]), imageAspect: 1.5)
        s.pinned = true
        s.snapshot = [1, 2, 3]
        s.placement.rotationDegrees = 12
        try store.save(s)
        let loaded = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(loaded, s)
        XCTAssertEqual(try Data(contentsOf: store.imageURL(for: loaded)), Data([1, 2, 3]))
        try store.delete(s.id)
        XCTAssertTrue(store.loadAll().isEmpty)
    }
}
