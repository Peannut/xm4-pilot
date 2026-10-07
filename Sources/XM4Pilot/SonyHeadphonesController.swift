import Combine
import Foundation
import OSLog
@preconcurrency import IOBluetooth

@MainActor
final class SonyHeadphonesController: NSObject, ObservableObject {
    enum LinkState: Equatable {
        case searching, disconnected, opening, handshaking, ready, controlBusy
        case failed(String)
    }

    @Published private(set) var deviceName = "WH-1000XM4"
    @Published private(set) var address = ""
    @Published private(set) var isDeviceConnected = false
    @Published private(set) var linkState: LinkState = .searching
    @Published private(set) var noiseControlMode: NoiseControlMode?
    @Published private(set) var ambientLevel = 10
    @Published private(set) var focusOnVoice = false
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var isApplyingChange = false
    @Published private(set) var equalizerPreset: EqualizerPreset?
    @Published private(set) var customEqualizer = EqualizerSettings.flat
    @Published private(set) var firmwareVersion: String?
    @Published private(set) var controlChannelID: Int?
    @Published private(set) var retrySecondsRemaining: Int?
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastErrorMessage: String?

    var isReady: Bool { linkState == .ready }
    var statusText: String {
        switch linkState {
        case .searching: "Looking for your XM4…"
        case .disconnected: "Headphones disconnected"
        case .opening: "Opening Sony control link…"
        case .handshaking: "Syncing controls…"
        case .ready: "Connected"
        case .controlBusy: "Control link busy"
        case .failed(let message): message
        }
    }

    var diagnosticReport: String {
        [
            "XM4 Pilot diagnostics",
            "Device: \(deviceName)",
            "Address: \(address.isEmpty ? "Not found" : address)",
            "Bluetooth audio: \(isDeviceConnected ? "Connected" : "Disconnected")",
            "Sony control: \(statusText)",
            "Protocol: MDR v1 / RFCOMM\(controlChannelID.map { " channel \($0)" } ?? "")",
            "Firmware: \(firmwareVersion ?? "Unknown")",
            "Battery: \(batteryLevel.map { "\($0)%" } ?? "Unknown")",
            "Noise control: \(noiseControlMode?.title ?? "Unknown")",
            "Equalizer: \(equalizerPreset?.title ?? "Unknown")",
            "Last sync: \(lastSyncDate?.formatted(date: .numeric, time: .standard) ?? "Never")",
            "Last error: \(lastErrorMessage ?? "None")",
        ].joined(separator: "\n")
    }

    private enum Stage { case idle, protocolInfo, noiseControl, ready }
    /// Sony's control service UUIDs: the MDR v1 one the XM4 advertises first,
    /// then the newer v2 one as a fallback for later firmware.
    private static let sonyServiceUUIDs: [[UInt8]] = [
        [
            0x96, 0xCC, 0x20, 0x3E, 0x50, 0x68, 0x46, 0xAD,
            0xB3, 0x2D, 0xE3, 0x16, 0xF5, 0xE0, 0x69, 0xBA,
        ],
        [
            0x95, 0x6C, 0x7B, 0x26, 0xD4, 0x9A, 0x4B, 0xA8,
            0xB0, 0x3F, 0xB1, 0x7D, 0x39, 0x3C, 0xB6, 0xE2,
        ],
    ]
    private static let logger = Logger(subsystem: "local.xm4pilot", category: "SonyBluetooth")

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var refreshTimer: Timer?
    private var retryWorkItem: DispatchWorkItem?
    private var ambientWorkItem: DispatchWorkItem?
    private var commandTimeoutWorkItem: DispatchWorkItem?
    private var equalizerWorkItem: DispatchWorkItem?
    private var stream = SonyFrameStream()
    private var stage: Stage = .idle
    private var sequence: UInt8 = 0
    private var reconnectAutomatically = true
    private var isSimulated = false
    private var retryAttempt = 0
    private var nextRetryDate: Date?
    private var syncPollCount = 0
    private var noiseControlLayout = MDRv1.NoiseControlLayout.dual
    private var handshakeAttempts = 0
    private static let maxHandshakeAttempts = 6

