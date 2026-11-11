import AppKit
import AVFoundation
import ClearMixCore
import CoreAudio
import Foundation
import ServiceManagement
import SwiftUI
import os

/// Main-thread state coordinator for the ClearMix menu bar app.
///
/// Separates structural row updates from high-frequency audio meters and slider
/// drags so dragging a volume fader never stutters when background sync ticks.
@MainActor
final class MixerStore: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: AudioObjectID
        let key: String
        let name: String
        let pid: pid_t
        let isSystemSounds: Bool
        let isPinned: Bool
        let outputDeviceUID: String?
        let outputDeviceName: String
        let icon: NSImage?
        let tap: AppTap
        var controlRevision: Int

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.id == rhs.id
                && lhs.key == rhs.key
                && lhs.name == rhs.name
                && lhs.isPinned == rhs.isPinned
                && lhs.outputDeviceUID == rhs.outputDeviceUID
                && lhs.outputDeviceName == rhs.outputDeviceName
                && lhs.controlRevision == rhs.controlRevision
        }
    }

    enum Tab: String, CaseIterable {
        case sounds
        case microphone
    }

    @Published var selectedTab: Tab = .sounds
    @Published var showingSettings = false
    @Published var showingSetupWizard = false
    @Published var setupWizardStep = 1
    @Published var showingEQForKey: String?

    @Published private(set) var rows: [Row] = []
    @Published private(set) var availableOutputs: [AudioDevice] = []
    @Published private(set) var availableInputs: [AudioDevice] = []
    @Published private(set) var blackHoleDevice: AudioDevice?
    @Published private(set) var activeOutputDevice: AudioDevice?
    @Published private(set) var deviceName = "Çıkış yok"
    @Published private(set) var lastError: String?
    @Published private(set) var playingCount = 0
    @Published private(set) var suspectedCaptureSilence = false
    @Published private(set) var microphoneAuthorized = false

    @Published var masterVolume: Float = 1.0
    @Published var masterMuted: Bool = false
    @Published var masterHasHardwareControl: Bool = false

    @Published private(set) var settings: ClearMixSettings
    @Published private(set) var isMicrophoneRunning = false
    @Published private(set) var isABComparing = false
    @Published private(set) var isMonitoringMic = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var isInstallingBlackHole = false
    @Published private(set) var blackHoleInstallMessage: String?

    private let session: MixSession
    private let settingsStore = SettingsStore()
    private let syncQueue = DispatchQueue(label: "com.clearmix.mixer.sync", qos: .userInitiated)
    private var hardwareMonitor: AudioHardwareMonitor?
    private var hotkeys: GlobalHotkeys?
    private var syncTimer: Timer?
    private var saveWorkItem: DispatchWorkItem?
    private var isSyncing = false
    private var started = false
    private var controlRevision = 0
    private var lastLoggedRows = -1
    private var lastWantedMicOnDisconnect = false

    private static let log = Logger(subsystem: "com.clearmix.ui", category: "mixer")
    private static let verbose = ProcessInfo.processInfo.environment["CLEARMIX_DEBUG"] != nil

    static let shared = MixerStore()

    init() {
        let loaded = settingsStore.load()
        self.settings = loaded

        let outputs = AudioDevices.outputs()
        let initialOutput: AudioDevice?
        if let uid = loaded.preferredOutputDeviceUID,
           let preferred = outputs.first(where: { $0.uid == uid }) {
            initialOutput = preferred
        } else {
            initialOutput = AudioDevices.defaultOutput() ?? outputs.first
        }

        let inputs = AudioDevices.inputs().filter { !$0.isBlackHole }
        let initialInput: AudioDevice?
        if let uid = loaded.preferredInputDeviceUID,
           let preferred = inputs.first(where: { $0.uid == uid }) {
            initialInput = preferred
        } else {
            initialInput = AudioDevices.defaultInput() ?? inputs.first
        }

        let blackHole = AudioDevices.blackHole()
        var config = MixSession.Configuration(
            inputDevice: initialInput,
            outputDevice: initialOutput,
            micOutputDevice: blackHole
        )
        config.denoiseEnabled = loaded.denoiseEnabled
        config.denoiseStrength = loaded.denoiseStrength
        config.gateEnabled = loaded.gateEnabled
        config.gateThresholdDB = loaded.gateThresholdDB
        config.micGainDB = loaded.micGainDB
        // Never blast speakers on startup when BlackHole is missing.
        config.monitorMicrophone = false
        config.keepSystemSoundsTap = loaded.keepSystemSoundsTap

        let createdSession = MixSession(configuration: config)
        createdSession.setDucking(enabled: loaded.duckingEnabled, amountDB: loaded.duckingAmountDB)
        createdSession.setPinnedKeys(Set(loaded.apps.filter(\.value.isPinned).keys))
        self.session = createdSession

        // Apply saved per-app settings right when a tap is created.
        let snapshotSettings = loaded
        createdSession.onTapCreated = { tap in
            let key = tap.process.persistenceKey
            snapshotSettings.apps[key]?.apply(to: tap.bus)
        }

        // Apply saved per-app output device overrides.
        for (key, rule) in loaded.apps {
            if let uid = rule.outputDeviceUID,
               let device = outputs.first(where: { $0.uid == uid }) {
                createdSession.setOutputDevice(device, forAppKey: key)
            }
        }

        refreshDeviceLists(initialOutput: initialOutput)
        refreshLaunchAtLoginState()
        refreshPermissionStatus()
        showingSetupWizard = !loaded.onboardingCompleted
    }

    var lang: ClearMixSettings.Language { settings.language }
    var microphoneInputPeak: Float { session.microphoneInputPeak }
    var microphonePeak: Float { session.microphonePeak }
    var microphoneLatencyMilliseconds: Int { Int(session.microphoneLatency * 1_000) }

    var isCurrentInputBluetooth: Bool {
        if let uid = settings.preferredInputDeviceUID,
           let dev = availableInputs.first(where: { $0.uid == uid }) {
            return dev.isBluetooth
        }
        return (AudioDevices.defaultInput() ?? availableInputs.first)?.isBluetooth ?? false
    }

    var needsAudioCapturePermission: Bool {
        rows.isEmpty && playingCount > 0
    }

    var allMuted: Bool {
        !rows.isEmpty && rows.allSatisfy(\.tap.bus.isMuted)
    }

    var menuBarIconName: String {
        if isMicrophoneRunning {
            return "waveform.badge.mic"
        }
        if masterMuted || allMuted {
            return "speaker.slash.fill"
        }
        return "waveform"
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        installHardwareMonitor()
        installHotkeys()
        performSync()

        if CommandLine.arguments.contains("--mic") {
            toggleMicrophone()
        }

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.performSync() }
        }
        timer.tolerance = 0.2
        syncTimer = timer
    }

    func stop() {
        flushSettings()
        syncTimer?.invalidate()
        syncTimer = nil
        hardwareMonitor?.stop()
        hardwareMonitor = nil
        hotkeys?.unregisterAll()
        hotkeys = nil
        session.stop()
    }

    private func installHotkeys() {
        let manager = GlobalHotkeys { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggleMasterMute:
                self.toggleMasterMute()
            case .toggleMicrophone:
                self.toggleMicrophone()
            case .toggleDenoise:
                self.setDenoiseEnabled(!self.settings.denoiseEnabled)
            }
        }
        manager.setEnabled(settings.globalHotkeysEnabled)
        hotkeys = manager
    }

    private func installHardwareMonitor() {
        let monitor = AudioHardwareMonitor { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleHardwareEvent(event)
            }
        }
        monitor.start()
        if let id = activeOutputDevice?.id {
            monitor.observeOutputVolume(of: id)
        }
        hardwareMonitor = monitor
    }

    private func handleHardwareEvent(_ event: AudioHardwareMonitor.Event) {
        switch event {
        case .outputVolumeChanged:
            syncMasterVolumeFromDevice()
        case .devicesChanged, .defaultOutputChanged, .defaultInputChanged:
            refreshDeviceLists(initialOutput: nil)
            reconnectMicrophoneIfNeeded()
            performSync()
        }
    }

    // MARK: - Sync

    func refreshNow() {
        refreshPermissionStatus()
        refreshDeviceLists(initialOutput: nil)
        performSync()
    }

    private func refreshDeviceLists(initialOutput: AudioDevice?) {
        let outputs = AudioDevices.outputs()
        let inputs = AudioDevices.inputs().filter { !$0.isBlackHole }
        let blackHole = AudioDevices.blackHole()

        availableOutputs = outputs
        availableInputs = inputs
        blackHoleDevice = blackHole
        if session.configuration.micOutputDevice?.uid != blackHole?.uid {
            session.setMicOutputDevice(blackHole)
        }

        let targetOutput: AudioDevice?
        if let initialOutput {
            targetOutput = initialOutput
        } else if let prefUID = settings.preferredOutputDeviceUID,
                  let found = outputs.first(where: { $0.uid == prefUID }) {
            targetOutput = found
        } else {
            targetOutput = AudioDevices.defaultOutput() ?? outputs.first
        }

        activeOutputDevice = targetOutput
        deviceName = targetOutput?.name ?? L10n.text("Çıkış yok", "No output", lang: lang)
        if let targetOutput {
            hardwareMonitor?.observeOutputVolume(of: targetOutput.id)
        }
        syncMasterVolumeFromDevice()
    }

    private func performSync() {
        guard !isSyncing else { return }
        isSyncing = true

        let desiredOutput: AudioDevice?
        if let prefUID = settings.preferredOutputDeviceUID,
           let preferred = availableOutputs.first(where: { $0.uid == prefUID }) {
            desiredOutput = preferred
        } else {
            desiredOutput = AudioDevices.defaultOutput() ?? availableOutputs.first
        }

        let session = self.session
        let currentSettings = self.settings

        syncQueue.async { [weak self] in
            if let desiredOutput, desiredOutput.uid != session.configuration.outputDevice?.uid {
                session.setOutputDevice(desiredOutput)
            }

            let created = session.syncApplications()
            for tap in created {
                let key = tap.process.persistenceKey
                currentSettings.apps[key]?.apply(to: tap.bus)
            }

            let taps = session.taps
            let playing = AudioProcesses.playingOutput().count
            let error = session.lastError ?? session.applicationError
            let outputDev = session.configuration.outputDevice
            let micRunning = session.isMicrophoneRunning

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSyncing = false
                self.playingCount = playing
                self.lastError = error
                self.isMicrophoneRunning = micRunning
                if let outputDev {
                    self.activeOutputDevice = outputDev
                    self.deviceName = outputDev.name
                }
                self.rebuildRowsIfChanged(from: taps)
                self.suspectedCaptureSilence = self.detectCaptureSilence(taps: taps)
                self.logState()
            }
        }
    }

    private func detectCaptureSilence(taps: [AppTap]) -> Bool {
        let activePlaying = taps.filter(\.process.isRunningOutput)
        guard !activePlaying.isEmpty else { return false }
        return activePlaying.allSatisfy { $0.captureCalls > 60 && $0.nonZeroCaptureCalls == 0 }
    }

    private func rebuildRowsIfChanged(from taps: [AppTap]) {
        let pinnedKeys = Set(settings.apps.filter(\.value.isPinned).keys)
        let newRows: [Row] = taps.map { tap in
            let key = tap.process.persistenceKey
            let displayName = tap.process.isSystemSoundDaemon
                ? L10n.text("Sistem Sesleri", "System Sounds", lang: lang)
                : tap.process.name
            let rule = settings.apps[key]
            return Row(
                id: tap.process.objectID,
                key: key,
                name: displayName,
                pid: tap.process.pid,
                isSystemSounds: tap.process.isSystemSoundDaemon,
                isPinned: pinnedKeys.contains(key),
                outputDeviceUID: rule?.outputDeviceUID,
                outputDeviceName: tap.outputDevice.name,
                icon: resolveIcon(for: tap.process),
                tap: tap,
                controlRevision: controlRevision
            )
        }
        .sorted { lhs, rhs in
            if lhs.isSystemSounds != rhs.isSystemSounds {
                return !lhs.isSystemSounds
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        if newRows != rows {
            rows = newRows
        }
    }

    private func resolveIcon(for process: AudioProcess) -> NSImage? {
        if process.isSystemSoundDaemon {
            return NSImage(systemSymbolName: "bell.badge.waveform", accessibilityDescription: nil)
        }
        if let bundleID = process.appBundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = app.icon {
            return icon
        }
        if let app = NSRunningApplication(processIdentifier: process.pid),
           let icon = app.icon {
            return icon
        }
        if let bundleID = process.appBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    // MARK: - Master Volume & Output Device

    func selectMainOutputDevice(_ device: AudioDevice?) {
        settings.preferredOutputDeviceUID = device?.uid
        saveSettingsSoon()

        let target = device ?? AudioDevices.defaultOutput() ?? availableOutputs.first
        activeOutputDevice = target
        deviceName = target?.name ?? L10n.text("Çıkış yok", "No output", lang: lang)
        if let target {
            hardwareMonitor?.observeOutputVolume(of: target.id)
        }

        let session = self.session
        syncQueue.async { [weak self] in
            session.setOutputDevice(target)
            Task { @MainActor [weak self] in
                self?.syncMasterVolumeFromDevice()
                self?.performSync()
            }
        }
    }

    private func syncMasterVolumeFromDevice() {
        guard let dev = activeOutputDevice else {
            masterHasHardwareControl = false
            return
        }
        let hasHW = AudioDevices.hasVolumeControl(for: dev.id)
        masterHasHardwareControl = hasHW
        if hasHW {
            if let vol = AudioDevices.volume(for: dev.id) {
                masterVolume = vol
                settings.masterVolume = vol
            }
            if let muted = AudioDevices.isMuted(for: dev.id) {
                masterMuted = muted
                settings.masterMuted = muted
            }
            session.setMasterGain(1.0)
        } else {
            masterVolume = settings.masterVolume
            masterMuted = settings.masterMuted
            session.setMasterGain(masterMuted ? 0 : masterVolume)
        }
    }

    func setMasterVolume(_ scalar: Float) {
        let clamped = min(max(scalar, 0), 1)
        masterVolume = clamped
        settings.masterVolume = clamped
        if clamped > 0 && masterMuted {
            masterMuted = false
            settings.masterMuted = false
        }

        if let dev = activeOutputDevice, AudioDevices.hasVolumeControl(for: dev.id) {
            AudioDevices.setVolume(clamped, for: dev.id)
            if clamped > 0 { AudioDevices.setMute(false, for: dev.id) }
            session.setMasterGain(1.0)
        } else {
            session.setMasterGain(masterMuted ? 0 : clamped)
        }
        saveSettingsSoon()
    }

    func toggleMasterMute() {
        let next = !masterMuted
        masterMuted = next
        settings.masterMuted = next
        if let dev = activeOutputDevice, AudioDevices.hasVolumeControl(for: dev.id) {
            if !AudioDevices.setMute(next, for: dev.id) {
                session.setMasterGain(next ? 0 : 1)
            }
        } else {
            session.setMasterGain(next ? 0 : masterVolume)
        }
        saveSettingsSoon()
    }

    // MARK: - Per-App Controls

    func setGain(for row: Row, percent: Float) {
        let clamped = min(max(percent, 0), 200)
        row.tap.bus.setGain(percent: clamped)
        var rule = settings.apps[row.key] ?? ClearMixSettings.AppRule()
        rule.gainPercent = clamped
        rule.isMuted = false
        settings.apps[row.key] = rule
        saveSettingsSoon()
    }

    func resetGain(for row: Row) {
        setGain(for: row, percent: 100)
        bumpControls()
    }

    func toggleMute(for row: Row) {
        row.tap.bus.toggleMute()
        var rule = settings.apps[row.key] ?? ClearMixSettings.AppRule()
        rule.isMuted = row.tap.bus.isMuted
        settings.apps[row.key] = rule
        bumpControls()
        saveSettingsSoon()
    }

    func togglePin(for row: Row) {
        var rule = settings.apps[row.key] ?? ClearMixSettings.AppRule()
        rule.isPinned.toggle()
        settings.apps[row.key] = rule
        session.setPinnedKeys(Set(settings.apps.filter(\.value.isPinned).keys))
        bumpControls()
        saveSettingsSoon()
        performSync()
    }

    func setAppOutputDevice(_ device: AudioDevice?, forKey key: String) {
        var rule = settings.apps[key] ?? ClearMixSettings.AppRule()
        rule.outputDeviceUID = device?.uid
        settings.apps[key] = rule
        session.setOutputDevice(device, forAppKey: key)
        saveSettingsSoon()
        performSync()
    }

    func setEQBand(_ band: Int, gainDB: Float, for row: Row) {
        row.tap.bus.equalizer.setBand(band, gainDB: gainDB)
        var rule = settings.apps[row.key] ?? ClearMixSettings.AppRule()
        rule.eqBands = row.tap.bus.equalizer.bands
        settings.apps[row.key] = rule
        saveSettingsSoon()
    }

    func applyEQPreset(_ preset: Equalizer.Preset, for row: Row) {
        row.tap.bus.equalizer.apply(preset: preset)
        var rule = settings.apps[row.key] ?? ClearMixSettings.AppRule()
        rule.eqPreset = preset
        rule.eqBands = preset.gainsDB
        settings.apps[row.key] = rule
        bumpControls()
        saveSettingsSoon()
    }

    func muteAll() {
        for row in rows {
            row.tap.bus.mute()
            var rule = settings.apps[row.key] ?? ClearMixSettings.AppRule()
            rule.isMuted = true
            settings.apps[row.key] = rule
        }
        bumpControls()
        saveSettingsSoon()
    }

    func unmuteAll() {
        for row in rows {
            row.tap.bus.unmute()
            var rule = settings.apps[row.key] ?? ClearMixSettings.AppRule()
            rule.isMuted = false
            settings.apps[row.key] = rule
        }
        bumpControls()
        saveSettingsSoon()
    }

    private func bumpControls() {
        controlRevision &+= 1
        rebuildRowsIfChanged(from: session.taps)
    }

    // MARK: - Microphone Controls

    func toggleMicrophone() {
        if session.isMicrophoneRunning {
            lastWantedMicOnDisconnect = false
            session.stopMicrophone()
            isMicrophoneRunning = false
            return
        }
        let preferred = settings.preferredInputDeviceUID.flatMap { uid in
            availableInputs.first { $0.uid == uid }
        }
        guard let input = preferred ?? AudioDevices.defaultInput() ?? availableInputs.first else {
            lastError = L10n.text("Mikrofon bulunamadı.", "No microphone found.", lang: lang)
            return
        }
        lastWantedMicOnDisconnect = true
        startMicrophoneAsync(input: input)
    }

    private func startMicrophoneAsync(input: AudioDevice) {
        let session = self.session
        syncQueue.async { [weak self] in
            var failure: String?
            do {
                try session.startMicrophone(device: input)
            } catch {
                failure = error.localizedDescription
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastError = failure
                self.isMicrophoneRunning = session.isMicrophoneRunning
            }
        }
    }

    private func reconnectMicrophoneIfNeeded() {
        guard lastWantedMicOnDisconnect else { return }
        if session.isMicrophoneRunning,
           let activeIn = session.activeInputDevice,
           AudioDevices.isAlive(deviceID: activeIn.id) {
            return
        }
        let preferred = settings.preferredInputDeviceUID.flatMap { uid in
            availableInputs.first { $0.uid == uid }
        }
        if let fallback = preferred ?? AudioDevices.defaultInput() ?? availableInputs.first {
            startMicrophoneAsync(input: fallback)
        }
    }

    func selectInputDevice(_ device: AudioDevice) {
        settings.preferredInputDeviceUID = device.uid
        saveSettingsSoon()
        let session = self.session
        syncQueue.async { [weak self] in
            session.setInputDevice(device)
            Task { @MainActor [weak self] in
                self?.isMicrophoneRunning = session.isMicrophoneRunning
                self?.lastError = session.lastError
            }
        }
    }

    func setDenoiseEnabled(_ enabled: Bool) {
        settings.denoiseEnabled = enabled
        session.setMicrophoneSettings(denoise: enabled)
        saveSettingsSoon()
    }

    func setDenoiseStrength(_ strength: Float) {
        let clamped = min(max(strength, 0), 1)
        settings.denoiseStrength = clamped
        session.setMicrophoneSettings(strength: clamped)
        saveSettingsSoon()
    }

    func setGateEnabled(_ enabled: Bool) {
        settings.gateEnabled = enabled
        session.setMicrophoneSettings(gate: enabled)
        saveSettingsSoon()
    }

    func setGateThreshold(_ db: Float) {
        settings.gateThresholdDB = db
        session.setMicrophoneSettings(gateThresholdDB: db)
        saveSettingsSoon()
    }

    func setMicGain(_ db: Float) {
        settings.micGainDB = db
        session.setMicrophoneSettings(gainDB: db)
        saveSettingsSoon()
    }

    func toggleABCompare() {
        isABComparing.toggle()
        session.setMicrophoneSettings(abBypass: isABComparing)
    }

    func toggleMonitorMicrophone() {
        isMonitoringMic.toggle()
        session.setMicrophoneSettings(monitor: isMonitoringMic)
    }

    // MARK: - Profiles & Settings

    func setLanguage(_ language: ClearMixSettings.Language) {
        settings.language = language
        saveSettingsSoon()
        bumpControls()
    }

    func applyProfile(_ profile: ClearMixSettings.Profile) {
        settings.activateProfile(profile)
        switch profile {
        case .standard:
            settings.denoiseEnabled = true
            settings.denoiseStrength = 1.0
            settings.gateEnabled = false
            settings.duckingEnabled = false
        case .gaming:
            settings.denoiseEnabled = true
            settings.denoiseStrength = 1.0
            settings.gateEnabled = true
            settings.gateThresholdDB = -42
            settings.duckingEnabled = true
            settings.duckingAmountDB = -12
        case .meeting:
            settings.denoiseEnabled = true
            settings.denoiseStrength = 1.0
            settings.gateEnabled = true
            settings.gateThresholdDB = -46
            settings.duckingEnabled = true
            settings.duckingAmountDB = -15
        case .streaming:
            settings.denoiseEnabled = true
            settings.denoiseStrength = 0.85
            settings.gateEnabled = true
            settings.gateThresholdDB = -48
            settings.duckingEnabled = false
        }
        session.setMicrophoneSettings(
            denoise: settings.denoiseEnabled,
            strength: settings.denoiseStrength,
            gate: settings.gateEnabled,
            gateThresholdDB: settings.gateThresholdDB
        )
        session.setDucking(enabled: settings.duckingEnabled, amountDB: settings.duckingAmountDB)
        applyActiveRulesToTaps()
        saveSettingsSoon()
        performSync()
    }

    /// Puts the active profile's per-app rules on the live buses, including
    /// clearing a row the profile has no rule for back to 100%.
    private func applyActiveRulesToTaps() {
        let rules = settings.apps
        for tap in session.taps {
            let rule = rules[tap.process.persistenceKey] ?? ClearMixSettings.AppRule()
            rule.apply(to: tap.bus)
        }
        session.setPinnedKeys(Set(rules.filter(\.value.isPinned).keys))
        applyRoutingOverrides()
        bumpControls()
    }

    /// Moves each application to the device its profile routes it to, and drops
    /// the routing the previous profile had but the new one does not.
    private func applyRoutingOverrides() {
        let rules = settings.apps
        let keys = Set(session.overriddenKeys).union(rules.keys)
        for key in keys {
            guard let uid = rules[key]?.outputDeviceUID else {
                if session.outputOverride(forAppKey: key) != nil {
                    session.setOutputDevice(nil, forAppKey: key)
                }
                continue
            }
            guard let device = availableOutputs.first(where: { $0.uid == uid }) else {
                // The device is unplugged; keep the live routing rather than
                // silently playing somewhere the rule did not ask for.
                continue
            }
            if session.outputOverride(forAppKey: key)?.uid != device.uid {
                session.setOutputDevice(device, forAppKey: key)
            }
        }
    }

    func setKeepSystemSoundsTap(_ keep: Bool) {
        settings.keepSystemSoundsTap = keep
        session.setKeepSystemSoundsTap(keep)
        saveSettingsSoon()
        performSync()
    }

    func setDucking(enabled: Bool, amountDB: Float? = nil) {
        settings.duckingEnabled = enabled
        if let amountDB { settings.duckingAmountDB = amountDB }
        session.setDucking(enabled: enabled, amountDB: settings.duckingAmountDB)
        saveSettingsSoon()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            statusMessage = L10n.text(
                "Yalnızca .app paketinden açıldığında desteklenir.",
                "Only supported when launched from the .app bundle.",
                lang: lang
            )
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func refreshLaunchAtLoginState() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            launchAtLogin = false
            return
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openAudioPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openMicrophonePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshPermissionStatus() {
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    self?.microphoneAuthorized = granted
                }
            }
        case .authorized:
            microphoneAuthorized = true
        default:
            openMicrophonePrivacySettings()
        }
    }

    func openSetupWizard(step: Int = 1) {
        refreshPermissionStatus()
        setupWizardStep = min(max(step, 1), 3)
        showingSettings = false
        showingEQForKey = nil
        showingSetupWizard = true
    }

    func completeOnboarding() {
        settings.onboardingCompleted = true
        showingSetupWizard = false
        saveSettingsSoon()
    }

    func setGlobalHotkeysEnabled(_ enabled: Bool) {
        settings.globalHotkeysEnabled = enabled
        hotkeys?.setEnabled(enabled)
        saveSettingsSoon()
    }

    func openBlackHoleDownloadPage() {
        if let url = URL(string: "https://existential.audio/blackhole/") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Downloads and installs the official BlackHole package from inside the app;
    /// macOS asks for the admin password itself.
    func installBlackHole() {
        guard !isInstallingBlackHole else { return }
        isInstallingBlackHole = true
        blackHoleInstallMessage = L10n.text(
            "İndiriliyor…", "Downloading…", lang: lang
        )

        Task { [weak self] in
            guard let self else { return }
            var package: URL?
            do {
                let downloaded = try await BlackHoleInstaller.downloadPackage()
                package = downloaded
                self.blackHoleInstallMessage = L10n.text(
                    "Doğrulanıyor…", "Verifying…", lang: self.lang
                )
                try BlackHoleInstaller.verify(downloaded)

                self.blackHoleInstallMessage = L10n.text(
                    "Kuruluyor… macOS yönetici parolası isteyecek.",
                    "Installing… macOS will ask for your admin password.",
                    lang: self.lang
                )
                // NSAppleScript wants the main thread, and the password dialog is
                // modal anyway, so this runs here instead of on the sync queue.
                try BlackHoleInstaller.install(downloaded)

                self.blackHoleInstallMessage = L10n.text(
                    "Kuruldu, aygıt bekleniyor…",
                    "Installed, waiting for the device…",
                    lang: self.lang
                )
                // Postinstall restarts coreaudiod; give it a moment to come back.
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self.refreshNow()
                    if self.blackHoleDevice != nil { break }
                }
                self.blackHoleInstallMessage = self.blackHoleDevice == nil
                    ? L10n.text(
                        "Kurulum bitti ama aygıt görünmüyor. Mac'i yeniden başlatıp tekrar kontrol edin.",
                        "Installed, but the device is not visible yet. Reboot and check again.",
                        lang: self.lang
                    )
                    : L10n.text("BlackHole 2ch kuruldu.", "BlackHole 2ch installed.", lang: self.lang)
            } catch {
                self.blackHoleInstallMessage = error.localizedDescription
            }
            if let package {
                try? FileManager.default.removeItem(at: package)
            }
            self.isInstallingBlackHole = false
        }
    }

    func copyBlackHoleInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install --cask blackhole-2ch", forType: .string)
        statusMessage = L10n.text("Komut panoya kopyalandı.", "Command copied to clipboard.", lang: lang)
    }

    func copyDiagnosticsReport() {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let outputs = availableOutputs.map {
            "  - \($0.name) (\($0.outputChannels)ch, \(Int($0.nominalSampleRate))Hz, hwVol=\(AudioDevices.hasVolumeControl(for: $0.id)))"
        }.joined(separator: "\n")
        let inputs = availableInputs.map {
            "  - \($0.name) (\($0.inputChannels)ch, \(Int($0.nominalSampleRate))Hz)"
        }.joined(separator: "\n")
        let tapLines = rows.map { row in
            "  - \(row.name) [\(row.key)] out=\(row.outputDeviceName) rate=\(Int(row.tap.tapSampleRate))/\(Int(row.tap.outputSampleRate)) inCalls=\(row.tap.captureCalls) nonZero=\(row.tap.nonZeroCaptureCalls) status=\(row.tap.lastStatus)"
        }.joined(separator: "\n")
        let micStats = session.microphoneStats?.snapshot
        let report = """
        ClearMix Diagnostics
        macOS: \(os)
        Active Output: \(deviceName)
        BlackHole 2ch: \(blackHoleDevice?.name ?? "not installed")
        Mic Running: \(isMicrophoneRunning) (latency ~\(microphoneLatencyMilliseconds) ms)
        Mic Stats: in=\(micStats?.framesIn ?? 0) out=\(micStats?.framesOut ?? 0) underrun=\(micStats?.underrunFrames ?? 0) overrun=\(micStats?.overrunFrames ?? 0)
        Last Error: \(lastError ?? "none")
        Outputs:
        \(outputs)
        Inputs:
        \(inputs)
        Active Taps (\(rows.count)):
        \(tapLines)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        statusMessage = L10n.text("Tanılama raporu panoya kopyalandı.", "Diagnostics copied to clipboard.", lang: lang)
    }

    /// Writes a pending debounced change now, so quitting right after moving a
    /// slider does not lose it.
    private func flushSettings() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        settingsStore.save(settings)
    }

    private func saveSettingsSoon() {
        saveWorkItem?.cancel()
        let snapshot = settings
        let store = settingsStore
        let item = DispatchWorkItem {
            store.save(snapshot)
        }
        saveWorkItem = item
        syncQueue.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func logState() {
        let count = rows.count
        if count != lastLoggedRows {
            lastLoggedRows = count
            Self.log.info("satır \(count, privacy: .public), cihaz \(self.deviceName, privacy: .public)")
        }
        guard Self.verbose else { return }
        let mic = session.isMicrophoneRunning
            ? "mikrofon=\(String(format: "%.3f", session.microphonePeak))/\(Int(session.microphoneLatency * 1_000))ms"
            : "mikrofon=kapalı"
        let summary = rows.map { row in
            let route = row.tap.outputDevice.uid == session.configuration.outputDevice?.uid
                ? ""
                : "→\(row.tap.outputDevice.name)"
            return "\(row.name)=\(String(format: "%.3f", row.tap.bus.peak))"
                + "/\(Int(row.tap.bus.gainPercent))%\(route)"
        }.joined(separator: " ")
        Self.log.info("satırlar \(summary, privacy: .public) \(mic, privacy: .public) hata \(self.lastError ?? "-", privacy: .public)")
    }
}
