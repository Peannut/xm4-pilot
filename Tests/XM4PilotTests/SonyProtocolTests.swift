import Foundation
import Testing
@testable import XM4Pilot

struct SonyProtocolTests {
    @Test func reconnectBackoffCapsAtThirtySeconds() {
        #expect((0...6).map(ReconnectBackoff.delay) == [2, 4, 8, 15, 30, 30, 30])
    }

    @Test func frameRoundTripIncludingEscapedBytes() {
        let payload: [UInt8] = [0x68, 0x3C, 0x3D, 0x3E, 0x01]
        let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: payload)
        #expect(SonyFrameCodec.decode(encoded) == SonyFrame(type: 0x0C, sequence: 1, payload: payload))
    }

    @Test func streamReassemblesSplitFrames() {
        let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: MDRv1.initRequest)
        var stream = SonyFrameStream()
        #expect(stream.append(encoded.prefix(3)).isEmpty)
        #expect(stream.append(encoded.dropFirst(3)).first?.payload == MDRv1.initRequest)
    }

    @Test func rejectsBadChecksum() {
        var encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: MDRv1.batteryRequest)
        encoded[encoded.count - 2] ^= 0x01
        #expect(SonyFrameCodec.decode(encoded) == nil)
    }

    @Test func noiseControlSetPayloads() {
        #expect(MDRv1.setNoiseControl(.init(mode: .anc, focusOnVoice: false, ambientLevel: 10))
            == [0x68, 0x02, 0x11, 0x02, 0x02, 0x01, 0x00, 10])
        #expect(MDRv1.setNoiseControl(.init(mode: .ambient, focusOnVoice: true, ambientLevel: 25))
            == [0x68, 0x02, 0x11, 0x02, 0x00, 0x01, 0x01, 20])
        #expect(MDRv1.setNoiseControl(.init(mode: .off, focusOnVoice: false, ambientLevel: 0))
            == [0x68, 0x02, 0x00, 0x02, 0x00, 0x01, 0x00, 1])
        #expect(MDRv1.setNoiseControl(.init(mode: .anc, focusOnVoice: false, ambientLevel: 10, layout: .single))
            == [0x68, 0x02, 0x11, 0x00, 0x01, 0x01, 0x00, 10])
    }

    @Test func parsesNoiseControlReplies() {
        // Captured from a real WH-1000XM4 (firmware 3.0.1).
        #expect(MDRv1.parseNoiseControl([0x67, 0x02, 0x01, 0x02, 0x02, 0x01, 0x00, 0x00])
            == .init(mode: .anc, focusOnVoice: false, ambientLevel: 10))
        #expect(MDRv1.parseNoiseControl([0x67, 0x02, 0x01, 0x00, 0x01, 0x01, 0x00, 0x0A])
            == .init(mode: .anc, focusOnVoice: false, ambientLevel: 10, layout: .single))
        #expect(MDRv1.parseNoiseControl([0x69, 0x02, 0x01, 0x02, 0x00, 0x01, 0x01, 0x11])
            == .init(mode: .ambient, focusOnVoice: true, ambientLevel: 17))
        #expect(MDRv1.parseNoiseControl([0x67, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x05])?.mode == .off)
        #expect(MDRv1.parseNoiseControl([0x67, 0x02, 0x01]) == nil)
    }

    @Test func parsesBatteryAndFirmware() {
        #expect(MDRv1.parseBattery([0x11, 0x00, 70, 0x01]) == .init(level: 70, isCharging: true))
        #expect(MDRv1.parseBattery([0x13, 0x00, 101, 0x00]) == nil)
        #expect(MDRv1.parseFirmware([0x05, 0x02, 0x05] + Array("2.6.1".utf8)) == "2.6.1")
        #expect(MDRv1.parseFirmware([0x05, 0x02] + Array("2.6.1".utf8)) == "2.6.1")
    }

    @Test func equalizerPresetProtocolValues() {
        #expect(MDRv1.setEqualizerPreset(.bassBoost) == [0x58, 0x01, 0x16, 0x00])
        #expect(!EqualizerPreset.selectableCases.contains(.manual))
        #expect(!EqualizerPreset.selectableCases.contains(.custom1))
    }

    @Test func customEqualizerPayloadRoundTripAndClamping() {
        let settings = EqualizerSettings(clearBass: 12, bands: [-12, -4, 0, 6, 14])
        #expect(settings == EqualizerSettings(clearBass: 10, bands: [-10, -4, 0, 6, 10]))
        #expect(settings.sonySetPayload == [0x58, 0x01, 0xA0, 0x06, 20, 0, 6, 10, 16, 20])

        let response: [UInt8] = [0x57, 0x01, 0xA0, 0x06, 20, 0, 6, 10, 16, 20]
        #expect(EqualizerSettings(sonyPayload: response) == settings)
        // Captured from a real WH-1000XM4: EQ off, flat.
        #expect(EqualizerSettings(sonyPayload: [0x57, 0x01, 0x00, 0x06, 10, 10, 10, 10, 10, 10]) == .flat)
    }
}
