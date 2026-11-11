import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Microphone engine: capture → 48 kHz chain → virtual microphone.
///
/// The two HAL units run on their own threads. Capture copies the device's
/// interleaved frames into a lock-free ring; the playback render callback drains
/// that ring through `MicChain` and fills the output buffer. Both callbacks only
/// touch preallocated memory.
///
/// The chain runs at 48 kHz (RNNoise's rate). BlackHole 2ch runs there natively;
/// any other output rate — a Bluetooth headset locked to 16 kHz, a 44.1 kHz
/// interface — is converted on the way out, so no device has to be reconfigured.
public final class MicEngine: @unchecked Sendable {
    public struct Configuration {
        public var inputDevice: AudioDevice
        public var outputDevice: AudioDevice
        public var denoiseEnabled = true
        public var denoiseStrength: Float = 1.0
        public var gateEnabled = false
        public var gateThresholdDB: Float = -45
        public var gainDB: Float = 0
        public var ceilingDB: Float = -1
        /// Capture ring length; absorbs scheduling jitter between the two devices.
        /// Kept small on purpose: a deep ring adds latency and, because the drift
        /// controller can only steer by a percent or so, takes a long time to
        /// work off after a stall.
        public var ringMilliseconds = 60
        /// Ring level the drift controller holds, in milliseconds. Smaller is
        /// lower latency, but leaves less room for scheduling jitter between
        /// the two devices.
        public var targetRingMilliseconds = 4
        /// IO buffer to ask the microphone for, in frames. The capture buffer is
        /// the biggest slice of the latency budget we can safely influence; it is
        /// a HAL-wide setting, so the device's original size is restored on stop.
        /// 0 leaves the device alone.
        public var inputBufferFrames = 256
        /// Optional monitor copy of the processed stream (48 kHz mono).
        public var monitorRing: AudioRingBuffer?
        /// Keep the device clock running but send silence to the output device.
        /// Without it, testing with the built-in speakers and microphone creates
        /// an acoustic feedback loop (the classic howl you hear in a call).
        public var muteOutput = false

        public init(inputDevice: AudioDevice, outputDevice: AudioDevice) {
            self.inputDevice = inputDevice
            self.outputDevice = outputDevice
        }
    }

    public enum EngineError: LocalizedError {
        case deviceMissingInput(String)
        case deviceMissingOutput(String)
        case chainUnavailable
        case unitFailure(String, OSStatus)

        public var errorDescription: String? {
            switch self {
            case let .deviceMissingInput(name):
                return "\(name) adlı cihazın girişi yok."
            case let .deviceMissingOutput(name):
                return "\(name) adlı cihazın çıkışı yok."
            case .chainUnavailable:
                return "RNNoise başlatılamadı."
            case let .unitFailure(step, status):
                return "\(step) başarısız (OSStatus \(status))."
            }
        }
    }

    public let configuration: Configuration
    public let chain: MicChain
    public let stats = RealtimeStats()
    /// Peak of the most recent block handed to the output device, after the
    /// chain and before muting. Read by the UI at its own pace.
    public private(set) var peak: Float = 0
    /// Silences the device output while the chain keeps running; the monitor
    /// ring (used for recording) still receives audio. Plain flag reads only, so
    /// the render callback can consult it.
    public var isOutputMuted: Bool = false

    public private(set) var inputSampleRate: Double = 0
    public private(set) var inputChannels: Int = 0
    /// Rate the output device actually runs at; differs from the chain's 48 kHz
    /// when the device cannot be switched.
    public private(set) var outputSampleRate: Double = MicChain.sampleRate

    private let captureRing: AudioRingBuffer
    private let captureScratch: UnsafeMutablePointer<Float>
    private let outputScratch: UnsafeMutablePointer<Float>
    private var captureUnit: CaptureUnit?
    private var playbackUnit: PlaybackUnit?
    private var hasReceivedInput = false
    /// Fractional read budget, so a 0.4 % correction still moves the rate
    /// instead of being rounded away every callback.
    private var readCredit = 0.0

    /// Frames the playback converter requests on top of the device period for
    /// its kernel; they are lookahead, not new audio.
    private var outputMarginFrames: Int {
        abs(outputSampleRate - MicChain.sampleRate) > 0.5 ? 32 : 0
    }

    private let maxCaptureFrames = 4_096
    /// Device buffer we replaced, so `stop()` can put it back.
    private var savedInputBufferFrames: Int?

