import ClearMixCore
import SwiftUI

/// Microphone denoiser, noise gate, A/B comparison, self-monitoring and BlackHole routing tab.
struct MicrophoneTabView: View {
    @ObservedObject var store: MixerStore

    var body: some View {
        VStack(spacing: 10) {
            inputSelectorRow
            if store.isCurrentInputBluetooth {
                bluetoothWarningCard
            }
            processingCard
            blackHoleCard
            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var bluetoothWarningCard: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "headphones.circle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(L10n.text(
                "Bluetooth mikrofonu açıkken macOS kulaklık ses kalitesini düşürür. Dahili/USB mikrofon önerilir.",
                "Using a Bluetooth mic lowers macOS headphone audio quality. Built-in/USB mic recommended.",
                lang: store.lang
            ))
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var inputSelectorRow: some View {
        HStack(spacing: 8) {
            Image(systemName: store.isMicrophoneRunning ? "mic.fill" : "mic.slash")
                .font(.system(size: 12))
                .foregroundStyle(store.isMicrophoneRunning ? Color.accentColor : Color.secondary)

            Menu {
                ForEach(store.availableInputs, id: \.uid) { device in
                    Button {
                        store.selectInputDevice(device)
                    } label: {
                        HStack {
                            Text(device.name)
                            if store.settings.preferredInputDeviceUID == device.uid
                                || (store.settings.preferredInputDeviceUID == nil && device.uid == store.availableInputs.first?.uid) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentInputName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)

            Spacer(minLength: 4)

            Button(store.isMicrophoneRunning
                   ? L10n.text("Kapat", "Stop", lang: store.lang)
                   : L10n.text("Başlat", "Start", lang: store.lang)) {
                store.toggleMicrophone()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(store.isMicrophoneRunning ? .red : .accentColor)
        }
    }

    private var currentInputName: String {
        if let uid = store.settings.preferredInputDeviceUID,
           let found = store.availableInputs.first(where: { $0.uid == uid }) {
            return found.name
        }
        return AudioDevices.defaultInput()?.name
            ?? store.availableInputs.first?.name
            ?? L10n.text("Mikrofon yok", "No microphone", lang: store.lang)
    }

    private var processingCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Denoise toggle
            Toggle(isOn: Binding(
                get: { store.settings.denoiseEnabled },
                set: { store.setDenoiseEnabled($0) }
            )) {
                Text(L10n.text("Gürültü Temizleme (RNNoise)", "Noise Suppression (RNNoise)", lang: store.lang))
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            // Strength slider
            HStack(spacing: 8) {
                Text(L10n.text("Güç", "Strength", lang: store.lang))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(store.settings.denoiseStrength * 100) },
                        set: { store.setDenoiseStrength(Float($0 / 100)) }
                    ),
                    in: 0...100
                )
                .controlSize(.mini)
                .disabled(!store.settings.denoiseEnabled)
                Text("\(Int((store.settings.denoiseStrength * 100).rounded()))%")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            // Noise gate toggle + threshold
            Toggle(isOn: Binding(
                get: { store.settings.gateEnabled },
                set: { store.setGateEnabled($0) }
            )) {
                Text(L10n.text("Gürültü Kapısı", "Noise Gate", lang: store.lang))
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if store.settings.gateEnabled {
                HStack(spacing: 8) {
                    Text(L10n.text("Eşik", "Threshold", lang: store.lang))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { Double(store.settings.gateThresholdDB) },
                            set: { store.setGateThreshold(Float($0)) }
                        ),
                        in: -70...(-20)
                    )
                    .controlSize(.mini)
                    Text("\(Int(store.settings.gateThresholdDB.rounded())) dB")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }

            // Mic gain
            HStack(spacing: 8) {
                Text(L10n.text("Kazanç", "Gain", lang: store.lang))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(store.settings.micGainDB) },
                        set: { store.setMicGain(Float($0)) }
                    ),
                    in: -12...18
                )
                .controlSize(.mini)
                .onTapGesture(count: 2) {
                    store.setMicGain(0)
                }
                Text(String(format: "%+.0f dB", store.settings.micGainDB))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            Divider()

            // Before / After live meters
            TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        Text(L10n.text("Önce", "In", lang: store.lang))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        LevelMeterView(
                            level: store.isMicrophoneRunning ? store.microphoneInputPeak : 0,
                            muted: !store.isMicrophoneRunning,
                            width: 58,
                            height: 5
                        )
                    }
                    HStack(spacing: 5) {
                        Text(L10n.text("Sonra", "Out", lang: store.lang))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        LevelMeterView(
                            level: store.isMicrophoneRunning ? store.microphonePeak : 0,
                            muted: !store.isMicrophoneRunning,
                            width: 58,
                            height: 5
                        )
                    }
                    Spacer()
                    if store.isMicrophoneRunning {
                        Text("\(store.microphoneLatencyMilliseconds) ms")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // A/B & Self-Monitor
            HStack(spacing: 8) {
                Button {
                    store.toggleABCompare()
                } label: {
                    Label(
                        store.isABComparing
                            ? L10n.text("Ham (A/B)", "Raw (A/B)", lang: store.lang)
                            : L10n.text("A/B Dinle", "A/B Bypass", lang: store.lang),
                        systemImage: "waveform.path.ecg"
                    )
                    .font(.system(size: 10))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(store.isABComparing ? .orange : .secondary)

                Button {
                    store.toggleMonitorMicrophone()
                } label: {
                    Label(
                        L10n.text("Kendimi duy", "Monitor", lang: store.lang),
                        systemImage: store.isMonitoringMic ? "headphones.circle.fill" : "headphones"
                    )
                    .font(.system(size: 10))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(store.isMonitoringMic ? .accentColor : .secondary)

                Spacer()
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var blackHoleCard: some View {
        Group {
            if let blackHole = store.blackHoleDevice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                    Text(L10n.text(
                        "Discord / Zoom / OBS'e hazır: giriş cihazı olarak \"\(blackHole.name)\" seçin.",
                        "Ready for Discord / Zoom / OBS: select \"\(blackHole.name)\" as mic input.",
                        lang: store.lang
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 12))
                        Text(L10n.text(
                            "Sanal mikrofon (BlackHole 2ch) bulunamadı",
                            "Virtual mic (BlackHole 2ch) not found",
                            lang: store.lang
                        ))
                        .font(.system(size: 10, weight: .semibold))
                    }
                    Text(L10n.text(
                        "Temiz sesi Discord/OBS'e vermek için: brew install --cask blackhole-2ch",
                        "To route clean mic to Discord/OBS: brew install --cask blackhole-2ch",
                        lang: store.lang
                    ))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Button(L10n.text("Nasıl kurulur", "How to install", lang: store.lang)) {
                            store.openSetupWizard(step: 2)
                        }
                        .controlSize(.mini)
                        .buttonStyle(.borderedProminent)
                        Button(L10n.text("Komutu kopyala", "Copy command", lang: store.lang)) {
                            store.copyBlackHoleInstallCommand()
                        }
                        .controlSize(.mini)
                        Button(L10n.text("Kontrol et", "Recheck", lang: store.lang)) {
                            store.refreshNow()
                        }
                        .controlSize(.mini)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
