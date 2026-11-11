import ClearMixCore
import SwiftUI

/// The menu bar panel: header with `[ Sesler | Mikrofon ]` tabs, active tab
/// content, and quick settings access.
struct MixerPanel: View {
    @ObservedObject var store: MixerStore

    var body: some View {
        Group {
            if store.showingSetupWizard {
                SetupWizardView(store: store)
            } else if store.showingSettings {
                SettingsSheetView(store: store)
            } else if let eqKey = store.showingEQForKey,
                      let row = store.rows.first(where: { $0.key == eqKey }) {
                EqualizerSheetView(store: store, row: row)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    switch store.selectedTab {
                    case .sounds:
                        SoundsTabView(store: store)
                    case .microphone:
                        MicrophoneTabView(store: store)
                    }
                }
                .frame(width: 356)
            }
        }
        .task { store.start() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(.tint)

            Picker("", selection: $store.selectedTab) {
                Text(L10n.text("Sesler", "Sounds", lang: store.lang))
                    .tag(MixerStore.Tab.sounds)
                Text(L10n.text("Mikrofon", "Mic", lang: store.lang))
                    .tag(MixerStore.Tab.microphone)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 158)

            Spacer()

            Button {
                store.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help(L10n.text("Yenile", "Refresh", lang: store.lang))

            Button {
                store.showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help(L10n.text("Ayarlar", "Settings", lang: store.lang))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