    public init(configuration: Configuration) throws {
        guard configuration.inputDevice.hasInput else {
            throw EngineError.deviceMissingInput(configuration.inputDevice.name)
        }
        guard configuration.outputDevice.hasOutput else {
            throw EngineError.deviceMissingOutput(configuration.outputDevice.name)
        }
        self.configuration = configuration
        isOutputMuted = configuration.muteOutput

        let rate = configuration.inputDevice.nominalSampleRate
        let channels = configuration.inputDevice.inputChannels
        guard rate > 0, channels > 0 else {
            throw EngineError.deviceMissingInput(configuration.inputDevice.name)
        }
        inputSampleRate = rate
        inputChannels = channels

        guard let chain = MicChain(
            inputSampleRate: rate,
            channels: channels,
            maxInputFrames: maxCaptureFrames
        ) else {
            throw EngineError.chainUnavailable
        }
        self.chain = chain
        chain.denoiseEnabled = configuration.denoiseEnabled
        chain.denoiseStrength = configuration.denoiseStrength
        chain.gate.isEnabled = configuration.gateEnabled
        chain.gate.thresholdDB = configuration.gateThresholdDB
        chain.gain.setGain(decibels: configuration.gainDB)
        chain.gain.snapToTarget()
        chain.limiter.ceilingDB = configuration.ceilingDB

        let ringFrames = max(
            1_024,
            Int(rate * Double(configuration.ringMilliseconds) / 1_000)
        )
        captureRing = AudioRingBuffer(capacityFrames: ringFrames, channels: channels)
        let targetFrames = min(
            ringFrames / 2,
            max(1, Int(rate * Double(configuration.targetRingMilliseconds) / 1_000))
        )
        chain.targetFillFrames = targetFrames

        captureScratch = .allocate(capacity: maxCaptureFrames * channels)
        captureScratch.initialize(repeating: 0, count: maxCaptureFrames * channels)
        outputScratch = .allocate(capacity: 8_192)
        outputScratch.initialize(repeating: 0, count: 8_192)
    }

    deinit {
        stop()
        captureScratch.deallocate()
        outputScratch.deallocate()
    }

    public var isRunning: Bool {
        captureUnit != nil && playbackUnit != nil
    }

    /// Latency estimate in seconds: device input buffer, chain lookahead, the
    /// frames sitting in the capture ring, the chain backlog, and the device
    /// output buffer (plus a kernel if the output runs at another rate).
    public var estimatedLatency: Double {
        let inputBuffer = Double(configuration.inputDevice.bufferFrameSize) / max(inputSampleRate, 1)
        let chainLatency = Double(chain.latencyFrames) / MicChain.sampleRate
        let ring = Double(stats.snapshot.fillFrames) / max(inputSampleRate, 1)
        let backlog = Double(chain.pendingCount) / MicChain.sampleRate
        let rate = max(outputSampleRate, 1)
        let outputBuffer = Double(configuration.outputDevice.bufferFrameSize) / rate
        let outputKernel = abs(outputSampleRate - MicChain.sampleRate) > 0.5 ? 32 / rate : 0
        return inputBuffer + chainLatency + ring + backlog + outputBuffer + outputKernel
    }

    // MARK: - Control

