import AppKit
import CoreAudio
import Foundation

/// One application the audio system can tap: the HAL process object that
/// identifies its audio, plus the facts a mixer row needs.
public struct AudioProcess: Sendable, Equatable, Identifiable {
    /// HAL object id for the process; use this to build a tap.
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    /// Resolved enclosing application bundle id (e.g. `com.google.Chrome` for
    /// Chrome audio helpers), used for icons and persistent settings.
    public let appBundleID: String?
    public let name: String
    /// True while the process is sending audio to a device.
    public let isRunningOutput: Bool
    /// True while the process is recording from a device.
    public let isRunningInput: Bool

    public var id: AudioObjectID { objectID }

    /// True for macOS's system sound effects daemon (`systemsoundserverd`).
    public var isSystemSoundDaemon: Bool {
        bundleID == "systemsoundserverd"
    }

    /// Stable key for storing per-app mixer preferences across launches.
    public var persistenceKey: String {
        appBundleID ?? bundleID ?? name
    }
}

/// Discovery of the processes the HAL knows about (macOS 14.4 process objects).
public enum AudioProcesses {
    /// Every process object, whether or not it is currently making sound.
    public static func all() -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap(process(for:))
    }

    /// Processes that are playing audio right now: the mixer's default list.
    public static func playingOutput() -> [AudioProcess] {
        all().filter(\.isRunningOutput)
    }

    /// Locates macOS's system sound effects daemon (`systemsoundserverd`),
    /// whether or not an alert sound is playing at this instant.
    public static func systemSoundDaemon() -> AudioProcess? {
        all().first(where: \.isSystemSoundDaemon)
    }

    public static func process(for objectID: AudioObjectID) -> AudioProcess? {
        let rawPID = AudioDevices.integer(objectID, kAudioProcessPropertyPID, default: 0)
        guard rawPID > 0 else { return nil }
        let pid = pid_t(bitPattern: rawPID)
        // Command line tools such as afplay have no bundle id; they still get a
        // row so the same engine can mix them.
        let rawBundle = AudioDevices.string(objectID, kAudioProcessPropertyBundleID)
        let bundleID = (rawBundle?.isEmpty ?? true) ? nil : rawBundle
        let resolved = resolveApp(pid: pid, bundleID: bundleID)

        return AudioProcess(
            objectID: objectID,
            pid: pid,
            bundleID: bundleID,
            appBundleID: resolved.bundleID,
            name: resolved.name,
            isRunningOutput: AudioDevices.integer(
                objectID, kAudioProcessPropertyIsRunningOutput, default: 0
            ) != 0,
            isRunningInput: AudioDevices.integer(
                objectID, kAudioProcessPropertyIsRunningInput, default: 0
            ) != 0
        )
    }

    public static func find(_ query: String, in processes: [AudioProcess]) -> AudioProcess? {
        if let exact = processes.first(where: {
            $0.bundleID == query || $0.appBundleID == query || $0.name == query || "\($0.pid)" == query
        }) {
            return exact
        }
        return processes.first {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.appBundleID?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private static func resolveApp(pid: pid_t, bundleID: String?) -> (name: String, bundleID: String?) {
        if bundleID == "systemsoundserverd" {
            return ("Sistem Sesleri", "systemsoundserverd")
        }

        let path = executablePath(pid: pid)
        if let path, let enclosing = enclosingAppBundle(forExecutablePath: path) {
            let resolvedID = enclosing.bundleIdentifier ?? bundleID
            if let resolvedID,
               let running = NSRunningApplication.runningApplications(withBundleIdentifier: resolvedID).first,
               let appName = running.localizedName, !appName.isEmpty {
                return (appName, resolvedID)
            }
            if let bundleName = (enclosing.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (enclosing.object(forInfoDictionaryKey: "CFBundleName") as? String),
               !bundleName.isEmpty {
                return (bundleName, resolvedID)
            }
        }

        if let parentPID = parentPID(of: pid), parentPID > 1,
           let parent = NSRunningApplication(processIdentifier: parentPID),
           let parentName = parent.localizedName, !parentName.isEmpty {
            return (parentName, parent.bundleIdentifier ?? bundleID)
        }

        if let bundleID, (bundleID == "com.apple.WebKit.GPU" || bundleID == "com.apple.WebKit.Networking") {
            if let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first,
               let safariName = safari.localizedName {
                return (safariName, "com.apple.Safari")
            }
        }

        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty {
            return (name, app.bundleIdentifier ?? bundleID)
        }
        if let path {
            return ((path as NSString).lastPathComponent, bundleID)
        }
        guard let bundleID else { return ("pid \(pid)", nil) }
        // Fall back to the last bundle component: com.spotify.client → spotify.
        return (bundleID.split(separator: ".").last.map(String.init) ?? bundleID, bundleID)
    }

    private static func enclosingAppBundle(forExecutablePath path: String) -> Bundle? {
        let components = (path as NSString).pathComponents
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        let appPath = NSString.path(withComponents: Array(components.prefix(appIndex + 1)))
        return Bundle(path: appPath)
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return pid_t(info.pbi_ppid)
    }

    /// Binary path for processes that are not regular apps, e.g. `afplay` or helpers.
    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let length = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return 0 }
            return proc_pidpath(pid, base, UInt32(raw.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}
