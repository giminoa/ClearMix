import CoreAudio
import Foundation

/// Runs one `AppTap` per application that is producing audio, all writing to the
/// same output device. Adding and removing taps follows the process list, so
/// quitting an app releases its tap instead of leaving a silent channel behind.
///
/// `sync()` and `stop()` may be called from any thread; the tap list is copied
/// under a lock, so a UI can read it while a background queue syncs.
public final class MixerEngine: @unchecked Sendable {
    public struct Configuration {
        /// Device everything is played back to by default. Nil until one is available.
        public var outputDevice: AudioDevice?
        /// Bundle ids or names to mix. Empty means every app playing audio.
        public var only: [String] = []
        /// Bundle ids or names to skip (ClearMix itself, for example).
        public var excluding: [String] = []
        /// Keep `systemsoundserverd` tapped even between notification chimes.
        public var keepSystemSoundsTap: Bool = true
        /// Persistence keys to keep tapped even while momentarily silent.
        public var pinnedKeys: Set<String> = []
        /// Seconds to retain a recently active tap after playback pauses.
        public var idleGraceSeconds: TimeInterval = 15

        public init(outputDevice: AudioDevice?) {
            self.outputDevice = outputDevice
        }
    }

    private let lock = NSLock()
    private var storedTaps: [AppTap] = []
    private var outputOverrides: [String: AudioDevice] = [:]
    private var lastActiveAt: [AudioObjectID: Date] = [:]
    private var lastCommsActivity = Date.distantPast

    public private(set) var configuration: Configuration
    /// Last tap failure, for a UI to show instead of staying silent.
    public private(set) var lastError: String?
    /// Software master trim applied to all taps (0...1).
    public private(set) var masterGain: Float = 1
    /// Automatic ducking configuration.
    public var duckingEnabled = false
    public var duckingAmountDB: Float = -10
    public var onTapCreated: (@Sendable (AppTap) -> Void)?

