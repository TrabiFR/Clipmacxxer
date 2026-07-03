import SwiftUI
import AppKit
import Carbon.HIToolbox

struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? "Type shortcut… (⎋ cancels)" : hotkey.display)
                .frame(minWidth: 110)
        }
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let isFunctionKey = KeyNames.functionKeyCodes.contains(Int(event.keyCode))
            // Require a modifier (or an F-key) so plain typing can't become the hotkey.
            guard !flags.isEmpty || isFunctionKey else { return nil }
            hotkey = Hotkey(
                keyCode: UInt32(event.keyCode),
                carbonModifiers: KeyNames.carbonModifiers(from: flags),
                display: KeyNames.display(keyCode: Int(event.keyCode), flags: flags, event: event)
            )
            stop()
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

enum KeyNames {
    static let functionKeyCodes: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    private static let specialNames: [Int: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    static func display(keyCode: Int, flags: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        if let name = specialNames[keyCode] {
            result += name
        } else {
            result += event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
        return result
    }
}
