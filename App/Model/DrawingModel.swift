import CoreImage
import Foundation
import Observation
import SpencilCore
import SwiftUI

struct CameraOption: Identifiable, Hashable {
    let id: String
    let name: String
}

/// State for one open drawing: camera, tracking, placement, virtual zoom.
@Observable
@MainActor
final class DrawingModel {
    var session: Session {
        didSet { scheduleSave() }
    }

    // View-only state (not saved)
    var overlayVisible = true
    var zoom = 1.0
    var pan = Vec2.zero
    var status: PaperTracker.Status = .searching
    var cameraOptions: [CameraOption] = []
    var selectedCamera: String?
    var cameraError: String?
    var toast: String?

    var showOutline: Bool { !session.pinned || status != .tracking }

    @ObservationIgnored let processor: FrameProcessor
    @ObservationIgnored private let camera = CameraController()
    @ObservationIgnored private let library: Library
    @ObservationIgnored private let photo: CIImage?
    @ObservationIgnored private var lineArt: CIImage?
    /// Set by the renderer every frame.
    @ObservationIgnored var geometry: RenderGeometry?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    // Gesture bookkeeping
    @ObservationIgnored private var lastDrag: CGPoint?
    @ObservationIgnored private var magnifyStart: (zoom: Double, width: Double, anchor: Vec2)?
    @ObservationIgnored private var rotateStart: Double?

    private static let cameraKey = "spencil.lastCamera"

    init(session: Session, library: Library) {
        self.session = session
        self.library = library
        processor = FrameProcessor(paper: session.paper, reference: session.snapshot)
        photo = ImageLoader.cgImage(url: library.imageURL(for: session), maxPixel: 2048).map { CIImage(cgImage: $0) }
        selectedCamera = UserDefaults.standard.string(forKey: Self.cameraKey)
        if session.lineArt { buildLineArt() }
    }

    var hasReferenceImage: Bool { photo != nil }

    var overlayImage: CIImage? { session.lineArt ? (lineArt ?? photo) : photo }

    // MARK: Lifecycle

    func start() async {
        guard await CameraController.requestAccess() else {
            cameraError = "Camera access is off. Enable it in Settings to see your paper."
            return
        }
        cameraOptions = CameraController.availableDevices().map { CameraOption(id: $0.uniqueID, name: $0.localizedName) }
        processor.onStatus = { [weak self] s in Task { @MainActor in self?.status = s } }
        processor.onSnapshot = { [weak self] snap in Task { @MainActor in self?.session.snapshot = snap } }
        processor.onAutoRotated = { [weak self] in
            Task { @MainActor in self?.showToast("Turned the paper to match your drawing") }
        }
        camera.onFrame = { [processor] pb, t in processor.process(pb, time: t) }
        selectCamera(selectedCamera)
    }

    func stop() {
        camera.stop()
        saveNow()
    }

    func selectCamera(_ id: String?) {
        camera.configure(deviceID: id) { [weak self] chosen, error in
            Task { @MainActor in
                guard let self else { return }
                self.cameraError = error
                if let chosen {
                    self.selectedCamera = chosen
                    UserDefaults.standard.set(chosen, forKey: Self.cameraKey)
                }
            }
        }
    }

    // MARK: Actions

    func rotatePaper() { processor.rotate() }

    func setPinned(_ pinned: Bool) {
        session.pinned = pinned
        resetZoom()
    }

    func setViewMode(_ mode: ViewMode) {
        session.viewMode = mode
        resetZoom()
    }

    func rotateFlatView() {
        session.flatRotation = (session.flatRotation + 1) % 4
        resetZoom()
    }

    func setLineArt(_ on: Bool) {
        session.lineArt = on
        if on, lineArt == nil { buildLineArt() }
    }

    func fitImageToPaper() {
        session.placement = .fitted(paper: session.paper, imageAspect: session.imageAspect)
    }

    func resetZoom() {
        zoom = 1
        pan = .zero
    }

    func zoom(by factor: Double) {
        guard let vp = geometry?.viewport else { return }
        let center = vp.viewSize / 2
        let c = vp.toContent(center)
        let z = clampZoom(zoom * factor)
        pan = vp.pan(keeping: c, at: center, zoom: z)
        zoom = z
    }

    // MARK: Gestures
    //
    // While placing: gestures move/scale/rotate the image *on the paper*.
    // While pinned (drawing): gestures only zoom/pan the view.

    func dragChanged(start: CGPoint, location: CGPoint) {
        guard magnifyStart == nil else { lastDrag = location; return }
        let from = lastDrag ?? start
        lastDrag = location
        if session.pinned {
            pan += Vec2(location.x - from.x, location.y - from.y)
        } else if let a = paperPoint(from), let b = paperPoint(location) {
            session.placement.centerX += b.x - a.x
            session.placement.centerY += b.y - a.y
        }
    }

    func dragEnded() { lastDrag = nil }

    func magnifyChanged(_ scale: Double, anchor: CGPoint) {
        guard let vp = geometry?.viewport else { return }
        if magnifyStart == nil {
            magnifyStart = (zoom, session.placement.width, vp.toContent(Vec2(anchor.x, anchor.y)))
        }
        guard let start = magnifyStart else { return }
        if session.pinned {
            let z = clampZoom(start.zoom * scale)
            pan = vp.pan(keeping: start.anchor, at: Vec2(anchor.x, anchor.y), zoom: z)
            zoom = z
        } else {
            session.placement.width = max(5, min(session.paper.longMM * 3, start.width * scale))
        }
    }

    func magnifyEnded() { magnifyStart = nil }

    func rotateChanged(_ degrees: Double) {
        guard !session.pinned else { return }
        if rotateStart == nil { rotateStart = session.placement.rotationDegrees }
        let c = Vec2(session.placement.centerX, session.placement.centerY)
        let sign = geometry?.paperToContent?.orientationSign(at: c) ?? 1
        session.placement.rotationDegrees = (rotateStart ?? 0) + degrees * sign
    }

    func rotateEnded() { rotateStart = nil }

    private func paperPoint(_ p: CGPoint) -> Vec2? {
        guard let g = geometry, let inv = g.paperToContent?.inverse else { return nil }
        return inv.applyChecked(g.viewport.toContent(Vec2(p.x, p.y)))
    }

    private func clampZoom(_ z: Double) -> Double { max(1, min(16, z)) }

    // MARK: Helpers

    private func buildLineArt() {
        guard let photo else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let lines = photo.applyingFilter("CILineOverlay", parameters: [
                "inputNRNoiseLevel": 0.07, "inputNRSharpness": 0.71,
                "inputEdgeIntensity": 1.0, "inputThreshold": 0.1, "inputContrast": 50.0,
            ]).cropped(to: photo.extent)
            // Render once so the filter doesn't re-run every frame.
            let ctx = CIContext()
            guard let cg = ctx.createCGImage(lines, from: photo.extent) else { return }
            let image = CIImage(cgImage: cg)
            await MainActor.run { self?.lineArt = image }
        }
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { self?.saveNow() }
        }
    }

    func saveNow() {
        saveTask?.cancel()
        library.save(session)
    }
}
