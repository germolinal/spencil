import MetalKit
import SwiftUI

#if os(iOS)
typealias PlatformViewRepresentable = UIViewRepresentable
#else
typealias PlatformViewRepresentable = NSViewRepresentable
#endif

struct MetalView: PlatformViewRepresentable {
    let model: DrawingModel

    func makeCoordinator() -> Renderer { Renderer(model: model) }

    private func makeView(_ renderer: Renderer) -> MTKView {
        let v = MTKView(frame: .zero, device: renderer.device)
        v.delegate = renderer
        v.framebufferOnly = false
        v.colorPixelFormat = .bgra8Unorm
        v.preferredFramesPerSecond = 60
        v.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        #if os(macOS)
        v.wantsLayer = true
        let host = v.layer!
        #else
        let host = v.layer
        #endif
        host.addSublayer(renderer.outline)
        host.addSublayer(renderer.cornerDot)
        return v
    }

    #if os(iOS)
    func makeUIView(context: Context) -> MTKView { makeView(context.coordinator) }
    func updateUIView(_ view: MTKView, context: Context) {}
    #else
    func makeNSView(context: Context) -> MTKView { makeView(context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) {}
    #endif
}

