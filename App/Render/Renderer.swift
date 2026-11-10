import CoreImage
import MetalKit
import QuartzCore
import SpencilCore

/// What the last frame drew, so gestures can map screen points back to paper mm.
struct RenderGeometry {
    var viewport: Viewport
    /// Paper mm → content pixels (nil while the paper hasn't been found).
    var paperToContent: Homography?
}

/// Composites camera + reference image with Core Image and draws into an MTKView.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let ci: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    weak var model: DrawingModel?

    let outline = CAShapeLayer()
    let cornerDot = CAShapeLayer()

    init(model: DrawingModel) {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        ci = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        self.model = model
        super.init()
        outline.fillColor = nil
        outline.lineWidth = 2
        outline.lineJoin = .round
        cornerDot.lineWidth = 0
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let model, let frame = model.processor.latest,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }

        let s = model.session
        let paper = s.paper
        let cam = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let camW = Double(CVPixelBufferGetWidth(frame.pixelBuffer))
        let camH = Double(CVPixelBufferGetHeight(frame.pixelBuffer))

        var content = cam
        var contentSize = Vec2(camW, camH)
        var paperToContent = frame.quad.flatMap { Homography(from: paper.corners, to: $0.corners) }
        var isFlat = false

        // Flat view: warp the camera so the paper is straight-on.
        if s.viewMode == .flat, let quad = frame.quad,
           let camToPaper = Homography(from: quad.corners, to: paper.corners) {
            let k = 1600 / paper.longMM  // px per mm
            let (rot, size) = Self.quarterTurn(s.flatRotation, size: Vec2(paper.shortMM * k, paper.longMM * k))
            let p2c = rot * Homography.scale(k, k)
            let camToContent = p2c * camToPaper
            let camCorners = [Vec2(0, 0), Vec2(camW, 0), Vec2(camW, camH), Vec2(0, camH)]
            let mapped = camCorners.compactMap(camToContent.applyChecked)
            if mapped.count == 4 {
                content = Self.warp(cam, to: mapped, contentHeight: size.y)
                contentSize = size
                paperToContent = p2c
                isFlat = true
            }
        }

        if model.overlayVisible, let p2c = paperToContent, let overlay = model.overlayImage {
            let corners = s.placement.corners(imageAspect: s.imageAspect).compactMap(p2c.applyChecked)
            if corners.count == 4 {
                let faded = overlay.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(s.opacity)),
                ])
                content = Self.warp(faded, to: corners, contentHeight: contentSize.y).composited(over: content)
            }
        }
        content = content.cropped(to: CGRect(x: 0, y: 0, width: contentSize.x, height: contentSize.y))

        // Virtual zoom/pan: content → drawable pixels (CI is y-up).
        let viewSize = Vec2(Double(view.bounds.width), Double(view.bounds.height))
        guard viewSize.x > 0, viewSize.y > 0 else { return }
        let dw = Double(view.drawableSize.width), dh = Double(view.drawableSize.height)
        let sf = dw / viewSize.x
        let vp = Viewport(contentSize: contentSize, viewSize: viewSize, zoom: model.zoom, pan: model.pan)
        let S = vp.scale * sf
        let o = vp.origin
        let t = CGAffineTransform(a: S, b: 0, c: 0, d: S, tx: o.x * sf, ty: dh - o.y * sf - contentSize.y * S)
        let bg = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.09)).cropped(to: CGRect(x: 0, y: 0, width: dw, height: dh))
        let final = content.transformed(by: t).composited(over: bg)

        let dest = CIRenderDestination(
            width: Int(dw), height: Int(dh), pixelFormat: view.colorPixelFormat,
            commandBuffer: cb, mtlTextureProvider: { drawable.texture })
        dest.colorSpace = colorSpace
        _ = try? ci.startTask(toRender: final, to: dest)
        cb.present(drawable)
        cb.commit()

        model.geometry = RenderGeometry(viewport: vp, paperToContent: paperToContent)
        updateOutline(view: view, quad: isFlat ? nil : frame.quad, viewport: vp, model: model)
    }

    /// Warps `image` (extent at origin) so its corners land on `pts`
    /// (TL, TR, BR, BL in y-down content coords).
    private static func warp(_ image: CIImage, to pts: [Vec2], contentHeight h: Double) -> CIImage {
        func v(_ p: Vec2) -> CIVector { CIVector(x: p.x, y: h - p.y) }
        return image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": v(pts[0]), "inputTopRight": v(pts[1]),
            "inputBottomRight": v(pts[2]), "inputBottomLeft": v(pts[3]),
        ])
    }

    /// Clockwise quarter turns of a y-down rectangle of `size`.
    static func quarterTurn(_ n: Int, size: Vec2) -> (Homography, Vec2) {
        let w = size.x, h = size.y
        switch ((n % 4) + 4) % 4 {
        case 1: return (Homography(simd_double3x3(rows: [SIMD3(0, -1, h), SIMD3(1, 0, 0), SIMD3(0, 0, 1)])), Vec2(h, w))
        case 2: return (Homography(simd_double3x3(rows: [SIMD3(-1, 0, w), SIMD3(0, -1, h), SIMD3(0, 0, 1)])), size)
        case 3: return (Homography(simd_double3x3(rows: [SIMD3(0, 1, 0), SIMD3(-1, 0, w), SIMD3(0, 0, 1)])), Vec2(h, w))
        default: return (.identity, size)
        }
    }

    private func updateOutline(view: MTKView, quad: Quad?, viewport vp: Viewport, model: DrawingModel) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        outline.frame = view.bounds
        cornerDot.frame = view.bounds
        guard let quad, model.showOutline else {
            outline.path = nil
            cornerDot.path = nil
            return
        }
        let height = Double(view.bounds.height)
        func pt(_ p: Vec2) -> CGPoint {
            let v = vp.toView(p)
            #if os(macOS)
            return CGPoint(x: v.x, y: height - v.y)  // NSView layers are y-up
            #else
            return CGPoint(x: v.x, y: v.y + 0 * height)
            #endif
        }
        let path = CGMutablePath()
        path.addLines(between: quad.corners.map(pt))
        path.closeSubpath()
        outline.path = path
        let color: CGColor = model.status == .tracking
            ? CGColor(red: 0.2, green: 0.85, blue: 0.45, alpha: 0.9)
            : CGColor(red: 1, green: 0.75, blue: 0.1, alpha: 0.9)
        outline.strokeColor = color
        // Dot on the paper's top-left so you can see which way up it thinks the sheet is.
        let c = pt(quad[0])
        cornerDot.path = CGPath(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14), transform: nil)
        cornerDot.fillColor = color
    }
}
