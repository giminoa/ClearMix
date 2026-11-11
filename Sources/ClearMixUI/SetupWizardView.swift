import ClearMixCore
import SwiftUI

/// Three-step setup & BlackHole onboarding wizard matching the ClearMix roadmap:
/// 1. Permissions (Microphone + System Audio Capture)
/// 2. BlackHole 2ch check & install guide (+ Bluetooth headset quality tip)
/// 3. Discord / Zoom / OBS input guide & live self-monitor audio test
struct SetupWizardView: View {
    @ObservedObject var store: MixerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            stepContent
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 356)
        .onAppear {
            store.refreshNow()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("ClearMix Kurulum Sihirbazı", "ClearMix Setup Wizard", lang: store.lang))
                    .font(.system(size: 13, weight: .semibold))
                Text(L10n.text("Adım \(store.setupWizardStep) / 3", "Step \(store.setupWizardStep) of 3", lang: store.lang))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.text("Atla", "Skip", lang: store.lang)) {
                store.completeOnboarding()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch store.setupWizardStep {
        case 1:
            permissionsStep
        case 2:
            blackHoleStep
        default:
            discordAndTestStep
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("1. Sistem İzinleri", "1. System Permissions", lang: store.lang))
                .font(.system(size: 12, weight: .semibold))

            // Microphone permission row
            HStack(spacing: 8) {
                Image(systemName: store.microphoneAuthorized ? "checkmark.circle.fill" : "mic.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(store.microphoneAuthorized ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Mikrofon Erişimi", "Microphone Access", lang: store.lang))
                        .font(.system(size: 11, weight: .medium))
                    Text(store.microphoneAuthorized
                         ? L10n.text("Onaylandı", "Granted", lang: store.lang)
                         : L10n.text("Gürültü temizleme için gerekir", "Required for voice noise suppression", lang: store.lang))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !store.microphoneAuthorized {
                    Button(L10n.text("İzin Ver", "Allow", lang: store.lang)) {
                        store.requestMicrophonePermission()
                    }
                    .controlSize(.small)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

            // System audio capture row
            let audioReady = !store.needsAudioCapturePermission && !store.suspectedCaptureSilence
            HStack(spacing: 8) {
                Image(systemName: audioReady ? "checkmark.circle.fill" : "speaker.wave.2.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(audioReady ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Sistem Sesi Kaydı", "System Audio Capture", lang: store.lang))
                        .font(.system(size: 11, weight: .medium))
                    Text(L10n.text(
                        "Uygulama seslerini sürücüsüz kısmak için Gizlilik ayarından onaylayın.",
                        "Approve in Privacy Settings so ClearMix can tap app audio.",
                        lang: store.lang
                    ))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(L10n.text("Ayarlar", "Privacy", lang: store.lang)) {
                    store.openAudioPrivacySettings()
                }
                .controlSize(.small)
            }
            .padding(8)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var blackHoleStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("2. BlackHole 2ch Sanal Mikrofon", "2. BlackHole 2ch Virtual Mic", lang: store.lang))
                .font(.system(size: 12, weight: .semibold))

            if let blackHole = store.blackHoleDevice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("\"\(blackHole.name)\" hazır!", "\"\(blackHole.name)\" is ready!", lang: store.lang))
                            .font(.system(size: 11, weight: .semibold))
                        Text(L10n.text(
                            "ClearMix temizlenmiş sesinizi otomatik olarak bu cihaza aktarır.",
                            "ClearMix automatically sends your denoised voice to this device.",
                            lang: store.lang
                        ))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.orange)
                        Text(L10n.text("BlackHole 2ch henüz kurulu değil", "BlackHole 2ch is not installed yet", lang: store.lang))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(L10n.text(
                        "Discord, Zoom veya OBS'e temizlenmiş ses göndermek için BlackHole 2ch kurun (yalnızca ses mikseri için zorunlu değildir):",
                        "Install BlackHole 2ch to send denoised mic audio to Discord, Zoom, or OBS (optional if you only use the app mixer):",
                        lang: store.lang
                    ))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Text(L10n.text(
                        "ClearMix resmi ve imzalı paketi kendisi indirir, doğrular ve kurar. Yalnızca macOS'un yönetici parolası penceresi çıkar; Terminal ya da Homebrew gerekmez.",
                        "ClearMix downloads, verifies and installs the official signed package itself. Only macOS's admin password prompt appears; no Terminal or Homebrew needed.",
                        lang: store.lang
                    ))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Button {
                            store.installBlackHole()
                        } label: {
                            if store.isInstallingBlackHole {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.mini)
                                    Text(L10n.text("Kuruluyor…", "Installing…", lang: store.lang))
                                }
                            } else {
                                Label(L10n.text("BlackHole'u kur", "Install BlackHole", lang: store.lang), systemImage: "arrow.down.circle")
                            }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isInstallingBlackHole)

                        Button(L10n.text("Resmi İndirme", "Download Page", lang: store.lang)) {
                            store.openBlackHoleDownloadPage()
                        }
                        .controlSize(.mini)
                        Button(L10n.text("Tekrar kontrol et", "Recheck", lang: store.lang)) {
                            store.refreshNow()
                        }
                        .controlSize(.mini)
                    }

                    if let message = store.blackHoleInstallMessage {
                        Text(message)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            // Bluetooth headphone quality tip from Section 11 of roadmap
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "headphones")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                Text(L10n.text(
                    "İpucu: Bluetooth kulaklığın mikrofonunu açmak macOS'te çıkış ses kalitesini düşürür. En iyi kalite için Mac/USB mikrofonu + Bluetooth kulaklık çıkışı önerilir.",
                    "Tip: Opening a Bluetooth headset mic lowers macOS audio output quality. Use Built-in/USB mic + Bluetooth headphones for best sound.",
                    lang: store.lang
                ))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(7)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var discordAndTestStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("3. Discord / Zoom Bağlantısı ve Test", "3. Discord / Zoom Setup & Test", lang: store.lang))
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("• ClearMix Mikrofon sekmesinden mikrofonunuzu Başlat'ın.", "• Start your mic in ClearMix's Microphone tab.", lang: store.lang))
                Text(L10n.text("• Discord / Zoom / OBS ses ayarlarında Giriş Cihazı olarak \"BlackHole 2ch\" seçin.", "• Choose \"BlackHole 2ch\" as Input Device in Discord / Zoom / OBS.", lang: store.lang))
                Text(L10n.text("• Çift işlemeyi önlemek için Discord içindeki Krisp'i kapatabilirsiniz.", "• Optionally disable Discord's built-in Krisp to avoid double processing.", lang: store.lang))
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        if !store.isMicrophoneRunning {
                            store.toggleMicrophone()
                        }
                        if !store.isMonitoringMic {
                            store.toggleMonitorMicrophone()
                        }
                    } label: {
                        Label(
                            L10n.text("Test Et (Kendimi Dinle)", "Test & Monitor Voice", lang: store.lang),
                            systemImage: "waveform.and.mic"
                        )
                        .font(.system(size: 10, weight: .medium))
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)

                    if store.isMonitoringMic {
                        Button(L10n.text("Dinlemeyi Durdur", "Stop Monitor", lang: store.lang)) {
                            store.toggleMonitorMicrophone()
                        }
                        .controlSize(.small)
                    }
                }

                TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Text(L10n.text("Önce", "In", lang: store.lang))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            LevelMeterView(
                                level: store.isMicrophoneRunning ? store.microphoneInputPeak : 0,
                                muted: !store.isMicrophoneRunning,
                                width: 64,
                                height: 5
                            )
                        }
                        HStack(spacing: 4) {
                            Text(L10n.text("Sonra", "Out", lang: store.lang))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            LevelMeterView(
                                level: store.isMicrophoneRunning ? store.microphonePeak : 0,
                                muted: !store.isMicrophoneRunning,
                                width: 64,
                                height: 5
                            )
                        }
                        Spacer()
                    }
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var footer: some View {
        HStack {
            if store.setupWizardStep > 1 {
                Button(L10n.text("Geri", "Back", lang: store.lang)) {
                    store.setupWizardStep -= 1
                }
                .controlSize(.small)
            }
            Spacer()
            if store.setupWizardStep < 3 {
                Button(L10n.text("Devam", "Next", lang: store.lang)) {
                    store.setupWizardStep += 1
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            } else {
                Button(L10n.text("Kurulumu Tamamla", "Finish Setup", lang: store.lang)) {
                    if store.isMonitoringMic {
                        store.toggleMonitorMicrophone()
                    }
                    store.completeOnboarding()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
