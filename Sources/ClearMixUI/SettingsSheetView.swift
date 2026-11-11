import ClearMixCore
import SwiftUI

/// Compact settings, profiles, permissions & diagnostics panel.
struct SettingsSheetView: View {
    @ObservedObject var store: MixerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("Ayarlar ve Kurulum", "Settings & Setup", lang: store.lang))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(L10n.text("Bitti", "Done", lang: store.lang)) {
                    store.showingSettings = false
                }
                .controlSize(.small)
            }

            Divider()

            // Profiles
            HStack {
                Text(L10n.text("Profil", "Profile", lang: store.lang))
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Picker("", selection: Binding(
                    get: { store.settings.activeProfile },
                    set: { store.applyProfile($0) }
                )) {
                    ForEach(ClearMixSettings.Profile.allCases, id: \.self) { profile in
                        Text(L10n.profileName(profile, lang: store.lang)).tag(profile)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 140)
            }

            // Language
            HStack {
                Text(L10n.text("Dil / Language", "Language / Dil", lang: store.lang))
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Picker("", selection: Binding(
                    get: { store.settings.language },
                    set: { store.setLanguage($0) }
                )) {
                    Text("Türkçe").tag(ClearMixSettings.Language.turkish)
                    Text("English").tag(ClearMixSettings.Language.english)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 140)
            }

            Divider()

            // Toggles
            Toggle(isOn: Binding(
                get: { store.settings.keepSystemSoundsTap },
                set: { store.setKeepSystemSoundsTap($0) }
            )) {
                Text(L10n.text("Sistem Seslerini (bildirimler) her zaman göster", "Always show System Sounds", lang: store.lang))
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: Binding(
                get: { store.settings.duckingEnabled },
                set: { store.setDucking(enabled: $0) }
            )) {
                Text(L10n.text("Otomatik kısma (Discord/Zoom konuşurken müziği kıs)", "Auto-duck music during Discord/Zoom calls", lang: store.lang))
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            )) {
                Text(L10n.text("Oturum açılışında başlat", "Launch at login", lang: store.lang))
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: Binding(
                get: { store.settings.globalHotkeysEnabled },
                set: { store.setGlobalHotkeysEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("Global kısayollar", "Global hotkeys", lang: store.lang))
                        .font(.system(size: 11))
                    Text(L10n.text(
                        "⌃⌥M Ana ses · ⌃⌥K Mikrofon · ⌃⌥D Temizleme",
                        "⌃⌥M Master mute · ⌃⌥K Mic · ⌃⌥D Denoise",
                        lang: store.lang
                    ))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            // Permissions & Diagnostics
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("İzinler ve Tanılama", "Permissions & Diagnostics", lang: store.lang))
                    .font(.system(size: 11, weight: .semibold))
                HStack(spacing: 6) {
                    Button(L10n.text("Sistem Sesi İzni", "System Audio Privacy", lang: store.lang)) {
                        store.openAudioPrivacySettings()
                    }
                    .controlSize(.small)
                    Button(L10n.text("Mikrofon İzni", "Mic Privacy", lang: store.lang)) {
                        store.openMicrophonePrivacySettings()
                    }
                    .controlSize(.small)
                }
                HStack(spacing: 6) {
                    Button(L10n.text("Kurulum Sihirbazı", "Setup Wizard", lang: store.lang)) {
                        store.openSetupWizard(step: 1)
                    }
                    .controlSize(.small)
                    Button(L10n.text("Tanılama raporunu kopyala", "Copy diagnostics", lang: store.lang)) {
                        store.copyDiagnosticsReport()
                    }
                    .controlSize(.small)
                }
            }

            if let msg = store.statusMessage {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Spacer()
                Button(L10n.text("ClearMix'ten Çık", "Quit ClearMix", lang: store.lang)) {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
