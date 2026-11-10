import AVFoundation

/// Wraps AVCaptureSession and delivers frames on a background queue.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "spencil.camera.session")
    private let frameQueue = DispatchQueue(label: "spencil.camera.frames", qos: .userInteractive)
    private var currentInput: AVCaptureDeviceInput?

    /// Called on the frame queue.
    var onFrame: ((CVPixelBuffer, Double) -> Void)?

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    static func availableDevices() -> [AVCaptureDevice] {
        #if os(iOS)
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        #else
        let types: [AVCaptureDevice.DeviceType] = [.deskViewCamera, .continuityCamera, .external, .builtInWideAngleCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        #endif
    }

    private static func defaultDevice(_ devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        #if os(iOS)
        return devices.first { $0.deviceType == .builtInWideAngleCamera } ?? devices.first
        #else
        // Desk View gives a top-down view of the desk from an iPhone on the Mac.
        return devices.first { $0.deviceType == .deskViewCamera }
            ?? devices.first { $0.deviceType == .continuityCamera }
            ?? devices.first
        #endif
    }

    /// Switches to the given camera (or the default). Completion runs on an arbitrary queue.
    func configure(deviceID: String?, completion: @escaping @Sendable (String?, String?) -> Void) {
        sessionQueue.async { [self] in
            let devices = Self.availableDevices()
            guard let device = devices.first(where: { $0.uniqueID == deviceID }) ?? Self.defaultDevice(devices) else {
                completion(nil, "No camera found.")
                return
            }
            session.beginConfiguration()
            if let cur = currentInput { session.removeInput(cur) }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw CameraError.cannotAdd }
                session.addInput(input)
                currentInput = input
            } catch {
                session.commitConfiguration()
                completion(nil, "Couldn't open \(device.localizedName): \(error.localizedDescription)")
                return
            }
            if !session.outputs.contains(output) {
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: frameQueue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            } else {
                session.sessionPreset = .high
            }
            #if os(iOS)
            if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) {
                c.videoRotationAngle = 90  // portrait buffers
            }
            #endif
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            completion(device.uniqueID, nil)
        }
    }

    func stop() {
        sessionQueue.async { [session] in session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }

    enum CameraError: Error { case cannotAdd }
}
