import AppKit
import Carbon

extension Notification.Name {
    static let quickPasteHotKey = Notification.Name("ZPaste.QuickPasteHotKey")
}

/// Global hotkey (Carbon `RegisterEventHotKey`).
/// Default ⌘⇧V opens the history window.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    // 'PCTE' signature + id 1
    private let hotKeyID = EventHotKeyID(signature: OSType(0x5043_5445), id: 1)

    private init() {}

    deinit { unregister() }

    /// Registers the default hotkey: ⌘⇧V (keyCode 9 = V, modifiers = cmd | shift).
    func registerDefault() {
        register(keyCode: 9, modifiers: 0x0100 | 0x0200)
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                NotificationCenter.default.post(name: .quickPasteHotKey, object: nil)
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandlerRef
        )

        _ = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }
}