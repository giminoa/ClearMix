import AudioToolbox
import CoreAudio
import Foundation

/// One Core Audio device, with just the facts the microphone engine needs.
public struct AudioDevice: Hashable, Sendable {
    /// HAL object id; stable for the lifetime of the device.
    public let id: AudioDeviceID
    public let name: String
    /// Persistent UID. Survives reconnects, so settings should store this.
    public let uid: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let nominalSampleRate: Double
    public let transport: UInt32

    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }

    /// Buffer size the device uses, in frames. Reported for latency estimates.
    public var bufferFrameSize: Int {
        AudioDevices.bufferFrameSize(for: id)
    }

    public var isBlackHole: Bool {
        name.localizedCaseInsensitiveContains("BlackHole")
    }

    public var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

/// Device discovery and small HAL helpers.
public enum AudioDevices {
    /// Every device that has at least one input or output stream.
    public static func all() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { device(for: $0) }
    }

    public static func inputs() -> [AudioDevice] {
        all().filter(\.hasInput)
    }

    public static func outputs() -> [AudioDevice] {
        all().filter(\.hasOutput)
    }

    public static func device(for id: AudioDeviceID) -> AudioDevice? {
        guard let name = string(id, kAudioObjectPropertyName),
              let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDevice(
            id: id,
            name: name,
            uid: uid,
            inputChannels: channels(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: channels(id, scope: kAudioObjectPropertyScopeOutput),
            nominalSampleRate: nominalSampleRate(for: id) ?? 0,
            transport: UInt32(integer(id, kAudioDevicePropertyTransportType, default: 0))
        )
    }

    public static func defaultInput() -> AudioDevice? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    public static func defaultOutput() -> AudioDevice? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    public static func defaultSystemOutput() -> AudioDevice? {
        defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    public static func isAlive(deviceID: AudioDeviceID) -> Bool {
        integer(deviceID, kAudioDevicePropertyDeviceIsAlive, default: 0) != 0
    }

    /// True if the HAL exposes a hardware/virtual main volume control on the output device.
    public static func hasVolumeControl(for deviceID: AudioDeviceID) -> Bool {
        for element in volumeElements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceID, &address) {
                return true
            }
            address.mSelector = kAudioDevicePropertyVolumeScalar
            if AudioObjectHasProperty(deviceID, &address) {
                return true
            }
        }
        return false
    }

    /// Reads the output device's scalar volume (0...1), or nil if unavailable.
    public static func volume(for deviceID: AudioDeviceID) -> Float? {
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            for element in volumeElements {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: element
                )
                guard AudioObjectHasProperty(deviceID, &address) else { continue }
                var scalar: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &scalar) == noErr {
                    return min(max(scalar, 0), 1)
                }
            }
        }
        return nil
    }

    /// Sets the output device's scalar volume (0...1).
    @discardableResult
    public static func setVolume(_ scalar: Float, for deviceID: AudioDeviceID) -> Bool {
        let clamped = min(max(scalar, 0), 1)
        var succeeded = false
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            for element in volumeElements {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: element
                )
                guard AudioObjectHasProperty(deviceID, &address) else { continue }
                var settable = DarwinBoolean(false)
                guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
                      settable.boolValue else { continue }
                var value = Float32(clamped)
                if AudioObjectSetPropertyData(
                    deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
                ) == noErr {
                    succeeded = true
                    if selector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume {
                        return true
                    }
                }
            }
            if succeeded { return true }
        }
        return succeeded
    }

    public static func isMuted(for deviceID: AudioDeviceID) -> Bool? {
        for element in volumeElements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
                return value != 0
            }
        }
        return nil
    }

    @discardableResult
    public static func setMute(_ muted: Bool, for deviceID: AudioDeviceID) -> Bool {
        var succeeded = false
        for element in volumeElements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            var value: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(
                deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
            ) == noErr {
                succeeded = true
                if element == kAudioObjectPropertyElementMain { return true }
            }
        }
        return succeeded
    }

    private static let volumeElements: [AudioObjectPropertyElement] = [
        kAudioObjectPropertyElementMain, 1, 2
    ]

    /// BlackHole's 2-channel virtual microphone, if it is installed.
    public static func blackHole() -> AudioDevice? {
        outputs().first { $0.isBlackHole && $0.outputChannels == 2 }
            ?? outputs().first(where: \.isBlackHole)
    }

    /// Finds a device by exact name, UID, or a case-insensitive name fragment.
    public static func find(_ query: String, in devices: [AudioDevice]) -> AudioDevice? {
        if let exact = devices.first(where: { $0.name == query || $0.uid == query }) {
            return exact
        }
        return devices.first { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Sets the device's nominal sample rate. Needed because the engine runs the
    /// whole microphone chain at 48 kHz (RNNoise's frame rate).
    @discardableResult
    public static func setNominalSampleRate(_ rate: Double, for deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = rate
        return AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value
        ) == noErr
    }

    public static func bufferFrameSize(for deviceID: AudioDeviceID) -> Int {
        Int(integer(deviceID, kAudioDevicePropertyBufferFrameSize, default: 0))
    }

    /// Asks the device for a smaller IO buffer; returns the size that was set.
    @discardableResult
    public static func setBufferFrameSize(_ frames: Int, for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(frames)
        guard AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        ) == noErr else {
            return bufferFrameSize(for: deviceID)
        }
        return bufferFrameSize(for: deviceID)
    }

    // MARK: - HAL property helpers

    private static func defaultDevice(
        _ selector: AudioObjectPropertySelector
    ) -> AudioDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr, id != 0 else { return nil }
        return device(for: id)
    }

    static func string(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    static func nominalSampleRate(for objectID: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
              value > 0 else { return nil }
        return value
    }

    static func integer(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        default defaultValue: UInt32
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = defaultValue
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return defaultValue
        }
        return value
    }

    static func channels(
        _ objectID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