    init(startAutomatically: Bool = true, simulatedReady: Bool = false) {
        super.init()
        #if DEBUG
        if simulatedReady {
            isSimulated = true
            address = "80:99:E7:FB:0A:59"
            isDeviceConnected = true
            linkState = .ready
            noiseControlMode = .ambient
            ambientLevel = 12
            batteryLevel = 78
            equalizerPreset = .bassBoost
            firmwareVersion = "2.6.1"
            controlChannelID = 9
            lastSyncDate = Date()
            stage = .ready
            return
        }
        #endif
        guard startAutomatically else {
            linkState = .disconnected
            return
        }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func setReconnectAutomatically(_ enabled: Bool) {
        reconnectAutomatically = enabled
        guard !isSimulated else { return }
        if enabled {
            refresh()
        } else {
            retryWorkItem?.cancel()
            retryWorkItem = nil
            nextRetryDate = nil
            retrySecondsRemaining = nil
        }
    }

    func refresh() {
        cancelScheduledRetry(resetAttempts: true)
        refresh(shouldOpenLink: true)
        requestCurrentSettings()
    }

    func refreshEqualizer() {
        guard stage == .ready else { return }
        send(MDRv1.equalizerRequest)
    }

    private func poll() {
        updateRetryCountdown()
        refresh(shouldOpenLink: reconnectAutomatically)
        guard stage == .ready else { return }
        syncPollCount += 1
        if syncPollCount >= 5 {
            syncPollCount = 0
            requestCurrentSettings()
        }
    }

    private func requestCurrentSettings() {
        guard stage == .ready else { return }
        send(MDRv1.noiseControlRequest)
        send(MDRv1.batteryRequest)
        send(MDRv1.equalizerRequest)
        if firmwareVersion == nil { send(MDRv1.firmwareRequest) }
    }

    private func refresh(shouldOpenLink: Bool) {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        guard let match = paired.first(where: { ($0.name ?? "").localizedCaseInsensitiveContains("1000XM4") }) else {
            closeSonyLink()
            device = nil
            address = ""
            isDeviceConnected = false
            linkState = .failed("Pair your Sony WH-1000XM4 in System Settings")
            return
        }
        device = match
        deviceName = match.name ?? "Sony XM4"
        address = match.addressString ?? ""
        isDeviceConnected = match.isConnected()
        guard isDeviceConnected else {
            closeSonyLink()
            linkState = .disconnected
            return
        }
        if shouldOpenLink, channel == nil, stage == .idle {
            guard nextRetryDate.map({ $0 <= Date() }) ?? true else { return }
            nextRetryDate = nil
            retrySecondsRemaining = nil
            openSonyLink()
        }
    }

    func connect() {
        cancelScheduledRetry(resetAttempts: true)
        guard let device else {
            refresh()
            return
        }
        linkState = .opening
        let result = device.openConnection()
        isDeviceConnected = device.isConnected()
        if result != kIOReturnSuccess, !isDeviceConnected {
            fail("Headphones did not respond. Make sure they are powered on.")
            return
        }
        stage = .idle
        refresh()
    }

    func setNoiseControl(_ mode: NoiseControlMode) {
        sendNoiseControl(mode)
    }

    func toggleNoiseControl() {
        guard isReady else { return }
        sendNoiseControl(noiseControlMode == .anc ? .ambient : .anc)
    }

    func setEqualizerPreset(_ preset: EqualizerPreset) {
        guard stage == .ready else { return }
        equalizerWorkItem?.cancel()
        beginApplyingChange()
        send(MDRv1.setEqualizerPreset(preset))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            Task { @MainActor in self?.send(MDRv1.equalizerRequest) }
        }
    }

