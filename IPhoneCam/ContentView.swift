import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                Text(camera.status).font(.headline)
                if !camera.stats.isEmpty {
                    Text(camera.stats).font(.caption.monospacedDigit())
                }
                HStack {
                    Picker("Resolução", selection: $camera.config.resolution) {
                        ForEach(Resolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Codec", selection: $camera.config.codec) {
                        ForEach(Codec.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("FPS", selection: $camera.config.fps) {
                        ForEach([30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 640)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        }
        .statusBarHidden()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            camera.start()
        }
    }
}

/// Prévia da câmera. Só pra enquadrar: o que vai pro PC sai do encoder, não daqui.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            // A tela fica travada em paisagem (porta do cabo à direita), igual ao sensor.
            guard let connection = previewLayer.connection else { return }
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .landscapeRight
            }
        }
    }
}
