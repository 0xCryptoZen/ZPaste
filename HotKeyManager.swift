import AppKit
import Carbon

extension Notification.Name {
    static let quickPasteHotKey = Notification.Name("ZPaste.QuickPasteHotKey")
}

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var registeredCode: UInt32?
    private var registeredModifiers: UInt32?
    private let hotKeyID = EventHotKeyID(signature: OSType(0x5043_5445), id: 1)

    struct RegistrationError: LocalizedError {
        let code: OSStatus
        var errorDescription: String? {
            "This shortcut could not be registered (\(code)). It may already be used by another app. Choose a different shortcut."
        }
    }

    func registerSaved() throws {
        try register(
            keyCode: UInt32(UserDefaults.standard.integer(forKey: "hotKeyCode")),
            modifiers: UInt32(UserDefaults.standard.integer(forKey: "hotKeyModifiers"))
        )
    }

    func register(keyCode: UInt32, modifiers: UInt32) throws {
        if registeredCode == keyCode && registeredModifiers == modifiers { return }
        if eventHandlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, _ -> OSStatus in
                    NotificationCenter.default.post(name: .quickPasteHotKey, object: nil)
                    return noErr
                },
                1, &spec, nil, &eventHandlerRef
            )
            guard status == noErr else { throw RegistrationError(code: status) }
        }
        // Register the replacement before removing the working shortcut.
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr else { throw RegistrationError(code: status) }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = replacement
        registeredCode = keyCode
        registeredModifiers = modifiers
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        hotKeyRef = nil
        eventHandlerRef = nil
        registeredCode = nil
        registeredModifiers = nil
    }
}
