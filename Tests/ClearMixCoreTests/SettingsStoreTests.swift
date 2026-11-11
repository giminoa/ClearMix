import XCTest
@testable import ClearMixCore

final class SettingsStoreTests: XCTestCase {
    func testMissingFileReturnsDefaults() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
        let store = SettingsStore(url: temp)
        XCTAssertEqual(store.load(), ClearMixSettings())
    }

    func testSaveAndLoadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        var settings = ClearMixSettings()
        settings.language = .english
        settings.activeProfile = .gaming
        settings.preferredOutputDeviceUID = "speaker-uid"
        settings.masterVolume = 0.65
        settings.duckingEnabled = true
        settings.denoiseStrength = 0.75
        settings.apps["com.spotify.client"] = ClearMixSettings.AppRule(
            gainPercent: 125,
            isMuted: false,
            isPinned: true,
            outputDeviceUID: "airpods-uid",
            eqPreset: .bassBoost,
            eqBands: Equalizer.Preset.bassBoost.gainsDB
        )

        store.save(settings)
        let loaded = store.load()
        XCTAssertEqual(loaded, settings)
    }

    func testMutedAppRuleSurvivesReload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))

        var settings = ClearMixSettings()
        settings.apps["com.apple.Music"] = ClearMixSettings.AppRule(gainPercent: 40, isMuted: true)
        store.save(settings)

        let rule = store.load().apps["com.apple.Music"]
        XCTAssertEqual(rule?.gainPercent, 40)
        XCTAssertEqual(rule?.isMuted, true)
    }

    func testProfileSwitchSnapshotsAndRestoresRules() {
        var settings = ClearMixSettings()
        settings.apps["com.apple.Music"] = ClearMixSettings.AppRule(gainPercent: 40)

        settings.activateProfile(.gaming)
        XCTAssertTrue(settings.apps.isEmpty, "oyun profili kendi setiyle başlar")
        settings.apps["com.apple.Music"] = ClearMixSettings.AppRule(gainPercent: 120, isMuted: true)

        settings.activateProfile(.standard)
        XCTAssertEqual(settings.apps["com.apple.Music"]?.gainPercent, 40)
        XCTAssertEqual(settings.apps["com.apple.Music"]?.isMuted, false)

        settings.activateProfile(.gaming)
        XCTAssertEqual(settings.apps["com.apple.Music"]?.gainPercent, 120)
        XCTAssertEqual(settings.apps["com.apple.Music"]?.isMuted, true)
        XCTAssertEqual(settings.activeProfile, .gaming)
    }

    func testProfileRulesSurviveReload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))

        var settings = ClearMixSettings()
        settings.activateProfile(.meeting)
        settings.apps["com.apple.Music"] = ClearMixSettings.AppRule(gainPercent: 25, isMuted: true)
        store.save(settings)

        var loaded = store.load()
        XCTAssertEqual(loaded.activeProfile, .meeting)
        XCTAssertEqual(loaded.apps["com.apple.Music"]?.gainPercent, 25)

        // Switching back to the untouched standard profile still finds it empty.
        loaded.activateProfile(.standard)
        XCTAssertTrue(loaded.apps.isEmpty)
        loaded.activateProfile(.meeting)
        XCTAssertEqual(loaded.apps["com.apple.Music"]?.isMuted, true)
    }

    func testProfilesKeepTheirOwnRouting() {
        var settings = ClearMixSettings()
        settings.apps["com.hnc.Discord"] = ClearMixSettings.AppRule(outputDeviceUID: "speakers")

        settings.activateProfile(.meeting)
        settings.apps["com.hnc.Discord"] = ClearMixSettings.AppRule(outputDeviceUID: "blackhole-2ch")

        settings.activateProfile(.standard)
        XCTAssertEqual(settings.apps["com.hnc.Discord"]?.outputDeviceUID, "speakers")

        settings.activateProfile(.meeting)
        XCTAssertEqual(settings.apps["com.hnc.Discord"]?.outputDeviceUID, "blackhole-2ch")

        // A profile without rules leaves every app on the default output.
        settings.activateProfile(.streaming)
        XCTAssertNil(settings.apps["com.hnc.Discord"]?.outputDeviceUID)
    }

    func testAppRuleRestoresSliderPositionAndMute() {
        let bus = MixerBus(sampleRate: 48_000)
        ClearMixSettings.AppRule(gainPercent: 45).apply(to: bus)
        XCTAssertEqual(bus.gainPercent, 45, accuracy: 0.001)
        XCTAssertFalse(bus.isMuted)

        // A muted row keeps the knob where the user left it.
        ClearMixSettings.AppRule(gainPercent: 45, isMuted: true).apply(to: bus)
        XCTAssertTrue(bus.isMuted)
        XCTAssertEqual(bus.gainPercent, 45, accuracy: 0.001)
        XCTAssertEqual(bus.targetGain, 0, accuracy: 0.0001)
    }

    func testDecodesLegacyPartialJSONWithDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("settings.json")
        let legacyJSON = """
        {
          "language": "en",
          "apps": {
            "com.spotify.client": {
              "gainPercent": 140
            }
          }
        }
        """
        try Data(legacyJSON.utf8).write(to: url)

        let loaded = SettingsStore(url: url).load()
        XCTAssertEqual(loaded.language, .english)
        XCTAssertFalse(loaded.onboardingCompleted)
        XCTAssertFalse(loaded.globalHotkeysEnabled)
        XCTAssertTrue(loaded.keepSystemSoundsTap)
        XCTAssertEqual(loaded.apps["com.spotify.client"]?.gainPercent, 140)
        XCTAssertEqual(loaded.apps["com.spotify.client"]?.eqPreset, .flat)
        XCTAssertTrue(loaded.profileApps.isEmpty)
    }
}