    public func start() throws {
        guard !isRunning else { return }

        // Prefer 48 kHz (no conversion at all), but never refuse a device that
        // cannot leave its own rate: the playback unit resamples whatever it gets.
        var outputRate = configuration.outputDevice.nominalSampleRate
        if abs(outputRate - MicChain.sampleRate) > 0.5 {
            AudioDevices.setNominalSampleRate(MicChain.sampleRate, for: configuration.outputDevice.id)
            outputRate = AudioDevices.device(for: configuration.outputDevice.id)?.nominalSampleRate ?? outputRate
        }
        outputSampleRate = outputRate

        captureRing.removeAll()
        chain.reset()
        readCredit = 0
        stats.reset()
        hasReceivedInput = false

        // Before the capture unit starts, so the IO proc runs at the smaller size.
        if configuration.inputBufferFrames > 0 {
            let current = configuration.inputDevice.bufferFrameSize
            if current != configuration.inputBufferFrames {
                savedInputBufferFrames = current
                AudioDevices.setBufferFrameSize(
                    configuration.inputBufferFrames,
                    for: configuration.inputDevice.id
                )
            }
        }

        let capture = try CaptureUnit(
            deviceID: configuration.inputDevice.id,
            deviceRate: inputSampleRate,
            channels: inputChannels,
            maxFrames: maxCaptureFrames
        )
        capture.sink = { [unowned self] samples, frames in
            self.receive(samples, frames: frames)
        }

        let playback = try PlaybackUnit(
            deviceID: configuration.outputDevice.id,
            sampleRate: outputRate,
            channels: max(1, configuration.outputDevice.outputChannels)
        )
        playback.provider = { [unowned self] destination, frames in
            self.render(frames: frames, into: destination)
        }

        captureUnit = capture
        playbackUnit = playback
        do {
            try capture.start()
            try playback.start()
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        playbackUnit?.stop()
        captureUnit?.stop()
        playbackUnit = nil
        captureUnit = nil
        // The buffer size belongs to the device, not to us: hand it back.
        if let saved = savedInputBufferFrames {
            AudioDevices.setBufferFrameSize(saved, for: configuration.inputDevice.id)
            savedInputBufferFrames = nil
        }
    }

    // MARK: - Realtime side

    /// Called on the capture thread with interleaved device frames.
    private func receive(_ samples: UnsafePointer<Float>, frames: Int) {
        let written = captureRing.write(samples, frames: frames)
        if written < frames {
            stats.recordOverrun(frames: frames - written)
        }
        if written > 0 { hasReceivedInput = true }
        let fill = captureRing.availableToRead
        stats.setFill(frames: fill)
        chain.setCaptureFill(fill)
    }

    /// Called on the playback thread. Fills `frames` mono samples, padding with
    /// silence when the capture side has not caught up yet.
    ///
    /// Only the deficit is pulled from the capture ring: draining it in large
    /// chunks would leave the chain holding seconds' worth of audio (latency)
    /// and make the ring level swing by the chunk size, which the drift
    /// controller would read as clock drift.
    private func render(frames: Int, into destination: UnsafeMutablePointer<Float>) -> Int {
        // Feed a fixed amount per callback: exactly the frames this callback is
        // about to play, scaled by the drift step. Following the instantaneous
        // deficit instead locks the loop up, because a partially filled RNNoise
        // block makes the deficit collapse and the ring never drains.
        // `frames` are chain (48 kHz) frames and may include the playback
        // converter's kernel margin, which needs no new input. The ring holds
        // device-rate frames, so convert the count before reading it.
        let margin = outputMarginFrames
        let needed = max(0, frames - margin)
        let inputPerOutput = inputSampleRate / MicChain.sampleRate
        readCredit += Double(needed) * chain.driftStep * inputPerOutput
        let wanted = min(Int(readCredit), maxCaptureFrames)
        let read = wanted > 0 ? captureRing.read(into: captureScratch, frames: wanted) : 0
        readCredit -= Double(read)
        if read > 0 {
            chain.setCaptureFill(captureRing.availableToRead)
            chain.process(captureScratch, frames: read)
            stats.recordFrames(input: read, output: 0)
            stats.setFill(frames: captureRing.availableToRead)
        }

        let produced = chain.pull(into: destination, maxFrames: frames)
        if produced < frames {
            memset(destination + produced, 0, (frames - produced) * MemoryLayout<Float>.stride)
            // Only a shortfall past the margin is audio the listener should have
            // heard now; the margin is lookahead the converter has not asked for.
            let shortfall = frames - margin - produced
            if hasReceivedInput, shortfall > 0 {
                stats.recordUnderrun(frames: shortfall)
            }
        }
        if let monitor = configuration.monitorRing {
            monitor.write(destination, frames: frames)
        }
        var blockPeak: Float = 0
        vDSP_maxmgv(destination, 1, &blockPeak, vDSP_Length(frames))
        peak = blockPeak
        if isOutputMuted {
            memset(destination, 0, frames * MemoryLayout<Float>.stride)
        }
        stats.recordFrames(input: 0, output: frames)
        return frames
    }
}

// MARK: - Capture unit

private func captureRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let unit = Unmanaged<CaptureUnit>.fromOpaque(inRefCon).takeUnretainedValue()
    return unit.render(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames)
}

/// HAL input unit. Delivers interleaved 32-bit float frames at the device rate.
private final class CaptureUnit {
    private var unit: AudioUnit?
    private let channels: Int
    private let maxFrames: Int
    private let sampleData: UnsafeMutablePointer<Float>
    private let bufferList: UnsafeMutableAudioBufferListPointer
    var sink: ((UnsafePointer<Float>, Int) -> Void)?

    init(deviceID: AudioDeviceID, deviceRate: Double, channels: Int, maxFrames: Int) throws {
        self.channels = channels
        self.maxFrames = maxFrames
        sampleData = .allocate(capacity: maxFrames * channels)
        bufferList = AudioBufferList.allocate(maximumBuffers: 1)
        bufferList[0].mNumberChannels = UInt32(channels)
        bufferList[0].mDataByteSize = UInt32(maxFrames * channels * MemoryLayout<Float>.stride)
        bufferList[0].mData = UnsafeMutableRawPointer(sampleData)

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw MicEngine.EngineError.unitFailure("Ses giriş birimi bulunamadı", -1)
        }
        var instance: AudioUnit?
        let status = AudioComponentInstanceNew(component, &instance)
        guard status == noErr, let instance else {
            throw MicEngine.EngineError.unitFailure("Giriş birimi açılamadı", status)
        }
        unit = instance

