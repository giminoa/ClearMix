import Foundation

/// Persistent JSON configuration for per-app volumes, routing, EQ, microphone
/// settings, profiles and UI preferences.
public struct ClearMixSettings: Codable, Sendable, Equatable {
    public struct AppRule: Codable, Sendable, Equatable {
        public var gainPercent: Float = 100
        public var isMuted: Bool = false
        public var isPinned: Bool = false
        public var outputDeviceUID: String?
        public var eqPreset: Equalizer.Preset = .flat
        public var eqBands: [Float] = Equalizer.Preset.flat.gainsDB

        public init(
            gainPercent: Float = 100,
            isMuted: Bool = false,
            isPinned: Bool = false,
            outputDeviceUID: String? = nil,
            eqPreset: Equalizer.Preset = .flat,
            eqBands: [Float] = Equalizer.Preset.flat.gainsDB
        ) {
            self.gainPercent = gainPercent
            self.isMuted = isMuted
            self.isPinned = isPinned
            self.outputDeviceUID = outputDeviceUID
            self.eqPreset = eqPreset
            self.eqBands = eqBands
        }

        /// Restores this rule onto a live bus: used for a tap created at launch
        /// and for one that comes back after its application was closed.
        public func apply(to bus: MixerBus) {
            bus.setGain(percent: gainPercent)
            if isMuted { bus.mute() }
            bus.equalizer.setBands(eqBands)
            bus.snapToTarget()
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            gainPercent = try c.decodeIfPresent(Float.self, forKey: .gainPercent) ?? 100
            isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
            isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
            outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
            eqPreset = try c.decodeIfPresent(Equalizer.Preset.self, forKey: .eqPreset) ?? .flat
            eqBands = try c.decodeIfPresent([Float].self, forKey: .eqBands) ?? Equalizer.Preset.flat.gainsDB
        }
    }

    public enum Language: String, Codable, CaseIterable, Sendable {
        case turkish = "tr"
        case english = "en"
    }

    public enum Profile: String, Codable, CaseIterable, Sendable {
        case standard
        case gaming
        case meeting
        case streaming
    }

    public var language: Language = .turkish
    public var activeProfile: Profile = .standard
    public var onboardingCompleted: Bool = false
    public var globalHotkeysEnabled: Bool = false
    /// Nil means follow the macOS system default output device.
    public var preferredOutputDeviceUID: String?
    /// Software master trim (0...1), combined with hardware output volume.
    public var masterVolume: Float = 1.0
    public var masterMuted: Bool = false
    /// Keep `systemsoundserverd` ("Sistem Sesleri") always controllable.
    public var keepSystemSoundsTap: Bool = true
    public var duckingEnabled: Bool = false
    public var duckingAmountDB: Float = -10

    // Microphone
    public var preferredInputDeviceUID: String?
    public var denoiseEnabled: Bool = true
    public var denoiseStrength: Float = 1.0
    public var gateEnabled: Bool = false
    public var gateThresholdDB: Float = -45
    public var micGainDB: Float = 0

    /// Rules of the active profile, keyed by `AudioProcess.persistenceKey`
    /// (`appBundleID ?? bundleID ?? name`).
    public var apps: [String: AppRule] = [:]

    /// The other profiles' rule sets, keyed by `Profile.rawValue`. A profile with
    /// no entry starts from the defaults (100%, unmuted) the first time it is
    /// selected.
    public var profileApps: [String: [String: AppRule]] = [:]

    public init() {}

    /// Rules a profile would activate, without switching to it.
    public func appRules(for profile: Profile) -> [String: AppRule] {
        profileApps[profile.rawValue] ?? [:]
    }

    /// Saves the active profile's rules under that profile and loads `profile`'s
    /// own set into `apps`.
    public mutating func activateProfile(_ profile: Profile) {
        guard profile != activeProfile else { return }
        profileApps[activeProfile.rawValue] = apps
        apps = profileApps[profile.rawValue] ?? [:]
        activeProfile = profile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(Language.self, forKey: .language) ?? .turkish
        activeProfile = try c.decodeIfPresent(Profile.self, forKey: .activeProfile) ?? .standard
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        globalHotkeysEnabled = try c.decodeIfPresent(Bool.self, forKey: .globalHotkeysEnabled) ?? false
        preferredOutputDeviceUID = try c.decodeIfPresent(String.self, forKey: .preferredOutputDeviceUID)
        masterVolume = try c.decodeIfPresent(Float.self, forKey: .masterVolume) ?? 1.0
        masterMuted = try c.decodeIfPresent(Bool.self, forKey: .masterMuted) ?? false
        keepSystemSoundsTap = try c.decodeIfPresent(Bool.self, forKey: .keepSystemSoundsTap) ?? true
        duckingEnabled = try c.decodeIfPresent(Bool.self, forKey: .duckingEnabled) ?? false
        duckingAmountDB = try c.decodeIfPresent(Float.self, forKey: .duckingAmountDB) ?? -10
        preferredInputDeviceUID = try c.decodeIfPresent(String.self, forKey: .preferredInputDeviceUID)
        denoiseEnabled = try c.decodeIfPresent(Bool.self, forKey: .denoiseEnabled) ?? true
        denoiseStrength = try c.decodeIfPresent(Float.self, forKey: .denoiseStrength) ?? 1.0
        gateEnabled = try c.decodeIfPresent(Bool.self, forKey: .gateEnabled) ?? false
        gateThresholdDB = try c.decodeIfPresent(Float.self, forKey: .gateThresholdDB) ?? -45
        micGainDB = try c.decodeIfPresent(Float.self, forKey: .micGainDB) ?? 0
        apps = try c.decodeIfPresent([String: AppRule].self, forKey: .apps) ?? [:]
        profileApps = try c.decodeIfPresent(
            [String: [String: AppRule]].self, forKey: .profileApps
        ) ?? [:]
    }
}

/// Reads and writes `ClearMixSettings` atomically in Application Support.
public final class SettingsStore: @unchecked Sendable {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.url = support
                .appendingPathComponent("ClearMix", isDirectory: true)
                .appendingPathComponent("settings.json")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func load() -> ClearMixSettings {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode(ClearMixSettings.self, from: data) else {
            return ClearMixSettings()
        }
        return decoded
    }

    public func save(_ settings: ClearMixSettings) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
