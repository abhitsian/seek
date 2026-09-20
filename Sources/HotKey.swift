import AppKit
import Carbon

/// A system-wide shortcut registered through Carbon. Works without Input Monitoring permission.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    private var ref: EventHotKeyRef?
    private let id: UInt32
    let registered: Bool

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        HotKey.installHandler()
        id = HotKey.nextID
        HotKey.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x5345_454B), id: id) // 'SEEK'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        registered = status == noErr
        if registered { HotKey.handlers[id] = handler }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        HotKey.handlers[id] = nil
    }

    deinit { unregister() }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let handler = HotKey.handlers[hotKeyID.id]
            DispatchQueue.main.async { handler?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// The shortcut choices offered in Settings.
struct Shortcut: Equatable {
    let label: String
    let keyCode: UInt32
    let modifiers: UInt32
    let menuKey: String
    let menuModifiers: NSEvent.ModifierFlags

    static let presets: [Shortcut] = [
        Shortcut(label: "⌃⌥F", keyCode: 3, modifiers: UInt32(controlKey | optionKey),
                 menuKey: "f", menuModifiers: [.control, .option]),
        Shortcut(label: "⌥Space", keyCode: 49, modifiers: UInt32(optionKey),
                 menuKey: " ", menuModifiers: [.option]),
        Shortcut(label: "⌃⌥⌘F", keyCode: 3, modifiers: UInt32(controlKey | optionKey | cmdKey),
                 menuKey: "f", menuModifiers: [.control, .option, .command]),
    ]
}
