import Foundation

struct DirectH264AccessUnit {
    let data: Data
    let isKeyframe: Bool
    let nalUnitTypes: [UInt8]
    let sps: Data?
    let pps: Data?

    var hasParameterSets: Bool {
        sps != nil && pps != nil
    }
}

enum DirectH264ParseResult: Equatable {
    case accessUnit(DirectH264AccessUnit)
    case control(UInt8)
    case waitingForKeyframe
    case invalid(String)
}

extension DirectH264AccessUnit: Equatable {}

struct DirectH264Parser {
    private var latestSPS: Data?
    private var latestPPS: Data?
    private var isSynced = false

    mutating func reset() {
        latestSPS = nil
        latestPPS = nil
        isSynced = false
    }

    mutating func parseGLKVMBinaryMessage(_ message: Data) -> DirectH264ParseResult {
        guard let kind = message.first else {
            return .invalid("empty binary message")
        }

        guard kind == 1 else {
            return .control(kind)
        }

        guard message.count >= 3 else {
            return .invalid("video message too short")
        }

        let keyframeFlag = message[message.startIndex + 1] != 0
        let payload = message.dropFirst(2)
        return parseAnnexBAccessUnit(Data(payload), keyframeFlag: keyframeFlag)
    }

    mutating func parseAnnexBAccessUnit(_ accessUnit: Data, keyframeFlag: Bool) -> DirectH264ParseResult {
        let nalUnits = Self.nalUnits(in: accessUnit)
        guard !nalUnits.isEmpty else {
            return .invalid("no Annex B NAL units found")
        }

        let nalTypes = nalUnits.map { $0.type }
        let sps = nalUnits.first(where: { $0.type == 7 })?.bytes
        let pps = nalUnits.first(where: { $0.type == 8 })?.bytes
        let hasIDR = nalUnits.contains { $0.type == 5 }
        let isKeyframe = keyframeFlag || hasIDR

        if let sps {
            latestSPS = sps
        }
        if let pps {
            latestPPS = pps
        }

        if isKeyframe && hasIDR && latestSPS != nil && latestPPS != nil {
            isSynced = true
        }

        guard isSynced else {
            return .waitingForKeyframe
        }

        return .accessUnit(DirectH264AccessUnit(
            data: accessUnit,
            isKeyframe: isKeyframe,
            nalUnitTypes: nalTypes,
            sps: latestSPS,
            pps: latestPPS
        ))
    }

    static func nalUnits(in annexB: Data) -> [DirectH264NALUnit] {
        let bytes = [UInt8](annexB)
        var units: [DirectH264NALUnit] = []
        var searchIndex = 0

        while let startCode = findStartCode(in: bytes, from: searchIndex) {
            let nalStart = startCode.end
            let nextStartCode = findStartCode(in: bytes, from: nalStart)
            let nalEnd = nextStartCode?.start ?? bytes.count
            searchIndex = nalEnd

            guard nalStart < nalEnd else {
                continue
            }

            let nalBytes = Data(bytes[nalStart..<nalEnd])
            guard let header = nalBytes.first else {
                continue
            }

            units.append(DirectH264NALUnit(
                type: header & 0x1f,
                bytes: nalBytes,
                annexBRange: nalStart..<nalEnd
            ))
        }

        return units
    }

    private static func findStartCode(in bytes: [UInt8], from startIndex: Int) -> (start: Int, end: Int)? {
        guard bytes.count >= 3, startIndex < bytes.count - 2 else {
            return nil
        }

        var index = max(0, startIndex)
        while index <= bytes.count - 3 {
            if bytes[index] == 0 && bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    return (index, index + 3)
                }
                if index <= bytes.count - 4 && bytes[index + 2] == 0 && bytes[index + 3] == 1 {
                    return (index, index + 4)
                }
            }
            index += 1
        }

        return nil
    }
}

struct DirectH264NALUnit: Equatable {
    let type: UInt8
    let bytes: Data
    let annexBRange: Range<Int>
}
