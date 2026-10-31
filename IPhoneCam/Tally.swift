import AVFoundation
import Foundation

enum LightMode: String, CaseIterable, Identifiable {
    case fixa, piscar, desligada

    var id: Self { self }
    var label: String {
        switch self {
        case .fixa: return "Luz fixa"
        case .piscar: return "Piscar"
        case .desligada: return "Sem luz"
        }
    }
}

/// Luz de gravação no flash traseiro: com a câmera traseira, é o lado virado pra quem grava
/// (talking head), o único que tem como acender alguma coisa.
/// Nível baixo de propósito: o flash fica ao lado da lente e ilumina o rosto.
/// Só mexida na fila da câmera.
final class Tally {
    private static let steadyLevel: Float = 0.05
    private static let pulseLevel: Float = 0.3
    private static let pulseLength = 0.12
    private static let pulseEvery = 1.5

    private let queue: DispatchQueue
    private var device: AVCaptureDevice?
    private var active = false
    private var mode = LightMode.fixa
    private var timer: DispatchSourceTimer?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Trocar o formato da câmera pode apagar a luz: chamar de novo depois de configurar.
    func set(device: AVCaptureDevice?) {
        self.device = device
        refresh()
    }

    func set(active: Bool) {
        self.active = active
        refresh()
    }

    func set(mode: LightMode) {
        self.mode = mode
        refresh()
    }

    private func refresh() {
        timer?.cancel()
        timer = nil
        guard active, mode != .desligada else {
            torch(nil)
            return
        }
        guard mode == .piscar else {
            torch(Self.steadyLevel)
            return
        }
        torch(nil)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.pulseEvery)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.torch(Self.pulseLevel)
            self.queue.asyncAfter(deadline: .now() + Self.pulseLength) { [weak self] in
                guard let self, self.active, self.mode == .piscar else { return }
                self.torch(nil)
            }
        }
        timer.resume()
        self.timer = timer
    }

    /// `nil` apaga.
    private func torch(_ level: Float?) {
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if let level, device.isTorchModeSupported(.on), device.isTorchAvailable {
                try device.setTorchModeOn(level: level)
            } else if device.torchMode != .off {
                device.torchMode = .off
            }
        } catch {
            // Sem luz não impede a gravação; o REC na tela e no PC continuam valendo.
        }
    }
}
