import CoreAudio
import Foundation

/// One output device for everything ClearMix makes: the cleaned microphone and,
/// if wanted, each application's audio with its own slider.
///
/// Both engines write to the same device, so the HAL sums them: a virtual
/// microphone (BlackHole, a loopback interface) carries the mixed result to
/// Discord, a recorder or a stream. The microphone is optional — the session
/// runs apps only until it is started, which keeps a permission prompt away from
/// users who just want a mixer.
public final class MixSession: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Microphone to clean. Nil keeps the session apps-only.
        public var inputDevice: AudioDevice?
        /// Where tapped applications (and optional self-monitoring) play.
        public var outputDevice: AudioDevice?
        /// Dedicated virtual microphone output (e.g. BlackHole 2ch). When nil,
        /// falls back to `outputDevice` (muted unless `monitorMicrophone` is true).
        public var micOutputDevice: AudioDevice?
        public var denoiseEnabled = true
        public var denoiseStrength: Float = 1.0
        public var gateEnabled = false
        public var gateThresholdDB: Float = -45
        public var micGainDB: Float = 0
        public var abBypass = false
        /// Play the microphone on `outputDevice` as well. Off is the
        /// conference setup: the mic only reaches `micOutputDevice` (BlackHole).
        public var monitorMicrophone = true
        /// Mix applications at all; off leaves the output to the microphone.
        public var mixApplications = true
        /// Keep `systemsoundserverd` tapped even between chimes.
        public var keepSystemSoundsTap = true
        /// Bundle ids or names to mix. Empty means every app playing audio.
        public var only: [String] = []
        public var excluding: [String] = []

        public init(
            inputDevice: AudioDevice? = nil,
            outputDevice: AudioDevice?,
            micOutputDevice: AudioDevice? = nil
        ) {
            self.inputDevice = inputDevice
            self.outputDevice = outputDevice
            self.micOutputDevice = micOutputDevice
        }
    }

    public enum SessionError: LocalizedError {
        case microphoneUnavailable
        case noOutputDevice

        public var errorDescription: String? {
            switch self {
            case .microphoneUnavailable:
                return "Mikrofon cihazı seçili değil."
            case .noOutputDevice:
                return "Çıkış cihazı bulunamadı."
            }
        }
    }

    private let lock = NSLock()
    private var micEngine: MicEngine?
    private var monitorPlayback: MonitorPlayback?
    private var monitorRing: AudioRingBuffer?
    private let mixerEngine: MixerEngine

    public private(set) var configuration: Configuration
    /// Last failure from either side, for a UI or a log line.
    public private(set) var lastError: String?

    public init(configuration: Configuration) {
        self.configuration = configuration
        var mixerConfig = MixerEngine.Configuration(outputDevice: configuration.outputDevice)
        mixerConfig.keepSystemSoundsTap = configuration.keepSystemSoundsTap
        mixerEngine = MixerEngine(configuration: mixerConfig)
        mixerEngine.setFilters(only: configuration.only, excluding: configuration.excluding)
    }

    deinit {
        stop()
    }

    // MARK: - State

    public var taps: [AppTap] { mixerEngine.taps }

    /// Last application tap failure, kept separate from the microphone's.
    public var applicationError: String? { mixerEngine.lastError }

    public var isMicrophoneRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return micEngine != nil
    }

    public var activeInputDevice: AudioDevice? {
        microphone?.configuration.inputDevice ?? configuration.inputDevice
    }

    public var activeMicOutputDevice: AudioDevice? {
        microphone?.configuration.outputDevice ?? configuration.micOutputDevice
    }

    /// Loudest application, after its slider.
    public var applicationPeak: Float { mixerEngine.peak }

    /// Microphone level before RNNoise / gate (for Önce meter).
    public var microphoneInputPeak: Float { microphone?.chain.inputPeak ?? 0 }

    /// Microphone level after the chain, before monitoring is muted (for Sonra meter).
    public var microphonePeak: Float { microphone?.peak ?? 0 }

    /// End-to-end microphone latency estimate, in seconds.
    public var microphoneLatency: Double { microphone?.estimatedLatency ?? 0 }

    public var microphoneStats: RealtimeStats? { microphone?.stats }

    public var onTapCreated: (@Sendable (AppTap) -> Void)? {
        get { mixerEngine.onTapCreated }
        set { mixerEngine.onTapCreated = newValue }
    }

    private var microphone: MicEngine? {
        lock.lock()
        defer { lock.unlock() }
        return micEngine
    }

    // MARK: - Microphone

    /// Builds and starts the microphone chain onto `micOutputDevice` (if set) or `outputDevice`.
    public func startMicrophone(device: AudioDevice? = nil) throws {
        guard let input = device ?? configuration.inputDevice else {
            throw SessionError.microphoneUnavailable
        }
        if let device {
            configuration.inputDevice = device
        }
        let targetMicOutput = configuration.micOutputDevice ?? configuration.outputDevice
        guard let targetMicOutput else {
            throw SessionError.noOutputDevice
        }
        stopMicrophone()

        let dedicatedVirtualMic = configuration.micOutputDevice != nil
            && configuration.micOutputDevice?.uid != configuration.outputDevice?.uid

        var micConfiguration = MicEngine.Configuration(
            inputDevice: input,
            outputDevice: targetMicOutput
        )
        micConfiguration.denoiseEnabled = configuration.denoiseEnabled
        micConfiguration.denoiseStrength = configuration.denoiseStrength
        micConfiguration.gateEnabled = configuration.gateEnabled
        micConfiguration.gateThresholdDB = configuration.gateThresholdDB
        micConfiguration.gainDB = configuration.micGainDB
        // If writing to BlackHole, never mute BlackHole; self-monitoring goes via MonitorPlayback.
        micConfiguration.muteOutput = dedicatedVirtualMic ? false : !configuration.monitorMicrophone

        let ring: AudioRingBuffer? = dedicatedVirtualMic
            ? AudioRingBuffer(capacityFrames: 48_000, channels: 1)
            : nil
        micConfiguration.monitorRing = ring

        let engine = try MicEngine(configuration: micConfiguration)
        engine.chain.abBypass = configuration.abBypass
        try engine.start()

        var playback: MonitorPlayback?
        if dedicatedVirtualMic, configuration.monitorMicrophone,
           let ring, let monitorTarget = configuration.outputDevice {
            let player = try MonitorPlayback(device: monitorTarget, ring: ring)
            try player.start()
            playback = player
        }

        lock.lock()
        micEngine = engine
        monitorRing = ring
        monitorPlayback = playback
        lock.unlock()
        lastError = nil
    }

    public func stopMicrophone() {
        lock.lock()
        let engine = micEngine
        let playback = monitorPlayback
        micEngine = nil
        monitorPlayback = nil
        monitorRing = nil
        lock.unlock()
        playback?.stop()
        engine?.stop()
    }

    @discardableResult
    public func setMicrophoneSettings(
        denoise: Bool? = nil,
        strength: Float? = nil,
        gate: Bool? = nil,
        gateThresholdDB: Float? = nil,
        gainDB: Float? = nil,
        abBypass: Bool? = nil,
        monitor: Bool? = nil
    ) -> Bool {
        if let denoise { configuration.denoiseEnabled = denoise }
        if let strength { configuration.denoiseStrength = min(max(strength, 0), 1) }
        if let gate { configuration.gateEnabled = gate }
        if let gateThresholdDB { configuration.gateThresholdDB = gateThresholdDB }
        if let gainDB { configuration.micGainDB = gainDB }
        if let abBypass { configuration.abBypass = abBypass }
        if let monitor { configuration.monitorMicrophone = monitor }

        guard let engine = microphone else { return true }
        if let denoise { engine.chain.denoiseEnabled = denoise }
        if let strength { engine.chain.denoiseStrength = min(max(strength, 0), 1) }
        if let gate { engine.chain.gate.isEnabled = gate }
        if let gateThresholdDB { engine.chain.gate.thresholdDB = gateThresholdDB }
        if let gainDB { engine.chain.gain.setGain(decibels: gainDB) }
        if let abBypass { engine.chain.abBypass = abBypass }

        if let monitor {
            let dedicatedVirtualMic = configuration.micOutputDevice != nil
                && configuration.micOutputDevice?.uid != configuration.outputDevice?.uid
            if dedicatedVirtualMic {
                updateMonitorPlayback(enabled: monitor)
            } else {
                engine.isOutputMuted = !monitor
            }
        }
        return true
    }

    private func updateMonitorPlayback(enabled: Bool) {
        lock.lock()
        let existing = monitorPlayback
        let ring = monitorRing
        monitorPlayback = nil
        lock.unlock()
        existing?.stop()

        guard enabled, let ring, let target = configuration.outputDevice else { return }
        ring.removeAll()
        do {
            let player = try MonitorPlayback(device: target, ring: ring)
            try player.start()
            lock.lock()
            if micEngine != nil {
                monitorPlayback = player
            } else {
                player.stop()
            }
            lock.unlock()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func setMicOutputDevice(_ device: AudioDevice?) {
        guard device?.uid != configuration.micOutputDevice?.uid else { return }
        let wantsMicrophone = isMicrophoneRunning
        stopMicrophone()
        configuration.micOutputDevice = device
        if wantsMicrophone {
            do {
                try startMicrophone()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    public func setInputDevice(_ device: AudioDevice?) {
        guard device?.uid != configuration.inputDevice?.uid else { return }
        let wantsMicrophone = isMicrophoneRunning
        stopMicrophone()
        configuration.inputDevice = device
        if wantsMicrophone, device != nil {
            do {
                try startMicrophone(device: device)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Applications

    /// Follows the process list. Returns the taps it created, so a caller can
    /// apply per-application settings.
    @discardableResult
    public func syncApplications() -> [AppTap] {
        guard configuration.mixApplications else { return [] }
        return mixerEngine.sync()
    }

    public func setMasterGain(_ scalar: Float) {
        mixerEngine.setMasterGain(scalar)
    }

    public func setKeepSystemSoundsTap(_ keep: Bool) {
        configuration.keepSystemSoundsTap = keep
        mixerEngine.setKeepSystemSoundsTap(keep)
    }

    public func setPinnedKeys(_ keys: Set<String>) {
        mixerEngine.setPinnedKeys(keys)
    }

    public func setDucking(enabled: Bool, amountDB: Float = -10) {
        mixerEngine.duckingEnabled = enabled
        mixerEngine.duckingAmountDB = amountDB
    }

    public func setOutputDevice(_ device: AudioDevice?, forAppKey key: String) {
        mixerEngine.setOutputDevice(device, forAppKey: key)
    }

    public func outputOverride(forAppKey key: String) -> AudioDevice? {
        mixerEngine.outputOverride(forAppKey: key)
    }

    /// Keys that currently play on a dedicated output device.
    public var overriddenKeys: [String] { mixerEngine.overriddenKeys }

    public func stop() {
        stopMicrophone()
        mixerEngine.stop()
    }

    /// Moves the mixer (and monitor playback, or fallback mic) to another output device.
    public func setOutputDevice(_ device: AudioDevice?) {
        guard device?.uid != configuration.outputDevice?.uid else { return }
        let wantsMicrophone = isMicrophoneRunning
        let dedicatedVirtualMic = configuration.micOutputDevice != nil
            && configuration.micOutputDevice?.uid != configuration.outputDevice?.uid
        if !dedicatedVirtualMic {
            stopMicrophone()
        } else if configuration.monitorMicrophone {
            updateMonitorPlayback(enabled: false)
        }
        mixerEngine.stop()
        configuration.outputDevice = device
        mixerEngine.setOutputDevice(device)
        if wantsMicrophone {
            if !dedicatedVirtualMic {
                do {
                    try startMicrophone()
                } catch {
                    lastError = error.localizedDescription
                }
            } else if configuration.monitorMicrophone {
                updateMonitorPlayback(enabled: true)
            }
        }
    }
}
