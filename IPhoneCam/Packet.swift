import CoreMedia
import Foundation

/// Formato do que vai pelo cabo. Especificação em `protocolo.md`.
enum Packet {
    static let magic = Data("IPCM".utf8)

    static let commandType: UInt8 = 3
    /// Comando é JSON curto; mais que isso é lixo na conexão.
    private static let maxCommandBytes = 64 * 1024

    static func config(_ config: StreamConfig) -> Data {
        let json: [String: Any] = [
            "proto": 2,
            "codec": config.codec.wireName,
            "width": Int(config.resolution.width),
            "height": Int(config.resolution.height),
            "fps": config.fps,
            "bitrate": config.resolution.bitrate,
        ]
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        return frame(type: 1, flags: 0, pts: 0, body)
    }

    static func video(_ frame: EncodedFrame) -> Data {
        let micros = CMTimeConvertScale(frame.pts, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
        return self.frame(type: 2, flags: frame.isKeyframe ? 1 : 0, pts: micros, frame.data)
    }

    /// Tira de `buffer` os pacotes completos que o PC mandou e devolve os comandos (tipo 3) em JSON.
    /// O que ainda não chegou inteiro fica no buffer pra próxima leitura.
    static func commands(from buffer: inout Data) -> [[String: Any]] {
        var commands: [[String: Any]] = []
        while buffer.count >= 16 {
            let start = buffer.startIndex
            let size = buffer[start + 4 ..< start + 8].reduce(0) { $0 << 8 | Int($1) }
            guard size <= maxCommandBytes else {
                buffer.removeAll()
                break
            }
            guard buffer.count >= 16 + size else { break }
            let type = buffer[start]
            let body = buffer.subdata(in: start + 16 ..< start + 16 + size)
            buffer.removeSubrange(start ..< start + 16 + size)
            if type == commandType, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                commands.append(json)
            }
        }
        return commands
    }

    /// Cabeçalho de 16 bytes, big-endian: tipo, flags, 2 reservados, tamanho (u32), pts em µs (i64).
    private static func frame(type: UInt8, flags: UInt8, pts: Int64, _ body: Data) -> Data {
        var data = Data(capacity: 16 + body.count)
        data.append(type)
        data.append(flags)
        data.append(contentsOf: [0, 0])
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: pts.bigEndian) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }
}