        do {
            var enable: UInt32 = 1
            var disable: UInt32 = 0
            try Self.check(
                AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Input, 1, &enable, 4),
                "giriş etkinleştirilemedi"
            )
            try Self.check(
                AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Output, 0, &disable, 4),
                "giriş biriminin çıkışı kapatılamadı"
            )
            var device = deviceID
            try Self.check(
                AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global, 0, &device,
                                     UInt32(MemoryLayout<AudioDeviceID>.size)),
                "giriş cihazı seçilemedi"
            )

            var format = AudioStreamBasicDescription.floatPCM(
                sampleRate: deviceRate,
                channels: UInt32(channels)
            )
            try Self.check(
                AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat,
                                     kAudioUnitScope_Output, 1, &format,
                                     UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                "giriş formatı ayarlanamadı"
            )

            var maxSlice = UInt32(maxFrames)
            try Self.check(
                AudioUnitSetProperty(instance, kAudioUnitProperty_MaximumFramesPerSlice,
                                     kAudioUnitScope_Global, 0, &maxSlice,
                                     UInt32(MemoryLayout<UInt32>.size)),
                "giriş blok boyu ayarlanamadı"
            )

            var callback = AURenderCallbackStruct(
                inputProc: captureRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try Self.check(
                AudioUnitSetProperty(instance, kAudioOutputUnitProperty_SetInputCallback,
                                     kAudioUnitScope_Global, 0, &callback,
                                     UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                "giriş geri çağrısı bağlanamadı"
            )

            try Self.check(AudioUnitInitialize(instance), "giriş birimi hazırlanamadı")
        } catch {
            AudioComponentInstanceDispose(instance)
            unit = nil
            sampleData.deallocate()
            throw error
        }
    }

    deinit {
        if let unit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        sampleData.deallocate()
    }

    func start() throws {
        guard let unit else { return }
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw MicEngine.EngineError.unitFailure("Giriş başlatılamadı", status)
        }
    }

    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
        }
    }

    func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timestamp: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32,
        _ frames: UInt32
    ) -> OSStatus {
        guard let unit else { return noErr }
        bufferList[0].mDataByteSize = frames * UInt32(channels * MemoryLayout<Float>.stride)
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, bufferList.unsafeMutablePointer)
        guard status == noErr else { return status }
        sink?(sampleData, Int(frames))
        return noErr
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            throw MicEngine.EngineError.unitFailure(step, status)
        }
    }
}

// MARK: - Playback unit

private func playbackRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let unit = Unmanaged<PlaybackUnit>.fromOpaque(inRefCon).takeUnretainedValue()
    return unit.render(ioData, frames: inNumberFrames)
}

/// HAL output unit. Pulls mono 48 kHz frames, converts them to the device rate
/// when needed, and sends them to every channel, so a stereo virtual device
/// receives the same clean signal on both sides.
private final class PlaybackUnit {
    private var unit: AudioUnit?
    private let channels: Int
    private let maxFrames = 8_192
    private let mono: UnsafeMutablePointer<Float>
    /// Chain-rate frames pulled from the provider before conversion.
    private let source: UnsafeMutablePointer<Float>
    private let converter: SampleRateConverter?
    var provider: ((UnsafeMutablePointer<Float>, Int) -> Int)?

    init(deviceID: AudioDeviceID, sampleRate: Double, channels: Int) throws {
        self.channels = channels
        mono = .allocate(capacity: maxFrames)
        mono.initialize(repeating: 0, count: maxFrames)
        source = .allocate(capacity: maxFrames)
        source.initialize(repeating: 0, count: maxFrames)
        if abs(sampleRate - MicChain.sampleRate) > 0.5 {
            converter = SampleRateConverter(
                inputRate: MicChain.sampleRate,
                outputRate: sampleRate,
                maxFramesPerCall: maxFrames
            )
        } else {
            converter = nil
        }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw MicEngine.EngineError.unitFailure("Ses çıkış birimi bulunamadı", -1)
        }
        var instance: AudioUnit?
        let status = AudioComponentInstanceNew(component, &instance)
        guard status == noErr, let instance else {
            throw MicEngine.EngineError.unitFailure("Çıkış birimi açılamadı", status)
        }
        unit = instance

