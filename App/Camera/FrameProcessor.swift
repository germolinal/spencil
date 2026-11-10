import CoreVideo
import Foundation
import SpencilCore
import Vision

/// Runs on the camera queue: finds the paper in each frame and keeps the
/// latest (frame, quad) pair for the renderer.
///
/// Strategy per frame:
/// 1. If we already know where the paper is, refine edges starting from there
///    (cheap, precise, survives a hand over one edge).
/// 2. Otherwise ask Vision's document detector for a rough quad, then refine.
final class FrameProcessor: @unchecked Sendable {
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let quad: Quad?
    }

    private let lock = NSLock()
    private var _latest: Frame?
    private var reference: [UInt8]?
    private var pendingRotation = 0

    private let paper: PaperSize
    private let tracker: PaperTracker
    private let refiner = EdgeRefiner()
    private let request = VNDetectDocumentSegmentationRequest()
    private var lastStatus: PaperTracker.Status = .searching
    private var lastSnapshotTime = 0.0
    private var noSnapshotUntil = 0.0

    var onStatus: ((PaperTracker.Status) -> Void)?
    var onSnapshot: (([UInt8]) -> Void)?
    var onAutoRotated: (() -> Void)?

    init(paper: PaperSize, reference: [UInt8]?) {
        self.paper = paper
        self.tracker = PaperTracker(paper: paper)
        self.reference = reference
    }

    var latest: Frame? { lock.withLock { _latest } }

    /// User tapped "rotate paper".
    func rotate() { lock.withLock { pendingRotation += 1 } }

    func process(_ pb: CVPixelBuffer, time: Double) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pb) >= 1,
              let raw = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let luma = LumaImage(
            width: CVPixelBufferGetWidthOfPlane(pb, 0),
            height: CVPixelBufferGetHeightOfPlane(pb, 0),
            bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
            base: UnsafePointer(raw.assumingMemoryBound(to: UInt8.self))
        )
        let (rotations, ref) = lock.withLock { () -> (Int, [UInt8]?) in
            defer { pendingRotation = 0 }
            return (pendingRotation, reference)
        }
        for _ in 0..<rotations { tracker.rotate() }
        if rotations > 0 { noSnapshotUntil = time + 4 }

        var detection: Quad?
        if let prev = tracker.quad, tracker.status != .searching,
           let r = refiner.refine(prev, in: luma), r.goodEdges >= 3 {
            detection = r.quad
        }
        if detection == nil, let rough = detectWithVision(pb, width: luma.width, height: luma.height) {
            if let r = refiner.refine(rough, in: luma), r.goodEdges >= 2 {
                detection = r.quad
            } else {
                detection = rough
            }
        }

        let event = tracker.update(detection: detection, time: time)
        if event == .acquired {
            noSnapshotUntil = time + 4
            if let ref, let q = tracker.quad,
               let k = PaperSnapshot.bestRotation(luma, quad: q, paper: paper, reference: ref), k != 0 {
                tracker.rotate(by: k)
                onAutoRotated?()
            }
        }

        if tracker.status == .tracking, time >= noSnapshotUntil, time - lastSnapshotTime > 5,
           let q = tracker.quad, let snap = PaperSnapshot.capture(luma, quad: q, paper: paper) {
            lastSnapshotTime = time
            lock.withLock { reference = snap }
            onSnapshot?(snap)
        }

        if tracker.status != lastStatus {
            lastStatus = tracker.status
            onStatus?(lastStatus)
        }
        let frame = Frame(pixelBuffer: pb, quad: tracker.quad)
        lock.withLock { _latest = frame }
    }

    private func detectWithVision(_ pb: CVPixelBuffer, width: Int, height: Int) -> Quad? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up)
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first, obs.confidence > 0.5 else { return nil }
        let w = Double(width), h = Double(height)
        // Vision: normalized, origin bottom-left → pixels, origin top-left.
        func px(_ p: CGPoint) -> Vec2 { Vec2(Double(p.x) * w, (1 - Double(p.y)) * h) }
        let q = Quad([px(obs.topLeft), px(obs.topRight), px(obs.bottomRight), px(obs.bottomLeft)])
        guard q.isConvex, abs(q.signedArea) > 0.03 * w * h else { return nil }
        return q
    }
}