    func setCustomEqualizer(_ settings: EqualizerSettings) {
        guard stage == .ready else { return }
        customEqualizer = settings
        equalizerPreset = .manual
        equalizerWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.beginApplyingChange()
                self.send(settings.sonySetPayload)
                // The XM4 doesn't echo EQ writes; read back to confirm.
                self.send(MDRv1.equalizerRequest)
            }
        }
        equalizerWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    func applyPreset(mode: NoiseControlMode, ambientLevel level: Int, focusOnVoice focus: Bool) {
        ambientWorkItem?.cancel()
        ambientLevel = max(1, min(20, level))
        focusOnVoice = focus
        sendNoiseControl(mode)
    }

    private func sendNoiseControl(_ mode: NoiseControlMode) {
        if isSimulated {
            noiseControlMode = mode
            return
        }
        guard stage == .ready else { return }
        beginApplyingChange()
        send(MDRv1.setNoiseControl(.init(
            mode: mode,
            focusOnVoice: focusOnVoice,
            ambientLevel: ambientLevel,
            layout: noiseControlLayout
        )))
    }

    func setAmbientLevel(_ level: Int) {
        ambientLevel = max(1, min(20, level))
        ambientWorkItem?.cancel()
        guard noiseControlMode == .ambient else { return }
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.sendNoiseControl(.ambient) }
        }
        ambientWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: workItem)
    }

    func setFocusOnVoice(_ enabled: Bool) {
        focusOnVoice = enabled
        if noiseControlMode == .ambient { sendNoiseControl(.ambient) }
    }

    private func beginApplyingChange() {
        isApplyingChange = true
        commandTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.isApplyingChange = false }
        }
        commandTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func openSonyLink() {
        guard let device else { return }
        stage = .protocolInfo
        linkState = .opening
        let record = Self.sonyServiceUUIDs.lazy.compactMap { bytes in
            let uuid = bytes.withUnsafeBytes {
                IOBluetoothSDPUUID(bytes: $0.baseAddress!, length: bytes.count)
            }
            return device.getServiceRecord(for: uuid)
        }.first
        guard let record else {
            fail("Sony control service is unavailable")
            return
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            fail("Could not resolve Sony control channel")
            return
        }
        var openedChannel: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&openedChannel, withChannelID: channelID, delegate: self)
        channel = openedChannel
        guard result == kIOReturnSuccess else {
            handleOpenFailure(result)
            return
        }
        controlChannelID = Int(channelID)
        Self.logger.info("Opening RFCOMM channel \(channelID)")
    }

    private func closeSonyLink() {
        cancelScheduledRetry(resetAttempts: true)
        channel?.close()
        channel = nil
        stage = .idle
        noiseControlMode = nil
        batteryLevel = nil
        isCharging = false
        isApplyingChange = false
        equalizerPreset = nil
        firmwareVersion = nil
        controlChannelID = nil
        equalizerWorkItem?.cancel()
        equalizerWorkItem = nil
    }

    private func beginHandshake() {
        sequence = 0
        stream = SonyFrameStream()
        stage = .protocolInfo
        linkState = .handshaking
        handshakeAttempts = 0
        sendInit()
    }

    /// The XM4 often drops the first init request while it pushes its own greeting,
    /// so keep re-sending until it answers.
    private func sendInit() {
        guard stage == .protocolInfo, channel != nil else { return }
        guard handshakeAttempts < Self.maxHandshakeAttempts else {
            fail("Headphones did not answer the control handshake")
            return
        }
        handshakeAttempts += 1
        send(MDRv1.initRequest)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            Task { @MainActor in self?.sendInit() }
        }
    }

    private func send(_ payload: [UInt8], type: UInt8 = 0x0C, sequence explicitSequence: UInt8? = nil) {
        guard let channel else { return }
        let frameSequence: UInt8
        if let explicitSequence {
            frameSequence = explicitSequence
        } else {
            frameSequence = sequence
            sequence = 1 - sequence
        }
        let data = SonyFrameCodec.encode(type: type, sequence: frameSequence, payload: payload)
        let result = data.withUnsafeBytes { bytes -> IOReturn in
            guard let baseAddress = bytes.baseAddress else { return kIOReturnBadArgument }
            return channel.writeSync(UnsafeMutableRawPointer(mutating: baseAddress), length: UInt16(data.count))
        }
        if result != kIOReturnSuccess { fail("Could not send to headphones (\(result))") }
    }

    private func receive(_ data: Data) {
        for frame in stream.append(data) {
            if frame.type == 0x01 { continue }
            if frame.type == 0x0C || frame.type == 0x0E {
                send([], type: 0x01, sequence: 1 - frame.sequence)
            }
            if frame.type == 0x0C, !frame.payload.isEmpty { dispatch(frame.payload) }
        }
    }

    private func dispatch(_ payload: [UInt8]) {
        switch (payload[0], stage) {
        case (MDRv1.initReply, .protocolInfo):
            stage = .noiseControl
            send(MDRv1.noiseControlRequest)
        case (_, .protocolInfo):
            // Unsolicited greeting (0xA5) arrived before our init was handled.
            send(MDRv1.initRequest)
        case (MDRv1.noiseControlReply, _), (MDRv1.noiseControlNotify, _):
            parseNoiseControl(payload)
        case (MDRv1.batteryReply, _), (MDRv1.batteryNotify, _):
            parseBattery(payload)
        case (MDRv1.equalizerReply, _), (MDRv1.equalizerNotify, _):
            parseEqualizer(payload)
        case (MDRv1.firmwareReply, _):
            parseFirmware(payload)
        default:
            break
        }
    }

    private func parseNoiseControl(_ payload: [UInt8]) {
        guard let state = MDRv1.parseNoiseControl(payload) else { return }
        let mode = state.mode
        noiseControlLayout = state.layout
        focusOnVoice = state.focusOnVoice
        ambientLevel = state.ambientLevel
        noiseControlMode = mode
        stage = .ready
        linkState = .ready
        isApplyingChange = false
        commandTimeoutWorkItem?.cancel()
        commandTimeoutWorkItem = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryAttempt = 0
        nextRetryDate = nil
        retrySecondsRemaining = nil
        lastErrorMessage = nil
        lastSyncDate = Date()
        Self.logger.info("Noise control synced; mode=\(mode.rawValue, privacy: .public)")
        if batteryLevel == nil { send(MDRv1.batteryRequest) }
        if equalizerPreset == nil { send(MDRv1.equalizerRequest) }
        if firmwareVersion == nil { send(MDRv1.firmwareRequest) }
    }

    private func parseBattery(_ payload: [UInt8]) {
        guard let battery = MDRv1.parseBattery(payload) else { return }
        let level = battery.level
        batteryLevel = level
        isCharging = battery.isCharging
        lastSyncDate = Date()
        Self.logger.info("Battery ready; level=\(level, privacy: .public)")
    }

    private func parseEqualizer(_ payload: [UInt8]) {
        guard payload.count >= 3, payload[1] == 0x01 else { return }
        equalizerPreset = EqualizerPreset(rawValue: payload[2])
        if let settings = EqualizerSettings(sonyPayload: payload) {
            customEqualizer = settings
        }
        lastSyncDate = Date()
        isApplyingChange = false
        commandTimeoutWorkItem?.cancel()
        commandTimeoutWorkItem = nil
        if let equalizerPreset {
            Self.logger.info("Equalizer ready; preset=\(equalizerPreset.title, privacy: .public)")
        }
    }

    private func fail(_ message: String) {
        Self.logger.error("\(message, privacy: .public)")
        channel?.close()
        channel = nil
        stage = .idle
        linkState = .failed(message)
        lastErrorMessage = message
        isApplyingChange = false
        scheduleRetry()
    }

    private func handleOpenFailure(_ error: IOReturn) {
        let message = "Sony control channel is busy (\(error))"
        Self.logger.error("\(message, privacy: .public)")
        channel?.close()
        channel = nil
        stage = .idle
        linkState = .controlBusy
        lastErrorMessage = message
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        guard reconnectAutomatically, isDeviceConnected else {
            nextRetryDate = nil
            retrySecondsRemaining = nil
            return
        }
        let delay = ReconnectBackoff.delay(forAttempt: retryAttempt)
        retryAttempt += 1
        nextRetryDate = Date().addingTimeInterval(delay)
        retrySecondsRemaining = Int(delay.rounded(.up))
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.retryWorkItem = nil
                self.nextRetryDate = nil
                self.retrySecondsRemaining = nil
                self.refresh(shouldOpenLink: true)
            }
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelScheduledRetry(resetAttempts: Bool) {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        nextRetryDate = nil
        retrySecondsRemaining = nil
        if resetAttempts { retryAttempt = 0 }
    }

    private func updateRetryCountdown() {
        guard let nextRetryDate else {
            retrySecondsRemaining = nil
            return
        }
        retrySecondsRemaining = max(0, Int(nextRetryDate.timeIntervalSinceNow.rounded(.up)))
    }

    private func parseFirmware(_ payload: [UInt8]) {
        guard let value = MDRv1.parseFirmware(payload) else { return }
        firmwareVersion = value
        lastSyncDate = Date()
        Self.logger.info("Firmware ready; version=\(value, privacy: .public)")
    }

    @objc nonisolated
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel, status error: IOReturn) {
        Task { @MainActor in
            guard error == kIOReturnSuccess else {
                handleOpenFailure(error)
                return
            }
            channel = rfcommChannel
            beginHandshake()
        }
    }

    @objc nonisolated
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel, data dataPointer: UnsafeMutableRawPointer, length dataLength: Int) {
        let copied = Data(bytes: dataPointer, count: dataLength)
        Task { @MainActor in receive(copied) }
    }

    @objc nonisolated
    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel) {
        Task { @MainActor in
            guard channel === rfcommChannel else { return }
            channel = nil
            stage = .idle
            noiseControlMode = nil
            if isDeviceConnected {
                linkState = .controlBusy
                lastErrorMessage = "Sony control link closed while Bluetooth audio remained connected"
                scheduleRetry()
            } else {
                linkState = .disconnected
            }
        }
    }
}
