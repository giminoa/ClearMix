import AudioToolbox
import CoreAudio
import Foundation

/// Observes Core Audio hardware topology and default-device changes on a
/// background queue so the UI can react immediately to headphone plug/unplug
/// or system default switches without polling.
public final class AudioHardwareMonitor: @unchecked Sendable {
    public enum Event: Sendable {
        case devicesChanged
        case defaultOutputChanged
        case defaultInputChanged
        case outputVolumeChanged
    }

    private let queue = DispatchQueue(label: "com.clearmix.hardware.monitor")
    private let handler: @Sendable (Event) -> Void
    private var isStarted = false

    private var observedVolumeDeviceID: AudioDeviceID = 0
    private var devicesBlock: AudioObjectPropertyListenerBlock?
    private var defaultOutputBlock: AudioObjectPropertyListenerBlock?
    private var defaultInputBlock: AudioObjectPropertyListenerBlock?
    private var volumeBlock: AudioObjectPropertyListenerBlock?
    private var muteBlock: AudioObjectPropertyListenerBlock?

    public init(handler: @escaping @Sendable (Event) -> Void) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        let system = AudioObjectID(kAudioObjectSystemObject)
        let cb = handler

        let devBlock: AudioObjectPropertyListenerBlock = { _, _ in cb(.devicesChanged) }
        let outBlock: AudioObjectPropertyListenerBlock = { _, _ in cb(.defaultOutputChanged) }
        let inBlock: AudioObjectPropertyListenerBlock = { _, _ in cb(.defaultInputChanged) }

        devicesBlock = devBlock
        defaultOutputBlock = outBlock
        defaultInputBlock = inBlock

        var devicesAddr = Self.systemAddress(kAudioHardwarePropertyDevices)
        var outAddr = Self.systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var inAddr = Self.systemAddress(kAudioHardwarePropertyDefaultInputDevice)

        AudioObjectAddPropertyListenerBlock(system, &devicesAddr, queue, devBlock)
        AudioObjectAddPropertyListenerBlock(system, &outAddr, queue, outBlock)
        AudioObjectAddPropertyListenerBlock(system, &inAddr, queue, inBlock)
    }

    public func observeOutputVolume(of deviceID: AudioDeviceID) {
        guard deviceID != observedVolumeDeviceID else { return }
        removeVolumeListeners()
        guard deviceID != 0 else { return }
        observedVolumeDeviceID = deviceID

        let cb = handler
        let vBlock: AudioObjectPropertyListenerBlock = { _, _ in cb(.outputVolumeChanged) }
        let mBlock: AudioObjectPropertyListenerBlock = { _, _ in cb(.outputVolumeChanged) }
        volumeBlock = vBlock
        muteBlock = mBlock

        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &volAddr) {
            AudioObjectAddPropertyListenerBlock(deviceID, &volAddr, queue, vBlock)
        }
        if AudioObjectHasProperty(deviceID, &muteAddr) {
            AudioObjectAddPropertyListenerBlock(deviceID, &muteAddr, queue, mBlock)
        }
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        let system = AudioObjectID(kAudioObjectSystemObject)

        if let devBlock = devicesBlock {
            var addr = Self.systemAddress(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(system, &addr, queue, devBlock)
        }
        if let outBlock = defaultOutputBlock {
            var addr = Self.systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(system, &addr, queue, outBlock)
        }
        if let inBlock = defaultInputBlock {
            var addr = Self.systemAddress(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(system, &addr, queue, inBlock)
        }
        devicesBlock = nil
        defaultOutputBlock = nil
        defaultInputBlock = nil
        removeVolumeListeners()
    }

    private func removeVolumeListeners() {
        guard observedVolumeDeviceID != 0 else { return }
        let dev = observedVolumeDeviceID
        if let vBlock = volumeBlock {
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(dev, &volAddr, queue, vBlock)
        }
        if let mBlock = muteBlock {
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(dev, &muteAddr, queue, mBlock)
        }
        volumeBlock = nil
        muteBlock = nil
        observedVolumeDeviceID = 0
    }

    private static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
