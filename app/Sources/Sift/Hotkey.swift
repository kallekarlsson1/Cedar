import Carbon
import AppKit

/// A system-wide keyboard shortcut (Carbon's RegisterEventHotKey: no Accessibility permission needed).
final class Hotkey {
    struct Combo: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32     // Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey)
        var label: String
    }

    static let choices: [Combo] = [
        Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), label: "⌘ Space"),
        Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), label: "⌥ Space"),
        Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey), label: "⌃ Space"),
        Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘ Space"),
    ]

    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private(set) var combo: Combo?

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return noErr }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(data).takeUnretainedValue()
            DispatchQueue.main.async { hotkey.action() }
            return noErr
        }, 1, &spec, me, &handlerRef)
    }

    /// Returns false when the system refused the shortcut (another app holds it).
    @discardableResult
    func register(_ combo: Combo) -> Bool {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        let id = EventHotKeyID(signature: OSType(0x53494654), id: 1)   // 'SIFT'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        self.combo = status == noErr ? combo : nil
        return status == noErr
    }
}
