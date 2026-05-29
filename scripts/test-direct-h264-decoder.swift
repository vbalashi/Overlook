import Foundation
import CoreVideo

@main
struct DirectH264DecoderTestRunner {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: test-direct-h264-decoder <capture.ovdm>\n", stderr)
            exit(2)
        }

        let captureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: captureURL)
        guard data.starts(with: Data("OVDM1\n".utf8)) else {
            fputs("invalid capture magic\n", stderr)
            exit(2)
        }

        var parser = DirectH264Parser()
        let decoder = DirectH264VideoDecoder()
        var offset = 6
        var decodedFrames = 0
        var keyframes = 0
        var controlPackets = 0
        var lastSize: (width: Int, height: Int)?

        while offset < data.count {
            guard offset + 9 <= data.count else {
                throw TestError.truncatedRecordHeader
            }

            let type = data[offset]
            let length = Int(data[(offset + 1)..<(offset + 9)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
            offset += 9
            guard offset + length <= data.count else {
                throw TestError.truncatedRecordPayload
            }

            let payload = data[offset..<(offset + length)]
            offset += length

            guard type == 1 else {
                continue
            }

            switch parser.parseGLKVMBinaryMessage(Data(payload)) {
            case .accessUnit(let accessUnit):
                let pixelBuffer = try decoder.decode(accessUnit)
                decodedFrames += 1
                if accessUnit.isKeyframe {
                    keyframes += 1
                }
                lastSize = (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
            case .control:
                controlPackets += 1
            case .waitingForKeyframe:
                continue
            case .invalid(let reason):
                throw TestError.invalidFrame(reason)
            }
        }

        guard decodedFrames > 0, let lastSize else {
            throw TestError.noDecodedFrames
        }

        print("DirectH264Decoder decoded_frames=\(decodedFrames) keyframes=\(keyframes) control_packets=\(controlPackets) last_size=\(lastSize.width)x\(lastSize.height)")
    }

    enum TestError: Error {
        case truncatedRecordHeader
        case truncatedRecordPayload
        case invalidFrame(String)
        case noDecodedFrames
    }
}
