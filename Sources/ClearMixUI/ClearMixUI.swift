import AppKit
import SwiftUI

/// ClearMix's menu bar app. No Dock icon: the whole UI is the panel that drops
/// down from the menu bar.
@main
struct ClearMixUI: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = MixerStore.shared

    var body: some Scene {
        MenuBarExtra {
            MixerPanel(store: store)
        } label: {
            Image(systemName: store.menuBarIconName)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Works both from the signed bundle and from `swift run`.
        NSApp.setActivationPolicy(.accessory)
        // The panel is built lazily when the menu opens, so the engine must not
        // wait for it: taps have to run from launch.
        MixerStore.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MixerStore.shared.stop()
    }
}
