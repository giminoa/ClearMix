import AppKit
import ClearMixCore
import SwiftUI

/// System & per-application volume mixer tab.
struct SoundsTabView: View {
    @ObservedObject var store: MixerStore

    var body: some View {
        VStack(spacing: 0) {
            if store.suspectedCaptureSilence {
                silenceWarningBanner
                Divider()
            }
            appsList
            Divider()
            masterFooter
        }
    }

    private var silenceWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text(L10n.text(
                "Uygulamalar sessiz yakalanıyor. Sistem sesi kaydı iznini kontrol edin.",
                "Apps are capturing silence. Check System Audio Recording permission.",
                lang: store.lang
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(L10n.text("İzinler", "Privacy", lang: store.lang)) {
                store.openAudioPrivacySettings()
            }
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.08))
    }

    @ViewBuilder
    private var appsList: some View {
        if store.rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.rows) { row in
                        AppMixerRow(store: store, row: row)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 310)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text(store.needsAudioCapturePermission
                 ? L10n.text("Sistem sesi izni gerekiyor", "System audio permission needed", lang: store.lang)
                 : L10n.text("Ses çalan uygulama yok", "No applications playing audio", lang: store.lang))
                .font(.system(size: 12, weight: .medium))
            Text(store.needsAudioCapturePermission
                 ? L10n.text(
                    "Bir şey oynatın ve Gizlilik ayarlarından izin verin.",
                    "Play audio and allow System Audio Recording in Privacy Settings.",
                    lang: store.lang
                 )
                 : L10n.text(
                    "Bir uygulama ses çalmaya başladığında satırı burada görünür.",
                    "Apps appear here automatically as soon as they play audio.",
                    lang: store.lang
                 ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if store.needsAudioCapturePermission {
                Button(L10n.text("Gizlilik ayarlarını aç", "Open Privacy Settings", lang: store.lang)) {
                    store.openAudioPrivacySettings()
                }
                .controlSize(.small)
            }
            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    private var masterFooter: some View {
        VStack(spacing: 8) {
            // Output device picker + quick mute-all
            HStack(spacing: 8) {
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Menu {
                    Button {
                        store.selectMainOutputDevice(nil)
                    } label: {
                        HStack {
                            Text(L10n.text("Sistem Varsayılanı", "System Default", lang: store.lang))
                            if store.settings.preferredOutputDeviceUID == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    Divider()
                    ForEach(store.availableOutputs, id: \.uid) { device in
                        Button {
                            store.selectMainOutputDevice(device)
                        } label: {
                            HStack {
                                Text(device.name)
                                if store.settings.preferredOutputDeviceUID == device.uid {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(store.deviceName)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                Button(store.allMuted
                       ? L10n.text("Tümünü aç", "Unmute all", lang: store.lang)
                       : L10n.text("Tümünü sustur", "Mute all", lang: store.lang)) {
                    store.allMuted ? store.unmuteAll() : store.muteAll()
                }
                .controlSize(.mini)
            }

            // Master Volume ("Ana ses")
            HStack(spacing: 8) {
                Button {
                    store.toggleMasterMute()
                } label: {
                    Image(systemName: store.masterMuted
                          ? "speaker.slash.fill"
                          : (store.masterVolume > 0.5 ? "speaker.wave.3.fill" : "speaker.wave.1.fill"))
                        .font(.system(size: 12))
                        .foregroundStyle(store.masterMuted ? Color.secondary : Color.accentColor)
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Ana sesi kapat / aç", "Mute / unmute master volume", lang: store.lang))

                Text(L10n.text("Ana ses", "Master", lang: store.lang))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { Double(store.masterVolume * 100) },
                        set: { store.setMasterVolume(Float($0 / 100)) }
                    ),
                    in: 0...100
                )
                .controlSize(.mini)
                .disabled(store.masterMuted)
                .onTapGesture(count: 2) {
                    store.setMasterVolume(1.0)
                }
                .accessibilityLabel(L10n.text("Ana ses", "Master volume", lang: store.lang))

                Text(store.masterMuted ? L10n.text("sessiz", "muted", lang: store.lang) : "\(Int((store.masterVolume * 100).rounded()))%")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(store.masterMuted ? .secondary : .primary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct AppMixerRow: View {
    @ObservedObject var store: MixerStore
    let row: MixerStore.Row

    @State private var sliderPercent: Double

    init(store: MixerStore, row: MixerStore.Row) {
        self.store = store
        self.row = row
        _sliderPercent = State(initialValue: Double(row.tap.bus.gainPercent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                iconView
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if row.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                        outputBadge
                        Spacer(minLength: 4)
                        Text(gainLabel)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(row.tap.bus.isMuted ? Color.secondary : (sliderPercent > 100.5 ? Color.orange : Color.primary))
                    }

                    HStack(spacing: 8) {
                        Slider(
                            value: $sliderPercent,
                            in: 0...200
                        )
                        .controlSize(.mini)
                        .disabled(row.tap.bus.isMuted)
                        .onChange(of: sliderPercent) { _, newValue in
                            store.setGain(for: row, percent: Float(newValue))
                        }
                        .onTapGesture(count: 2) {
                            sliderPercent = 100
                            store.resetGain(for: row)
                        }
                        .accessibilityLabel(L10n.text("\(row.name) ses seviyesi", "\(row.name) volume", lang: store.lang))
                        .help(L10n.text("Çift tıklayarak %100'e sıfırla", "Double-click to reset to 100%", lang: store.lang))

                        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                            LevelMeterView(
                                level: row.tap.bus.peak,
                                muted: row.tap.bus.isMuted,
                                tint: isRoutedElsewhere ? Color.purple : Color.accentColor
                            )
                        }
                    }
                }

                HStack(spacing: 4) {
                    Button {
                        store.toggleMute(for: row)
                    } label: {
                        Image(systemName: row.tap.bus.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(row.tap.bus.isMuted ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(row.tap.bus.isMuted
                                        ? L10n.text("\(row.name) sesini aç", "Unmute \(row.name)", lang: store.lang)
                                        : L10n.text("\(row.name) sessize al", "Mute \(row.name)", lang: store.lang))
                    .help(row.tap.bus.isMuted
                          ? L10n.text("Sesi geri aç", "Unmute", lang: store.lang)
                          : L10n.text("Sessize al", "Mute", lang: store.lang))

                    Menu {
                        rowMenuItems()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 18)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
        .contextMenu {
            rowMenuItems()
        }
        .onChange(of: row.controlRevision) { _, _ in
            sliderPercent = Double(row.tap.bus.gainPercent)
        }
    }

    @ViewBuilder
    private func rowMenuItems() -> some View {
        Button {
            store.showingEQForKey = row.key
        } label: {
            Label(L10n.text("10-Bant EQ", "10-Band EQ", lang: store.lang), systemImage: "slider.vertical.3")
        }

        Button {
            store.togglePin(for: row)
        } label: {
            Label(
                row.isPinned
                    ? L10n.text("Sabitlemeyi kaldır", "Unpin", lang: store.lang)
                    : L10n.text("Listeye sabitle", "Pin row", lang: store.lang),
                systemImage: row.isPinned ? "pin.slash" : "pin"
            )
        }

        Button {
            store.toggleMute(for: row)
        } label: {
            Label(
                row.tap.bus.isMuted
                    ? L10n.text("Sesi geri aç", "Unmute", lang: store.lang)
                    : L10n.text("Sessize al", "Mute", lang: store.lang),
                systemImage: row.tap.bus.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
            )
        }

        Button {
            sliderPercent = 100
            store.resetGain(for: row)
        } label: {
            Label(L10n.text("%100'e sıfırla", "Reset to 100%", lang: store.lang), systemImage: "arrow.counterclockwise")
        }

        Divider()

        Menu(L10n.text("Çıkış Cihazı", "Output Device", lang: store.lang)) {
            outputMenuItems()
        }
    }

    /// The routing choices, shared by the row badge and the row menu.
    @ViewBuilder
    private func outputMenuItems() -> some View {
        Button {
            store.setAppOutputDevice(nil, forKey: row.key)
        } label: {
            HStack {
                Text(L10n.text("Ana Çıkış", "Main Output", lang: store.lang))
                if row.outputDeviceUID == nil { Image(systemName: "checkmark") }
            }
        }
        Divider()
        ForEach(store.availableOutputs, id: \.uid) { device in
            Button {
                store.setAppOutputDevice(device, forKey: row.key)
            } label: {
                HStack {
                    Text(device.name)
                    if row.outputDeviceUID == device.uid { Image(systemName: "checkmark") }
                }
            }
        }
    }

    /// True when this row plays somewhere other than the mixer's main output,
    /// which is worth spotting at a glance in a long list.
    private var isRoutedElsewhere: Bool {
        guard row.outputDeviceUID != nil else { return false }
        return row.tap.outputDevice.uid != store.activeOutputDevice?.uid
    }

    /// Clicking the device chip routes this application, and the choice is saved
    /// in the active profile's rules.
    private var outputBadge: some View {
        Menu {
            outputMenuItems()
        } label: {
            HStack(spacing: 2) {
                if isRoutedElsewhere {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 7, weight: .semibold))
                }
                Text(row.outputDeviceUID == nil
                     ? L10n.text("Çıkış", "Output", lang: store.lang)
                     : row.outputDeviceName)
                    .font(.system(size: 9, weight: isRoutedElsewhere ? .semibold : .regular))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .semibold))
            }
            .foregroundStyle(badgeForeground)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(badgeBackground, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.text(
            isRoutedElsewhere
                ? "\(row.name) → \(row.outputDeviceName) (ana çıkıştan farklı)"
                : "\(row.name) çıkış cihazını seç",
            isRoutedElsewhere
                ? "\(row.name) → \(row.outputDeviceName) (not the main output)"
                : "Choose output for \(row.name)",
            lang: store.lang
        ))
    }

    private var badgeForeground: Color {
        if isRoutedElsewhere { return .accentColor }
        return row.outputDeviceUID == nil ? .secondary : .primary
    }

    private var badgeBackground: AnyShapeStyle {
        isRoutedElsewhere
            ? AnyShapeStyle(Color.accentColor.opacity(0.18))
            : AnyShapeStyle(.quaternary)
    }

    @ViewBuilder
    private var iconView: some View {
        if let image = row.icon {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(row.isSystemSounds ? Color.accentColor : Color.secondary)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .padding(3)
                .foregroundStyle(.secondary)
        }
    }

    private var gainLabel: String {
        if row.tap.bus.isMuted {
            return L10n.text("sessiz", "muted", lang: store.lang)
        }
        return "\(Int(sliderPercent.rounded()))%"
    }
}

/// Inline 10-band equalizer view for a single app row.
struct EqualizerSheetView: View {
    @ObservedObject var store: MixerStore
    let row: MixerStore.Row
    @State private var bands: [Float]

    init(store: MixerStore, row: MixerStore.Row) {
        self.store = store
        self.row = row
        _bands = State(initialValue: row.tap.bus.equalizer.bands)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("\(row.name) — EQ")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Menu(L10n.text("Ön Ayar", "Preset", lang: store.lang)) {
                    ForEach(Equalizer.Preset.allCases, id: \.self) { preset in
                        Button(L10n.eqPresetName(preset, lang: store.lang)) {
                            store.applyEQPreset(preset, for: row)
                            bands = preset.gainsDB
                        }
                    }
                }
                .controlSize(.mini)
                Button(L10n.text("Bitti", "Done", lang: store.lang)) {
                    store.showingEQForKey = nil
                }
                .controlSize(.mini)
            }

            Divider()

            HStack(spacing: 6) {
                ForEach(0..<Equalizer.bandCount, id: \.self) { index in
                    VStack(spacing: 4) {
                        Text(String(format: "%+.0f", bands[index]))
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(bands[index]) },
                                set: { newValue in
                                    bands[index] = Float(newValue)
                                    store.setEQBand(index, gainDB: Float(newValue), for: row)
                                }
                            ),
                            in: Double(Equalizer.minGainDB)...Double(Equalizer.maxGainDB)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 24, height: 74)
                        Text(freqLabel(Equalizer.frequencies[index]))
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 26)
                }
            }
        }
        .padding(12)
        .frame(width: 356)
    }

    private func freqLabel(_ hz: Double) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }
}
