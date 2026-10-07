import Foundation

enum ReconnectBackoff {
    private static let delays: [TimeInterval] = [2, 4, 8, 15, 30]

    static func delay(forAttempt attempt: Int) -> TimeInterval {
        delays[min(max(0, attempt), delays.count - 1)]
    }
}

enum NoiseControlMode: String, CaseIterable, Identifiable, Sendable {
    case off, anc, ambient

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Off"
        case .anc: "Noise Cancelling"
        case .ambient: "Ambient"
        }
    }

    var compactTitle: String {
        switch self {
        case .off: "Off"
        case .anc: "ANC"
        case .ambient: "Ambient"
        }
    }

    var symbol: String {
        switch self {
        case .off: "speaker.slash"
        case .anc: "waveform"
        case .ambient: "ear"
        }
    }
}

enum EqualizerPreset: UInt8, CaseIterable, Identifiable, Sendable {
    case off = 0x00
    case bright = 0x10
    case excited = 0x11
    case mellow = 0x12
    case relaxed = 0x13
    case vocal = 0x14
    case trebleBoost = 0x15
    case bassBoost = 0x16
    case speech = 0x17
    case manual = 0xA0
    case custom1 = 0xA1
    case custom2 = 0xA2

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Off"
        case .bright: "Bright"
        case .excited: "Excited"
        case .mellow: "Mellow"
        case .relaxed: "Relaxed"
        case .vocal: "Vocal"
        case .trebleBoost: "Treble Boost"
        case .bassBoost: "Bass Boost"
        case .speech: "Speech"
        case .manual: "Manual"
        case .custom1: "Custom 1"
        case .custom2: "Custom 2"
        }
    }

    static var selectableCases: [Self] { allCases.filter { $0.rawValue < Self.manual.rawValue } }
}

/// WH-1000XM4 speaks Sony's original "MDR v1" command set. Framing is shared
/// with v2 (see `SonyFrameCodec`); the command bytes below are what differ.
enum MDRv1 {
    static let initRequest: [UInt8] = [0x00, 0x00]
    static let initReply: UInt8 = 0x01

    static let firmwareRequest: [UInt8] = [0x04, 0x02]
    static let firmwareReply: UInt8 = 0x05

    static let batteryRequest: [UInt8] = [0x10, 0x00]
    static let batteryReply: UInt8 = 0x11
    static let batteryNotify: UInt8 = 0x13

    static let equalizerRequest: [UInt8] = [0x56, 0x01]
    static let equalizerReply: UInt8 = 0x57
    static let equalizerSet: UInt8 = 0x58
    static let equalizerNotify: UInt8 = 0x59

    static let noiseControlRequest: [UInt8] = [0x66, 0x02]
    static let noiseControlReply: UInt8 = 0x67
    static let noiseControlSet: UInt8 = 0x68
    static let noiseControlNotify: UInt8 = 0x69

    /// Byte 3 of noise-control messages. The XM4 reports `dual` (ambient / wind / ANC
    /// selector, ANC = 2); older models use `single` (ANC = 1). Replies echo the layout,
    /// and commands must use the same one.
    enum NoiseControlLayout: UInt8, Sendable {
        case single = 0x00
        case dual = 0x02

        var ancValue: UInt8 { self == .dual ? 0x02 : 0x01 }
    }

    struct NoiseControlState: Equatable, Sendable {
        var mode: NoiseControlMode
        var focusOnVoice: Bool
        var ambientLevel: Int
        var layout: NoiseControlLayout = .dual
    }

    static func setNoiseControl(_ state: NoiseControlState) -> [UInt8] {
        [
            noiseControlSet, 0x02,
            state.mode == .off ? 0x00 : 0x11,
            state.layout.rawValue,
            state.mode == .anc ? state.layout.ancValue : 0x00,
            0x01,
            state.focusOnVoice ? 0x01 : 0x00,
            UInt8(max(1, min(20, state.ambientLevel))),
        ]
    }

    static func parseNoiseControl(_ payload: [UInt8]) -> NoiseControlState? {
        guard payload.count == 8, payload[1] == 0x02,
              let layout = NoiseControlLayout(rawValue: payload[3]) else { return nil }
        // payload[4]: 0 = ambient, non-zero = noise cancelling (or wind-reduction ANC).
        let mode: NoiseControlMode = payload[2] == 0x00 ? .off : (payload[4] == 0x00 ? .ambient : .anc)
        let level = Int(payload[7])
        return NoiseControlState(
            mode: mode,
            focusOnVoice: payload[6] == 0x01,
            ambientLevel: (1...20).contains(level) ? level : 10,
            layout: layout
        )
    }

    static func setEqualizerPreset(_ preset: EqualizerPreset) -> [UInt8] {
        [equalizerSet, 0x01, preset.rawValue, 0x00]
    }