        do {
            var enable: UInt32 = 1
            var disable: UInt32 = 0
            try Self.check(
                AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Output, 0, &enable, 4),
                "çıkış etkinleştirilemedi"
            )
            try Self.check(
                AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Input, 1, &disable, 4),
                "çıkış biriminin girişi kapatılamadı"
            )
            var device = deviceID
            try Self.check(
                AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global, 0, &device,
                                     UInt32(MemoryLayout<AudioDeviceID>.size)),
                "çıkış cihazı seçilemedi"
            )

            var format = AudioStreamBasicDescription.floatPCM(
                sampleRate: sampleRate,
                channels: UInt32(channels)
            )
            try Self.check(
                AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat,
                                     kAudioUnitScope_Input, 0, &format,
                                     UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                "çıkış formatı ayarlanamadı"
            )

            var callback = AURenderCallbackStruct(
                inputProc: playbackRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try Self.check(
                AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback,
                                     kAudioUnitScope_Input, 0, &callback,
                                     UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                "çıkış geri çağrısı bağlanamadı"
            )

            try Self.check(AudioUnitInitialize(instance), "çıkış birimi hazırlanamadı")
        } catch {
            AudioComponentInstanceDispose(instance)
            unit = nil
            mono.deallocate()
            source.deallocate()
            throw error
        }
    }

    deinit {
        if let unit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        mono.deallocate()
        source.deallocate()
    }

    func start() throws {
        guard let unit else { return }
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw MicEngine.EngineError.unitFailure("Çıkış başlatılamadı", status)
        }
    }

    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
        }
    }

    func render(_ ioData: UnsafeMutablePointer<AudioBufferList>?, frames: UInt32) -> OSStatus {
        guard let ioData else { return noErr }
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        let count = min(Int(frames), maxFrames)

        if let converter {
            let wanted = min(converter.inputFrames(forOutputFrames: count), maxFrames)
            let got = provider?(source, wanted) ?? 0
            if got < wanted {
                memset(source + got, 0, (wanted - got) * MemoryLayout<Float>.stride)
            }
            var produced = converter.process(
                input: source,
                inputFrames: wanted,
                output: mono,
                maxOutputFrames: count
            )
            if produced < 0 { produced = 0 }
            if produced < count {
                memset(mono + produced, 0, (count - produced) * MemoryLayout<Float>.stride)
            }
        } else {
            let produced = provider?(mono, count) ?? 0
            if produced < count {
                memset(mono + produced, 0, (count - produced) * MemoryLayout<Float>.stride)
            }
        }

        for buffer in list {
            guard let data = buffer.mData else { continue }
            let out = data.assumingMemoryBound(to: Float.self)
            let bufferChannels = max(1, Int(buffer.mNumberChannels))
            if bufferChannels == 1 {
                out.update(from: mono, count: count)
            } else {
                for frame in 0..<count {
                    let value = mono[frame]
                    let base = frame * bufferChannels
                    for channel in 0..<bufferChannels {
                        out[base + channel] = value
                    }
                }
            }
        }
        return noErr
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            throw MicEngine.EngineError.unitFailure(step, status)
        }
    }
}

/// Plays a 48 kHz mono `AudioRingBuffer` (such as `MicEngine`'s `monitorRing`)
/// to a monitoring output device (headphones/speakers) independently of the
/// virtual microphone output.
public final class MonitorPlayback: @unchecked Sendable {
    private let unit: PlaybackUnit
    private let ring: AudioRingBuffer
    public let device: AudioDevice

    public init(device: AudioDevice, ring: AudioRingBuffer) throws {
        guard device.hasOutput else {
            throw MicEngine.EngineError.deviceMissingOutput(device.name)
        }
        self.device = device
        self.ring = ring
        let rate = device.nominalSampleRate > 0 ? device.nominalSampleRate : MicChain.sampleRate
        unit = try PlaybackUnit(
            deviceID: device.id,
            sampleRate: rate,
            channels: max(1, device.outputChannels)
        )
        unit.provider = { [weak self] destination, frames in
            guard let self else { return 0 }
            let available = self.ring.availableToRead
            // Keep latency small on monitor: drop stale excess if needed.
            if available > 4_800 {
                let discard = available - 960
                _ = self.ring.read(into: destination, frames: min(discard, frames))
            }
            return self.ring.read(into: destination, frames: frames)
        }
    }

    deinit {
        stop()
    }

    public func start() throws {
        try unit.start()
    }

    public func stop() {
        unit.stop()
    }
}

extension AudioStreamBasicDescription {
    static func floatPCM(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        let bytesPerFrame = channels * UInt32(MemoryLayout<Float>.stride)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