    private static let commsBundleIDs: Set<String> = [
        "com.hnc.Discord",
        "us.zoom.xos",
        "com.apple.FaceTime",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.tinyspeck.slackmacgap",
        "ru.keepcoder.Telegram",
        "net.whatsapp.WhatsApp",
    ]

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        stop()
    }

    /// Copy of the live taps. Safe to read from the main thread.
    public var taps: [AppTap] {
        lock.lock()
        defer { lock.unlock() }
        return storedTaps
    }

    public var isRunning: Bool { !taps.isEmpty }

    /// Level of the loudest bus, for a single menu bar meter.
    public var peak: Float {
        taps.reduce(0) { max($0, $1.bus.peak) }
    }

    /// Restricts which applications are mixed; existing taps are left as they
    /// are until the next `sync()`.
    public func setFilters(only: [String], excluding: [String]) {
        lock.lock()
        configuration.only = only
        configuration.excluding = excluding
        lock.unlock()
    }

    public func setKeepSystemSoundsTap(_ keep: Bool) {
        lock.lock()
        configuration.keepSystemSoundsTap = keep
        lock.unlock()
    }

    public func setPinnedKeys(_ keys: Set<String>) {
        lock.lock()
        configuration.pinnedKeys = keys
        lock.unlock()
    }

    public func setMasterGain(_ scalar: Float) {
        let clamped = min(max(scalar, 0), 1)
        lock.lock()
        masterGain = clamped
        for tap in storedTaps {
            tap.bus.masterGain = clamped
        }
        lock.unlock()
    }

    public func setOutputDevice(_ device: AudioDevice?) {
        lock.lock()
        storedTaps.forEach { $0.stop() }
        storedTaps.removeAll()
        lastActiveAt.removeAll()
        configuration.outputDevice = device
        lastError = nil
        lock.unlock()
    }

    /// Routes one application (by `persistenceKey`) to a dedicated output device.
    /// Pass `nil` to revert that app to the default mixer output.
    public func setOutputDevice(_ device: AudioDevice?, forAppKey key: String) {
        lock.lock()
        if let device {
            outputOverrides[key] = device
        } else {
            outputOverrides.removeValue(forKey: key)
        }
        // Rebuild only taps belonging to this app key on the next sync.
        storedTaps.removeAll { tap in
            guard tap.process.persistenceKey == key else { return false }
            tap.stop()
            return true
        }
        lock.unlock()
    }

    public func outputOverride(forAppKey key: String) -> AudioDevice? {
        lock.lock()
        defer { lock.unlock() }
        return outputOverrides[key]
    }

    /// Keys that currently play on a dedicated output device.
    public var overriddenKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(outputOverrides.keys)
    }

    /// Creates taps for every matching process that is playing audio (plus
    /// pinned/system-sound processes and recently paused apps within the grace window).
    /// Returns the taps it just created, so callers can apply per-app settings.
    @discardableResult
    public func sync() -> [AppTap] {
        lock.lock()
        defer { lock.unlock() }

        guard let defaultOutput = configuration.outputDevice else {
            lastError = "Çıkış cihazı bulunamadı."
            return []
        }

        let now = Date()
        let ownPID = getpid()
        let allProcesses = AudioProcesses.all()
        let allByID = Dictionary(uniqueKeysWithValues: allProcesses.map { ($0.objectID, $0) })

        // Never tap ClearMix itself: feedback loop protection.
        func isAllowed(_ process: AudioProcess) -> Bool {
            if process.pid == ownPID { return false }
            if process.bundleID?.hasPrefix("com.clearmix.") == true { return false }
            if !configuration.only.isEmpty {
                guard configuration.only.contains(where: { matches(process, $0) }) else {
                    return false
                }
            }
            return !configuration.excluding.contains { matches(process, $0) }
        }

        var wantedByID: [AudioObjectID: AudioProcess] = [:]
        for process in allProcesses where isAllowed(process) {
            if process.isRunningOutput {
                wantedByID[process.objectID] = process
                lastActiveAt[process.objectID] = now
            } else if configuration.keepSystemSoundsTap && process.isSystemSoundDaemon && configuration.only.isEmpty {
                wantedByID[process.objectID] = process
            } else if configuration.pinnedKeys.contains(process.persistenceKey) && configuration.only.isEmpty {
                wantedByID[process.objectID] = process
            }
        }

        // Keep recently paused taps alive during the grace window if the process still exists.
        if configuration.idleGraceSeconds > 0 {
            for tap in storedTaps {
                let oid = tap.process.objectID
                guard wantedByID[oid] == nil,
                      let process = allByID[oid],
                      isAllowed(process),
                      let last = lastActiveAt[oid],
                      now.timeIntervalSince(last) < configuration.idleGraceSeconds else {
                    continue
                }
                wantedByID[oid] = process
            }
        }

        let candidates = Array(wantedByID.values)
        let live = Set(storedTaps.map(\.process.objectID))
        var added: [AppTap] = []
        var failures: [String] = []
        let tapCallback = onTapCreated

        for process in candidates where !live.contains(process.objectID) {
            let targetOutput = outputOverrides[process.persistenceKey] ?? defaultOutput
            do {
                let tap = try AppTap(process: process, output: targetOutput)
                tap.bus.masterGain = masterGain
                tapCallback?(tap)
                try tap.start()
                storedTaps.append(tap)
                added.append(tap)
            } catch {
                failures.append("\(process.name): \(error.localizedDescription)")
            }
        }
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")

        // Drop taps whose process exited or passed the grace window.
        let current = Set(candidates.map(\.objectID))
        storedTaps.removeAll { tap in
            guard !current.contains(tap.process.objectID) else { return false }
            tap.stop()
            lastActiveAt.removeValue(forKey: tap.process.objectID)
            return true
        }
        lastActiveAt = lastActiveAt.filter { current.contains($0.key) }

        applyDucking(now: now)
        return added
    }

    private func applyDucking(now: Date) {
        guard duckingEnabled else {
            for tap in storedTaps { tap.bus.duckingGain = 1 }
            return
        }
        let commsActive = storedTaps.contains { tap in
            guard let key = tap.process.appBundleID ?? tap.process.bundleID else { return false }
            return Self.commsBundleIDs.contains(key) && tap.bus.sourcePeak > 0.02
        }
        if commsActive {
            lastCommsActivity = now
        }
        let shouldDuck = commsActive || now.timeIntervalSince(lastCommsActivity) < 1.2
        let duckScalar = shouldDuck ? AudioMath.dbToLinear(duckingAmountDB) : 1
        for tap in storedTaps {
            let key = tap.process.appBundleID ?? tap.process.bundleID ?? ""
            let isProtected = Self.commsBundleIDs.contains(key) || tap.process.isSystemSoundDaemon
            tap.bus.duckingGain = isProtected ? 1 : duckScalar
        }
    }

    public func tap(for process: AudioProcess) -> AppTap? {
        taps.first { $0.process.objectID == process.objectID }
    }

    public func stop() {
        lock.lock()
        storedTaps.forEach { $0.stop() }
        storedTaps.removeAll()
        lastActiveAt.removeAll()
        lock.unlock()
    }

    private func matches(_ process: AudioProcess, _ query: String) -> Bool {
        process.bundleID == query
            || process.appBundleID == query
            || process.name.localizedCaseInsensitiveContains(query)
            || "\(process.pid)" == query
    }
}
