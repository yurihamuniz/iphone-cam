import Foundation
import Network

/// Servidor TCP só no loopback do iPhone. O PC chega aqui pelo cabo: o usbmux (Apple Mobile Device
/// Service no Windows) abre a conexão em 127.0.0.1:7878 do lado do iPhone. Pela Wi-Fi a porta não existe.
/// Um PC por vez: conexão nova derruba a anterior.
final class StreamServer {
    static let port: UInt16 = 7878
    /// Mais que isso esperando o cabo é atraso acumulando: descarta até o próximo quadro-chave.
    private static let maxPendingBytes = 8 * 1024 * 1024

    var onClientChange: ((Bool) -> Void)?
    var onKeyframeNeeded: (() -> Void)?
    var onStats: ((_ fps: Double, _ mbps: Double) -> Void)?
    var onError: ((String) -> Void)?
    /// Comando do PC (protocolo, tipo 3). Chega na fila do servidor.
    var onCommand: (([String: Any]) -> Void)?

    private let queue = DispatchQueue(label: "stream.server")
    private let lock = NSLock()
    private var clientFlag = false

    // Só mexidos na queue.
    private var listener: NWListener?
    private var connection: NWConnection?
    private var pendingBytes = 0
    private var incoming = Data()
    private var waitingForKeyframe = true
    private var statFrames = 0
    private var statBytes = 0
    private var statStart = Date()

    var hasClient: Bool {
        lock.lock()
        defer { lock.unlock() }
        return clientFlag
    }

    func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: StreamServer.port)!)

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.onError?("Porta \(StreamServer.port) caiu: \(error)") }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func sendConfig(_ packet: Data) {
        queue.async { self.write(packet) }
    }

    func sendVideo(_ packet: Data, keyframe: Bool) {
        queue.async {
            guard self.connection != nil else { return }
            if self.waitingForKeyframe && !keyframe { return }
            if self.pendingBytes > StreamServer.maxPendingBytes {
                if !self.waitingForKeyframe {
                    self.waitingForKeyframe = true
                    self.onKeyframeNeeded?()
                }
                return
            }
            self.waitingForKeyframe = false
            self.write(packet)
            self.count(packet.count)
        }
    }

    private func accept(_ newConnection: NWConnection) {
        connection?.cancel()
        connection = newConnection
        pendingBytes = 0
        incoming.removeAll()
        waitingForKeyframe = true

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection, self.connection === newConnection else { return }
            switch state {
            case .ready:
                newConnection.send(content: Packet.magic, completion: .idempotent)
                self.receive(on: newConnection)
                self.setClient(true)
            case .failed, .cancelled:
                self.connection = nil
                self.setClient(false)
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    /// Lê os comandos do PC e nota quando ele fecha.
    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty, self.connection === connection {
                self.incoming.append(data)
                for command in Packet.commands(from: &self.incoming) { self.onCommand?(command) }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection)
        }
    }

    private func write(_ packet: Data) {
        guard let connection else { return }
        pendingBytes += packet.count
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self, self.connection === connection else { return }
            self.pendingBytes -= packet.count
            if error != nil { connection.cancel() }
        })
    }

    private func count(_ bytes: Int) {
        statFrames += 1
        statBytes += bytes
        let elapsed = Date().timeIntervalSince(statStart)
        guard elapsed >= 1 else { return }
        onStats?(Double(statFrames) / elapsed, Double(statBytes * 8) / elapsed / 1_000_000)
        statFrames = 0
        statBytes = 0
        statStart = Date()
    }

    private func setClient(_ connected: Bool) {
        lock.lock()
        clientFlag = connected
        lock.unlock()
        onClientChange?(connected)
    }
}
