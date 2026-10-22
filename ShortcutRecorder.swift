import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    var label: String
    var onRecord: (UInt32, UInt32, String) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(RecorderButton.beginRecording)
        button.onRecord = onRecord
        button.displayLabel = label
        button.title = label
        button.setAccessibilityLabel("Record global shortcut")
        button.toolTip = "Click, then press a shortcut with Command, Control, or Option. Escape cancels."
        return button
    }

    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) {
        button.cancelRecording()
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.displayLabel = label
        button.onRecord = onRecord
        if !button.recording { button.title = label }
    }
}

final class RecorderButton: NSButton {
    var onRecord: ((UInt32, UInt32, String) -> Void)?
    var displayLabel = "⌘⇧V"
    private(set) var recording = false
    override var acceptsFirstResponder: Bool { true }

    @objc func beginRecording() {
        if recording { finish(); return }
        window?.makeFirstResponder(self)
        recording = true
        title = "Press shortcut… (Esc cancels)"
        if !UIPreviewData.enabled { HotKeyManager.shared.unregister() }
    }

    override func keyDown(with event: NSEvent) {
        if recording { record(event) } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { record(event); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func resignFirstResponder() -> Bool {
        if recording { finish() }
        return super.resignFirstResponder()
    }

    func cancelRecording() {
        if recording { finish() }
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == 53 { finish(); return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !event.isARepeat, !flags.intersection([.command, .control, .option]).isEmpty else {
            NSSound.beep()
            return
        }
        var modifiers: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); symbols += "⌘" }
        let special: [UInt16: String] = [123: "←", 124: "→", 125: "↓", 126: "↑", 49: "Space", 36: "Return", 48: "Tab", 51: "Delete"]
        let key = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        onRecord?(UInt32(event.keyCode), modifiers, symbols + key)
        finish()
    }

    private func finish() {
        recording = false
        title = displayLabel
        guard !UIPreviewData.enabled else { return }
        do { try HotKeyManager.shared.registerSaved() }
        catch { AppStatus.shared.errorMessage = error.localizedDescription }
    }
}
