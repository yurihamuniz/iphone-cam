import AVFoundation
import Foundation

enum Resolution: String, CaseIterable, Identifiable {
    case fullHD = "1080p"
    case uhd = "4K"

    var id: Self { self }
    var width: Int32 { self == .fullHD ? 1920 : 3840 }
    var height: Int32 { self == .fullHD ? 1080 : 2160 }
    /// Perto do que o app Câmera usa e bem abaixo do que o cabo aguenta.
    var bitrate: Int { self == .fullHD ? 20_000_000 : 60_000_000 }
}

enum Codec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC"

    var id: Self { self }
    var type: CMVideoCodecType { self == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC }
    var wireName: String { self == .h264 ? "h264" : "hevc" }
}

struct StreamConfig: Equatable {
    var resolution = Resolution.fullHD
    var codec = Codec.hevc
    var fps = 30
}

/// Câmera traseira → encoder de hardware → servidor TCP. Só codifica com o PC conectado.
final class CameraController: NSObject, ObservableObject {
    @Published var config = StreamConfig() {
        didSet { if config != oldValue { apply(config) } }
    }
    @Published private(set) var status = "Iniciando"
    @Published private(set) var stats = ""

    let session = AVCaptureSession()
    private let server = StreamServer()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "camera.capture")

    // Só mexidos na captureQueue.
    private var applied = StreamConfig()
    private var encoder: VideoEncoder?
    private var firstPTS: CMTime?
    private var keyframeRequested = true

    func start() {
        let waiting = "Aguardando o PC na porta \(StreamServer.port)"
        server.onError = { [weak self] message in self?.publish(status: message) }
        server.onClientChange = { [weak self] connected in
            guard let self else { return }
            self.captureQueue.async {
                self.firstPTS = nil
                self.keyframeRequested = true
                if connected { self.server.sendConfig(Packet.config(self.applied)) }
            }
            self.publish(status: connected ? "Enviando pro PC" : waiting)
            if !connected { DispatchQueue.main.async { self.stats = "" } }
        }
        server.onKeyframeNeeded = { [weak self] in
            self?.captureQueue.async { self?.keyframeRequested = true }
        }
        server.onStats = { [weak self] fps, mbps in
            DispatchQueue.main.async { self?.stats = String(format: "%.1f fps · %.1f Mbps", fps, mbps) }
        }

        do {
            try server.start()
            publish(status: waiting)
        } catch {
            publish(status: "Não abriu a porta \(StreamServer.port): \(error.localizedDescription)")
        }

        let initial = config
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.publish(status: "Sem permissão de câmera (Ajustes > iPhone Cam)")
                return
            }
            self.captureQueue.async {
                self.configure(initial)
                self.session.startRunning()
            }
        }
    }

    private func apply(_ config: StreamConfig) {
        captureQueue.async { self.configure(config) }
    }

    /// Roda na captureQueue.
    private func configure(_ config: StreamConfig) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.inputs.isEmpty {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                publish(status: "Câmera indisponível")
                return
            }
            session.addInput(input)
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: captureQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }

        guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
        guard let format = Self.format(for: device, width: config.resolution.width, height: config.resolution.height, fps: config.fps) else {
            publish(status: "\(config.resolution.rawValue) a \(config.fps) fps não existe neste iPhone")
            return
        }

        session.sessionPreset = .inputPriority
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let frame = CMTime(value: 1, timescale: CMTimeScale(config.fps))
            device.activeVideoMinFrameDuration = frame
            device.activeVideoMaxFrameDuration = frame
            device.unlockForConfiguration()
        } catch {
            publish(status: "Não travou a câmera: \(error.localizedDescription)")
            return
        }

        // Estabilização segura quadros e soma atraso.
        if let connection = output.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }

        encoder = nil
        guard let encoder = VideoEncoder(width: config.resolution.width, height: config.resolution.height,
                                         codec: config.codec.type, fps: config.fps, bitrate: config.resolution.bitrate) else {
            publish(status: "\(config.codec.rawValue) não suportado neste iPhone")
            return
        }
        encoder.onOutput = { [weak self] frame in
            self?.server.sendVideo(Packet.video(frame), keyframe: frame.isKeyframe)
        }
        self.encoder = encoder
        applied = config
        firstPTS = nil
        keyframeRequested = true
        if server.hasClient { server.sendConfig(Packet.config(config)) }
    }

    /// Primeiro formato 8 bits com o tamanho e o fps pedidos.
    private static func format(for device: AVCaptureDevice, width: Int32, height: Int32, fps: Int) -> AVCaptureDevice.Format? {
        device.formats.first { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixel = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let is8bit = pixel == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || pixel == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            return size.width == width && size.height == height && is8bit
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(fps) }
        }
    }

    private func publish(status: String) {
        DispatchQueue.main.async { self.status = status }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard server.hasClient, let encoder, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let start = firstPTS ?? pts
        firstPTS = start
        encoder.encode(pixels, pts: CMTimeSubtract(pts, start), forceKeyframe: keyframeRequested)
        keyframeRequested = false
    }
}
