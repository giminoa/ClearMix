import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Taps one application's audio and plays it back through an output device with
/// that application's own gain, mute and meter.
///
/// A tap is a HAL object holding the mixdown of one process. To read it and hear
/// it at the same time, the tap is bundled into a private aggregate device whose
/// main sub-device is the real output, and an AUHAL unit on that aggregate
/// captures the tap on its input side and writes to the device on its output
/// side. Each application therefore gets its own pair of callbacks, closely
/// clocked by the same device.
public final class AppTap: @unchecked Sendable {
    public enum TapError: LocalizedError {
        case tapCreationFailed(OSStatus)
        case aggregateFailed(OSStatus)
        case unitFailed(String, OSStatus)
        case formatUnavailable

        public var errorDescription: String? {
            switch self {
            case let .tapCreationFailed(status):
                return "Ses yakalama (tap) oluşturulamadı (OSStatus \(status)). Sistem sesi kaydı izni gerekebilir."
            case let .aggregateFailed(status):
                return "Toplu cihaz oluşturulamadı (OSStatus \(status))."
            case let .unitFailed(step, status):
                return "\(step) başarısız (OSStatus \(status))."
            case .formatUnavailable:
                return "Tap ses formatı okunamadı."
            }
        }
    }

    public let process: AudioProcess
    public let outputDevice: AudioDevice
    public let bus: MixerBus
    /// Rate of the tapped stream.
    public let tapSampleRate: Double
    /// Rate of the output device.
    public let outputSampleRate: Double

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private var unit: AudioUnit?

    /// Diagnostics for the CLI and UI: frames the tap delivered and the last error.
    public private(set) var capturedFrames = 0
    public private(set) var renderedFrames = 0
    public private(set) var capturedPeak: Float = 0
    public private(set) var renderCalls = 0
    public private(set) var captureCalls = 0
    public private(set) var nonZeroCaptureCalls = 0
    public private(set) var lastStatus: OSStatus = 0

    private let ring: AudioRingBuffer
    private let leftConverter: SampleRateConverter?
    private let rightConverter: SampleRateConverter?
    private let captureScratch: UnsafeMutablePointer<Float>
    private let renderScratch: UnsafeMutablePointer<Float>
    private let convertScratch: UnsafeMutablePointer<Float>
    private let planarInL: UnsafeMutablePointer<Float>
    private let planarInR: UnsafeMutablePointer<Float>
    private let planarOutL: UnsafeMutablePointer<Float>
    private let planarOutR: UnsafeMutablePointer<Float>
    private let maxFrames = 4_096
    private let convertCapacity = 8_192
    private let channels = 2

    public init(
        process: AudioProcess,
        output: AudioDevice,
        bus: MixerBus? = nil
    ) throws {
        guard output.hasOutput else {
            throw TapError.unitFailed("çıkış cihazı yok", -1)
        }
        self.process = process
        self.outputDevice = output
        self.outputSampleRate = output.nominalSampleRate

        let description = CATapDescription(
            stereoMixdownOfProcesses: [process.objectID]
        )
        description.name = "ClearMix \(process.name)"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped

        var createdTap: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTap)
        guard tapStatus == noErr, createdTap != 0 else {
            throw TapError.tapCreationFailed(tapStatus)
        }
        tapID = createdTap

