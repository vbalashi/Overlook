import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

enum DirectH264VideoDecoderError: Error, CustomStringConvertible {
    case missingParameterSets
    case formatDescriptionFailed(OSStatus)
    case decompressionSessionFailed(OSStatus)
    case blockBufferFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
    case decodeFailed(OSStatus)
    case noOutputFrame
    case emptyAccessUnit

    var description: String {
        switch self {
        case .missingParameterSets:
            return "missing SPS/PPS parameter sets"
        case .formatDescriptionFailed(let status):
            return "CMVideoFormatDescriptionCreateFromH264ParameterSets failed status=\(status)"
        case .decompressionSessionFailed(let status):
            return "VTDecompressionSessionCreate failed status=\(status)"
        case .blockBufferFailed(let status):
            return "CMBlockBuffer operation failed status=\(status)"
        case .sampleBufferFailed(let status):
            return "CMSampleBufferCreateReady failed status=\(status)"
        case .decodeFailed(let status):
            return "VTDecompressionSessionDecodeFrame failed status=\(status)"
        case .noOutputFrame:
            return "decoder produced no output frame"
        case .emptyAccessUnit:
            return "empty access unit"
        }
    }
}

final class DirectH264VideoDecoder {
    private final class DecodeContext {
        var status: OSStatus = noErr
        var infoFlags = VTDecodeInfoFlags()
        var imageBuffer: CVImageBuffer?
    }

    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var currentSPS: Data?
    private var currentPPS: Data?
    private var frameIndex: Int64 = 0

    deinit {
        reset()
    }

    func reset() {
        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
        formatDescription = nil
        currentSPS = nil
        currentPPS = nil
        frameIndex = 0
    }

    func decode(_ accessUnit: DirectH264AccessUnit) throws -> CVPixelBuffer {
        guard let sps = accessUnit.sps, let pps = accessUnit.pps else {
            throw DirectH264VideoDecoderError.missingParameterSets
        }

        try configureIfNeeded(sps: sps, pps: pps)
        guard let decompressionSession, let formatDescription else {
            throw DirectH264VideoDecoderError.missingParameterSets
        }

        let avcc = try Self.avccAccessUnit(fromAnnexB: accessUnit.data)
        let sampleBuffer = try Self.sampleBuffer(
            avccAccessUnit: avcc,
            formatDescription: formatDescription,
            presentationTimestamp: CMTime(value: frameIndex, timescale: 60)
        )
        frameIndex += 1

        let context = DecodeContext()
        let contextPointer = Unmanaged.passUnretained(context).toOpaque()
        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: contextPointer,
            infoFlagsOut: nil
        )
        guard status == noErr else {
            throw DirectH264VideoDecoderError.decodeFailed(status)
        }

        VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)

        guard context.status == noErr else {
            throw DirectH264VideoDecoderError.decodeFailed(context.status)
        }
        guard let imageBuffer = context.imageBuffer else {
            throw DirectH264VideoDecoderError.noOutputFrame
        }

        return imageBuffer
    }

    private func configureIfNeeded(sps: Data, pps: Data) throws {
        guard sps != currentSPS || pps != currentPPS || decompressionSession == nil else {
            return
        }

        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
            self.decompressionSession = nil
        }

        let formatDescription = try Self.createFormatDescription(sps: sps, pps: pps)
        self.formatDescription = formatDescription
        currentSPS = sps
        currentPPS = pps

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { _, sourceFrameRefCon, status, infoFlags, imageBuffer, _, _ in
                guard let sourceFrameRefCon else { return }
                let context = Unmanaged<DecodeContext>.fromOpaque(sourceFrameRefCon).takeUnretainedValue()
                context.status = status
                context.infoFlags = infoFlags
                context.imageBuffer = imageBuffer
            },
            decompressionOutputRefCon: nil
        )

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw DirectH264VideoDecoderError.decompressionSessionFailed(status)
        }

        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        decompressionSession = session
    }

    private static func createFormatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var createdDescription: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsAddress = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsAddress = ppsBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                var parameterSetPointers = [spsAddress, ppsAddress]
                var parameterSetSizes = [sps.count, pps.count]

                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &parameterSetPointers,
                    parameterSetSizes: &parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &createdDescription
                )
                return status
            }
        }
        guard status == noErr, let createdDescription else {
            throw DirectH264VideoDecoderError.formatDescriptionFailed(status)
        }
        return createdDescription
    }

    private static func avccAccessUnit(fromAnnexB annexB: Data) throws -> Data {
        let nalUnits = DirectH264Parser.nalUnits(in: annexB)
        guard !nalUnits.isEmpty else {
            throw DirectH264VideoDecoderError.emptyAccessUnit
        }

        var output = Data()
        for nalUnit in nalUnits {
            var length = UInt32(nalUnit.bytes.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(nalUnit.bytes)
        }
        return output
    }

    private static func sampleBuffer(
        avccAccessUnit: Data,
        formatDescription: CMVideoFormatDescription,
        presentationTimestamp: CMTime
    ) throws -> CMSampleBuffer {
        guard !avccAccessUnit.isEmpty else {
            throw DirectH264VideoDecoderError.emptyAccessUnit
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccAccessUnit.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccAccessUnit.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            throw DirectH264VideoDecoderError.blockBufferFailed(status)
        }

        status = avccAccessUnit.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccAccessUnit.count
            )
        }
        guard status == noErr else {
            throw DirectH264VideoDecoderError.blockBufferFailed(status)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTimestamp,
            decodeTimeStamp: .invalid
        )
        var sampleSize = avccAccessUnit.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw DirectH264VideoDecoderError.sampleBufferFailed(status)
        }

        return sampleBuffer
    }
}