    struct Battery: Equatable, Sendable {
        var level: Int
        var isCharging: Bool
    }

    static func parseBattery(_ payload: [UInt8]) -> Battery? {
        guard payload.count >= 4, payload[1] == 0x00, (0...100).contains(Int(payload[2])) else { return nil }
        return Battery(level: Int(payload[2]), isCharging: payload[3] == 0x01)
    }

    static func parseFirmware(_ payload: [UInt8]) -> String? {
        guard payload.count > 2, payload[1] == 0x02 else { return nil }
        var text = Array(payload.dropFirst(2))
        // Firmware strings are usually length-prefixed.
        if let length = text.first, Int(length) == text.count - 1 { text.removeFirst() }
        let value = String(bytes: text, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        return value?.isEmpty == false ? value : nil
    }
}

struct EqualizerSettings: Codable, Equatable, Sendable {
    static let bandLabels = ["400 Hz", "1 kHz", "2.5 kHz", "6.3 kHz", "16 kHz"]
    static let flat = EqualizerSettings(clearBass: 0, bands: [0, 0, 0, 0, 0])

    var clearBass: Int
    var bands: [Int]

    init(clearBass: Int, bands: [Int]) {
        self.clearBass = Self.clamp(clearBass)
        self.bands = (0..<5).map { index in
            Self.clamp(index < bands.count ? bands[index] : 0)
        }
    }

    subscript(band index: Int) -> Int {
        get { bands[index] }
        set { bands[index] = Self.clamp(newValue) }
    }

    var sonySetPayload: [UInt8] {
        [MDRv1.equalizerSet, 0x01, EqualizerPreset.manual.rawValue, 0x06]
            + ([clearBass] + bands).map { UInt8(Self.clamp($0) + 10) }
    }

    init?(sonyPayload: [UInt8]) {
        guard sonyPayload.count >= 10,
              sonyPayload[1] == 0x01,
              sonyPayload[3] >= 0x06 else { return nil }
        self.init(
            clearBass: Int(sonyPayload[4]) - 10,
            bands: sonyPayload[5..<10].map { Int($0) - 10 }
        )
    }

    private static func clamp(_ value: Int) -> Int { max(-10, min(10, value)) }
}

struct SonyFrame: Equatable, Sendable {
    let type: UInt8
    let sequence: UInt8
    let payload: [UInt8]
}

enum SonyFrameCodec {
    static let header: UInt8 = 0x3E
    static let trailer: UInt8 = 0x3C
    static let escape: UInt8 = 0x3D
    private static let escapeMask: UInt8 = 0xEF

    static func encode(type: UInt8, sequence: UInt8, payload: [UInt8]) -> Data {
        let count = UInt32(payload.count)
        var body: [UInt8] = [
            type, sequence,
            UInt8((count >> 24) & 0xFF), UInt8((count >> 16) & 0xFF),
            UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF),
        ]
        body.append(contentsOf: payload)
        body.append(body.reduce(0, &+))

        var encoded = [header]
        for byte in body {
            if byte == header || byte == trailer || byte == escape {
                encoded += [escape, byte & escapeMask]
            } else {
                encoded.append(byte)
            }
        }
        encoded.append(trailer)
        return Data(encoded)
    }

    static func decode(_ data: Data) -> SonyFrame? {
        let bytes = [UInt8](data)
        guard bytes.count >= 9, bytes.first == header, bytes.last == trailer else { return nil }
        var raw: [UInt8] = []
        var index = 1
        while index < bytes.count - 1 {
            var byte = bytes[index]
            if byte == escape {
                index += 1
                guard index < bytes.count - 1 else { return nil }
                byte = bytes[index] | ~escapeMask
            }
            raw.append(byte)
            index += 1
        }
        guard raw.count >= 7, raw.last == raw.dropLast().reduce(0, &+) else { return nil }
        let length = Int(UInt32(raw[2]) << 24 | UInt32(raw[3]) << 16 | UInt32(raw[4]) << 8 | UInt32(raw[5]))
        guard length == raw.count - 7 else { return nil }
        return SonyFrame(type: raw[0], sequence: raw[1], payload: Array(raw[6..<(6 + length)]))
    }
}

struct SonyFrameStream: Sendable {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [SonyFrame] {
        buffer.append(data)
        var frames: [SonyFrame] = []
        while let start = buffer.firstIndex(of: SonyFrameCodec.header) {
            if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
            guard let end = buffer.dropFirst().firstIndex(of: SonyFrameCodec.trailer) else { break }
            let packet = Data(buffer[buffer.startIndex...end])
            buffer.removeSubrange(buffer.startIndex...end)
            if let frame = SonyFrameCodec.decode(packet) { frames.append(frame) }
        }
        return frames
    }
}