        guard let tapUID = AudioDevices.string(tapID, kAudioTapPropertyUID) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw TapError.formatUnavailable
        }
        let tapFormat = Self.streamFormat(of: tapID)
        let tapRate = tapFormat?.mSampleRate ?? 48_000
        tapSampleRate = tapRate
        self.bus = bus ?? MixerBus(sampleRate: tapRate)

        guard let aggregate = Self.createAggregate(
            name: "ClearMix \(process.name)",
            outputUID: output.uid,
            tapUID: tapUID
        ) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw TapError.aggregateFailed(-1)
        }
        aggregateID = aggregate

        ring = AudioRingBuffer(capacityFrames: Int(tapRate / 4), channels: channels)
        if abs(tapRate - output.nominalSampleRate) > 0.5 {
            leftConverter = SampleRateConverter(
                inputRate: tapRate,
                outputRate: output.nominalSampleRate,
                maxFramesPerCall: maxFrames
            )
            rightConverter = SampleRateConverter(
                inputRate: tapRate,
                outputRate: output.nominalSampleRate,
                maxFramesPerCall: maxFrames
            )
        } else {
            leftConverter = nil
            rightConverter = nil
        }

        captureScratch = .allocate(capacity: maxFrames * channels)
        captureScratch.initialize(repeating: 0, count: maxFrames * channels)
        renderScratch = .allocate(capacity: maxFrames * channels)
        renderScratch.initialize(repeating: 0, count: maxFrames * channels)
        convertScratch = .allocate(capacity: convertCapacity * channels)
        convertScratch.initialize(repeating: 0, count: convertCapacity * channels)
        planarInL = .allocate(capacity: maxFrames)
        planarInL.initialize(repeating: 0, count: maxFrames)
        planarInR = .allocate(capacity: maxFrames)
        planarInR.initialize(repeating: 0, count: maxFrames)
        planarOutL = .allocate(capacity: convertCapacity)
        planarOutL.initialize(repeating: 0, count: convertCapacity)
        planarOutR = .allocate(capacity: convertCapacity)
        planarOutR.initialize(repeating: 0, count: convertCapacity)

        if ProcessInfo.processInfo.environment["CLEARMIX_DEBUG"] != nil {
            let aggregateInputs = AudioDevices.channels(
                aggregateID, scope: kAudioObjectPropertyScopeInput
            )
            var line = "tap \(Int(tapRate)) Hz, \(tapFormat?.mChannelsPerFrame ?? 0) kanal"
            if let tapFormat {
                let planar = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
                line += planar ? " planar" : " interleaved"
            }
            line += ", toplu giriş \(aggregateInputs) kanal"
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }

        do {
            try makeUnit(aggregateID: aggregateID, output: output, tapFormat: tapFormat)
        } catch {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            captureScratch.deallocate()
            renderScratch.deallocate()
            convertScratch.deallocate()
            planarInL.deallocate()
            planarInR.deallocate()
            planarOutL.deallocate()
            planarOutR.deallocate()
            throw error
        }
    }

    deinit {
        stop()
        if let unit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        captureScratch.deallocate()
        renderScratch.deallocate()
        convertScratch.deallocate()
        planarInL.deallocate()
        planarInR.deallocate()
        planarOutL.deallocate()
        planarOutR.deallocate()
    }

    public func start() throws {
        guard let unit else { return }
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw TapError.unitFailed("tap başlatılamadı", status)
        }
    }

    public func stop() {
        if let unit { AudioOutputUnitStop(unit) }
    }

    // MARK: - Unit

    private func makeUnit(
        aggregateID: AudioDeviceID,
        output: AudioDevice,
        tapFormat: AudioStreamBasicDescription?
    ) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw TapError.unitFailed("çıkış birimi bulunamadı", -1)
        }
        var instance: AudioUnit?
        let status = AudioComponentInstanceNew(component, &instance)
        guard status == noErr, let instance else {
            throw TapError.unitFailed("birim açılamadı", status)
        }
        unit = instance

        var enable: UInt32 = 1
        try Self.check(
            AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input, 1, &enable, 4),
            "tap girişi etkinleştirilemedi"
        )
        try Self.check(
            AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Output, 0, &enable, 4),
            "çıkış etkinleştirilemedi"
        )

        var device = aggregateID
        try Self.check(
            AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &device,
                                 UInt32(MemoryLayout<AudioDeviceID>.size)),
            "toplu cihaz seçilemedi"
        )

        // The tap hands out planar float; ask the unit for interleaved stereo so
        // the ring and the meters see one layout. AUHAL converts for us.
        var inputFormat = AudioStreamBasicDescription.floatPCM(
            sampleRate: tapFormat?.mSampleRate ?? tapSampleRate,
            channels: UInt32(channels)
        )
        try Self.check(
            AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output, 1, &inputFormat,
                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "tap formatı ayarlanamadı"
        )

        var outputFormat = AudioStreamBasicDescription.floatPCM(
            sampleRate: outputSampleRate,
            channels: UInt32(max(1, output.outputChannels))
        )
        try Self.check(
            AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input, 0, &outputFormat,
                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "çıkış formatı ayarlanamadı"
        )

        var slice = UInt32(maxFrames)
        try Self.check(
            AudioUnitSetProperty(instance, kAudioUnitProperty_MaximumFramesPerSlice,
                                 kAudioUnitScope_Global, 0, &slice,
                                 UInt32(MemoryLayout<UInt32>.size)),
            "blok boyu ayarlanamadı"
        )

        var inputCallback = AURenderCallbackStruct(
            inputProc: tapInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try Self.check(
            AudioUnitSetProperty(instance, kAudioOutputUnitProperty_SetInputCallback,
                                 kAudioUnitScope_Global, 0, &inputCallback,
                                 UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
            "tap geri çağrısı bağlanamadı"
        )

        var renderCallback = AURenderCallbackStruct(
            inputProc: tapRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try Self.check(
            AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback,
                                 kAudioUnitScope_Input, 0, &renderCallback,
                                 UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
            "çıkış geri çağrısı bağlanamadı"
        )

        try Self.check(AudioUnitInitialize(instance), "birim hazırlanamadı")
    }

    // MARK: - Callbacks

    func capture(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timestamp: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) -> OSStatus {
        guard let unit else { return noErr }
        let count = min(Int(frames), maxFrames)

        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(count * channels * MemoryLayout<Float>.stride),
                mData: UnsafeMutableRawPointer(captureScratch)
            )
        )
        let status = AudioUnitRender(unit, flags, timestamp, 1, frames, &list)
        guard status == noErr else {
            lastStatus = status
            return status
        }
        ring.write(captureScratch, frames: count)
        capturedFrames += count
        captureCalls += 1
        var peak: Float = 0
        vDSP_maxmgv(captureScratch, 1, &peak, vDSP_Length(count * channels))
        capturedPeak = peak
        if peak > 1e-6 {
            nonZeroCaptureCalls += 1
        }
        return noErr
    }

    func render(into ioData: UnsafeMutablePointer<AudioBufferList>?, frames: UInt32) -> OSStatus {
        guard let ioData else { return noErr }
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        let count = min(Int(frames), maxFrames)
        renderCalls += 1

        // Ask for enough tap frames to cover this device block.
        let wanted = leftConverter.map { min($0.inputFrames(forOutputFrames: count), maxFrames) }
            ?? count
        let read = ring.read(into: renderScratch, frames: wanted)
        renderedFrames += read
        if read < wanted {
            memset(
                renderScratch + read * channels,
                0,
                (wanted - read) * channels * MemoryLayout<Float>.stride
            )
        }

        // Gain, EQ and mute belong on the tap side: before any rate conversion,
        // and on the whole block including padding so the ramp stays smooth.
        bus.process(renderScratch, frames: wanted)

        let source: UnsafeMutablePointer<Float>
        let sourceFrames: Int
        if let leftConverter, let rightConverter {
            for frame in 0..<wanted {
                let idx = frame * channels
                planarInL[frame] = renderScratch[idx]
                planarInR[frame] = renderScratch[idx + 1]
            }
            let producedL = leftConverter.process(
                input: planarInL,
                inputFrames: wanted,
                output: planarOutL,
                maxOutputFrames: convertCapacity
            )
            let producedR = rightConverter.process(
                input: planarInR,
                inputFrames: wanted,
                output: planarOutR,
                maxOutputFrames: convertCapacity
            )
            let produced = max(0, min(producedL, producedR))
            for frame in 0..<produced {
                let idx = frame * channels
                convertScratch[idx] = planarOutL[frame]
                convertScratch[idx + 1] = planarOutR[frame]
            }
            source = convertScratch
            sourceFrames = produced
        } else {
            source = renderScratch
            sourceFrames = wanted
        }

        let available = min(sourceFrames, count)
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let out = data.assumingMemoryBound(to: Float.self)
            let bufferChannels = max(1, Int(buffer.mNumberChannels))
            if bufferChannels == 1 {
                // Mono device: take the left channel.
                for frame in 0..<count {
                    out[frame] = frame < available ? source[frame * channels] : 0
                }
            } else {
                for frame in 0..<count {
                    let base = frame * bufferChannels
                    for channel in 0..<bufferChannels {
                        out[base + channel] = frame < available
                            ? source[frame * channels + min(channel, channels - 1)]
                            : 0
                    }
                }
            }
        }
        return noErr
    }

    // MARK: - Helpers

    private static func createAggregate(
        name: String,
        outputUID: String,
        tapUID: String
    ) -> AudioDeviceID? {
        let tapList: [[String: Any]] = [[
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: 1,
        ]]
        let subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: outputUID]]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: "ClearMix.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: tapList,
        ]
        var aggregate: AudioDeviceID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr, aggregate != 0 else { return nil }
        return aggregate
    }

    private static func streamFormat(of objectID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &format) == noErr,
              format.mSampleRate > 0 else { return nil }
        return format
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw TapError.unitFailed(step, status) }
    }
}

private func tapInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let tap = Unmanaged<AppTap>.fromOpaque(inRefCon).takeUnretainedValue()
    return tap.capture(ioActionFlags, inTimeStamp, frames: inNumberFrames)
}

private func tapRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let tap = Unmanaged<AppTap>.fromOpaque(inRefCon).takeUnretainedValue()
    return tap.render(into: ioData, frames: inNumberFrames)
}
