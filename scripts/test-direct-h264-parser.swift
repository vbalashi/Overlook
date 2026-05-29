import Foundation

@main
struct DirectH264ParserTestRunner {
    static func main() {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures.append(message)
            }
        }

        func nal(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
            [0, 0, 0, 1, type] + payload
        }

        let sps = nal(0x67, [0x64, 0x10, 0x28, 0xac])
        let pps = nal(0x68, [0xee, 0x3c, 0x80])
        let idr = nal(0x65, [0x88, 0x84, 0x21])
        let delta: [UInt8] = [0, 0, 1, 0x41, 0x9a, 0x22]

        var parser = DirectH264Parser()

        expect(parser.parseGLKVMBinaryMessage(Data([0xff])) == .control(0xff), "one-byte ff must be control")
        expect(parser.parseGLKVMBinaryMessage(Data([UInt8(1), UInt8(0)] + delta)) == .waitingForKeyframe, "delta before sync must wait for keyframe")

        let keyframeResult = parser.parseGLKVMBinaryMessage(Data([UInt8(1), UInt8(1)] + sps + pps + idr))
        switch keyframeResult {
        case .accessUnit(let accessUnit):
            expect(accessUnit.isKeyframe, "IDR access unit must be keyframe")
            expect(accessUnit.nalUnitTypes == [7, 8, 5], "keyframe NAL types must be [7, 8, 5]")
            expect(accessUnit.sps == Data([0x67, 0x64, 0x10, 0x28, 0xac]), "SPS must exclude Annex B start code")
            expect(accessUnit.pps == Data([0x68, 0xee, 0x3c, 0x80]), "PPS must exclude Annex B start code")
        default:
            failures.append("keyframe should emit access unit, got \(keyframeResult)")
        }

        let deltaResult = parser.parseGLKVMBinaryMessage(Data([UInt8(1), UInt8(0)] + delta))
        switch deltaResult {
        case .accessUnit(let accessUnit):
            expect(!accessUnit.isKeyframe, "delta access unit must not be keyframe")
            expect(accessUnit.nalUnitTypes == [1], "delta NAL type must be [1]")
            expect(accessUnit.hasParameterSets, "delta after sync must carry latest parameter sets")
        default:
            failures.append("delta after sync should emit access unit, got \(deltaResult)")
        }

        parser.reset()
        expect(parser.parseAnnexBAccessUnit(Data([0, 0, 1, 0x41, 0x00]), keyframeFlag: false) == .waitingForKeyframe, "reset must clear sync")
        expect(DirectH264Parser.nalUnits(in: Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3])).map(\.type) == [7, 8], "parser must support 3-byte and 4-byte start codes")

        if failures.isEmpty {
            print("DirectH264Parser tests passed")
        } else {
            for failure in failures {
                fputs("FAIL: \(failure)\n", stderr)
            }
            exit(1)
        }
    }
}
