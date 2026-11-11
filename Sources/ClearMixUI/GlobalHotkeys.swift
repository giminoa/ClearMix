import Carbon
import Foundation

/// Lightweight Carbon global hotkey controller (requires no Accessibility permission).
///
/// Shortcuts registered when enabled:
/// - `⌃⌥M`: Toggle master mute
/// - `⌃⌥K`: Start / stop microphone cleaner
/// - `⌃⌥D`: Toggle RNNoise noise suppression
@MainActor
final class GlobalHotkeys {
    enum Action: UInt32, CaseIterable {
        case toggleMasterMute = 1
        case toggleMicrophone = 2
        case toggleDenoise = 3
    }

    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private let onAction: @MainActor (Action) -> Void

    private static weak var activeInstance: GlobalHotkeys?

    init(onAction: @escaping @MainActor (Action) -> Void) {
        self.onAction = onAction
    }

    func setEnabled(_ enabled: Bool) {
        unregisterAll()
        guard enabled else { return }
        registerAll()
    }

    func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        if Self.activeInstance === self {
            Self.activeInstance = nil
        }
    }

    private func registerAll() {
        Self.activeInstance = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.carbonCallback,
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard status == noErr else { return }

        let modifiers = UInt32(controlKey | optionKey)
        let mappings: [(Action, Int)] = [
            (.toggleMasterMute, kVK_ANSI_M),
            (.toggleMicrophone, kVK_ANSI_K),
            (.toggleDenoise, kVK_ANSI_D),
        ]

        let signature: OSType = 0x434D_4958 // 'CMIX'
        for (action, keyCode) in mappings {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: action.rawValue)
            if RegisterEventHotKey(
                UInt32(keyCode),
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            ) == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
            }
        }
    }

    private static let carbonCallback: EventHandlerUPP = { _, event, _ in
        guard let event else { return noErr }
        var hotKeyID = EventHotKeyID()
        let err = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard err == noErr, let action = Action(rawValue: hotKeyID.id) else {
            return noErr
        }
        Task { @MainActor in
            GlobalHotkeys.activeInstance?.onAction(action)
        }
        return noErr
    }
}
