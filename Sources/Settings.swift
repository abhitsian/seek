import AppKit
import Foundation

enum Prefs {
    static let changed = Notification.Name("SeekSettingsChanged")

    /// The TypeSafe key: the key file first, then TYPESAFE_API_KEY for command-line runs.
    static var apiKey: String? {
        if let key = KeyFile.read(), !key.isEmpty { return key }
        if let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !key.isEmpty { return key }
        return nil
    }

    static var keySource: String {
        if KeyFile.read() != nil { return "key file" }
        return ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] != nil ? "TYPESAFE_API_KEY" : "none"
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: "model").flatMap { $0.isEmpty ? nil : $0 } ?? "jev-latest" }
        set { UserDefaults.standard.set(newValue, forKey: "model") }
    }

    static var client: Jev.Client? { apiKey.map { Jev.Client(apiKey: $0, model: model) } }

    static var shortcut: Shortcut {
        get { Shortcut.presets.first { $0.label == UserDefaults.standard.string(forKey: "shortcut") } ?? Shortcut.presets[0] }
        set { UserDefaults.standard.set(newValue.label, forKey: "shortcut") }
    }

    static func notify() { NotificationCenter.default.post(name: changed, object: nil) }
}

/// The TypeSafe key, in a file only this user can read (mode 600), the way gh and aws keep tokens.
/// Not the Keychain: without an Apple team ID, Keychain ties an entry to one exact build, so every rebuild
/// of Seek asked for access again.
enum KeyFile {
    static var url: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Seek")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("typesafe-key")
    }

    static func read() -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let path = url.path
        guard FileManager.default.createFile(atPath: path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600]) else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return true
    }

    static func delete() { try? FileManager.default.removeItem(at: url) }
}

/// Talks to Finder: which folder its front window shows, and revealing files.
enum Finder {
    static let bundleID = "com.apple.finder"

    /// The folder in Finder's front window. Asks for Automation permission the first time.
    static func frontFolder() -> URL? {
        let source = """
        tell application "Finder"
            if (count of Finder windows) is 0 then return ""
            try
                return POSIX path of (target of front Finder window as alias)
            on error
                return ""
            end try
        end tell
        """
        var error: NSDictionary?
        guard let path = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    /// Copies a file's path, or the whole link for a Settings page.
    static func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.isFileURL ? url.path : url.absoluteString, forType: .string)
    }
}
