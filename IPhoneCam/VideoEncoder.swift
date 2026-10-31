import CoreMedia
import Foundation
import VideoToolbox

struct EncodedFrame {
    let data: Data       // Annex B: cada NAL começa com 00 00 00 01
    let isKeyframe: Bool
    let pts: CMTime      // relativo ao primeiro quadro da conexão
}

/// Encoder de hardware do iPhone (VideoToolbox), ajustado pra atraso baixo:
/// tempo real, sem B-frames (PTS = DTS) e quadro-chave a cada 2 s.
final class VideoEncoder {
    var onOutput: ((EncodedFrame) -> Void)?

    private let session: VTCompressionSession
    private let hevc: Bool

    init?(width: Int32, height: Int32, codec: CMVideoCodecType, fps: Int, bitrate: Int) {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: codec,
                                                encoderSpecification: nil, imageBufferAttributes: nil,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &created)
        guard status == noErr, let created else { return nil }
        session = created
        hevc = codec == kCMVideoCodecType_HEVC

        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 2,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
        ]
        VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    func encode(_ pixels: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool) {
        let options: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self, let frame = AnnexB.frame(from: sample, hevc: self.hevc) else { return }
            self.onOutput?(frame)
        }
    }
}

enum AnnexB {
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    /// O VideoToolbox entrega NALs com prefixo de tamanho (AVCC/HVCC); o PC quer Annex B.
    /// Em quadro-chave, os parameter sets (VPS/SPS/PPS) vão na frente: o PC pode começar dali.
    static func frame(from sample: CMSampleBuffer, hevc: Bool) -> EncodedFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return nil }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        var setCount = 0
        var headerLength: Int32 = 4
        _ = parameterSet(format, hevc: hevc, index: 0, pointer: nil, size: nil, count: &setCount, headerLength: &headerLength)

        var out = Data()
        if isKeyframe {
            for index in 0..<setCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if parameterSet(format, hevc: hevc, index: index, pointer: &pointer, size: &size, count: nil, headerLength: nil) == noErr,
                   let pointer {
                    out.append(contentsOf: startCode)
                    out.append(pointer, count: size)
                }
            }
        }

        let total = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: total)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: &bytes) == noErr else { return nil }

        let prefix = Int(headerLength)
        var offset = 0
        while offset + prefix <= total {
            var length = 0
            for i in 0..<prefix { length = length << 8 | Int(bytes[offset + i]) }
            offset += prefix
            guard length > 0, offset + length <= total else { break }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[offset..<offset + length])
            offset += length
        }
        return EncodedFrame(data: out, isKeyframe: isKeyframe, pts: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    private static func parameterSet(_ format: CMFormatDescription, hevc: Bool, index: Int,
                                     pointer: UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
                                     size: UnsafeMutablePointer<Int>?,
                                     count: UnsafeMutablePointer<Int>?,
                                     headerLength: UnsafeMutablePointer<Int32>?) -> OSStatus {
        if hevc {
            return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                                                                      parameterSetPointerOut: pointer, parameterSetSizeOut: size,
                                                                      parameterSetCountOut: count, nalUnitHeaderLengthOut: headerLength)
        }
        return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                  parameterSetPointerOut: pointer, parameterSetSizeOut: size,
                                                                  parameterSetCountOut: count, nalUnitHeaderLengthOut: headerLength)
    }
}
