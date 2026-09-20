import AppKit

/// Something Seek can open that isn't a file: an app, a System Settings page or section, or a Finder folder.
struct Launchable: Identifiable, Hashable {
    enum Kind: Hashable { case app, settings, place, person, web, tab, hint }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let target: URL
    /// The file whose icon the row shows.
    let iconPath: String
    /// Names people use for it, as phrases: the title plus synonyms ("dark mode" for Appearance).
    let phrases: [String]
    var isPrivacySection = false

    var label: String {
        switch kind {
        case .app: "App"
        case .settings: "Settings"
        case .place: "Folder"
        case .person: "Teams"
        case .web: "Web"
        case .tab: "Tab"
        case .hint: "Set up"
        }
    }
}

/// Finds apps, Settings pages and folders by name, and opens them.
/// Settings pages come from the system's own ExtensionKit bundles, so the list matches this Mac's macOS version.
enum Launcher {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var items: [Launchable] = []

    nonisolated(unsafe) private static var builtAt = Date.distantPast

    static var catalog: [Launchable] { lock.withLock { items } }

    /// Rebuilds in the background when the catalog is over a minute old, so newly installed apps show up.
    static func refreshIfStale() {
        let stale = lock.withLock { Date().timeIntervalSince(builtAt) > 60 }
        if stale { DispatchQueue.global(qos: .userInitiated).async { refresh() } }
    }

    /// Builds the catalog: a few hundred apps plus 51 Settings pages takes about 50 ms. Call it off the main thread.
    static let refreshed = Notification.Name("SeekLaunchablesRefreshed")

    static func refresh() {
        let built = settingsPages() + privacySections() + places() + apps()
        lock.withLock {
            items = built
            builtAt = Date()
        }
        NotificationCenter.default.post(name: refreshed, object: nil)
    }

    static func open(_ item: Launchable) {
        switch item.kind {
        case .app: NSWorkspace.shared.openApplication(at: item.target, configuration: NSWorkspace.OpenConfiguration())
        case .settings, .place, .person, .web: NSWorkspace.shared.open(item.target)
        case .tab: ChromeTabs.focus(item)
        case .hint: break // the panel opens Seek's Settings
        }
    }

    // MARK: Matching

    /// Words that ask to open something rather than name it.
    private static let openCues: Set<String> = ["open", "launch", "start", "run", "app", "apps", "application", "go"]
    private static let settingsCues: Set<String> = ["settings", "setting", "preferences", "preference", "prefs", "system",
                                                    "pane", "section", "page", "turn", "change", "adjust", "enable",
                                                    "disable", "toggle", "manage", "permission", "permissions", "allow", "access"]
    private static let ignored: Set<String> = openCues.union(settingsCues).union(["take", "to", "on", "off", "how", "do", "i", "the", "my"])

    /// "open bluetooth settings", "screen recording permission": the search is about Settings, not files.
    static func isSettingsRequest(_ query: String) -> Bool {
        Words.split(query).contains { settingsCues.contains($0.text.lowercased()) }
    }

    /// Launchables that match the search well enough to show above the files. Empty for ordinary file searches.
    static func matches(_ query: String, limit: Int = 4) -> [Launchable] {
        let words = Words.split(query).map { $0.text.lowercased() }
        // Split the way titles are split, so "wi-fi" meets "Wi‑Fi".
        let core = words.filter { !ignored.contains($0) && !Words.filler.contains($0) }.flatMap(tokens)
        let wantsOpen = words.contains(where: openCues.contains)
        let wantsSettings = words.contains(where: settingsCues.contains)
        guard !core.isEmpty else {
            // "settings" or "open settings" on its own: the System Settings app.
            return wantsSettings ? catalog.filter { $0.id == "app:" + settingsApp } : []
        }
        let wantsPrivacy = words.contains { ["permission", "permissions", "privacy", "allow", "access"].contains($0) }

        var scored: [(item: Launchable, score: Double)] = []
        for item in catalog {
            let phrases = item.phrases.map(tokens)
            let known = Set(phrases.joined())
            var total = 0.0
            var matchedAll = true
            for word in core {
                if known.contains(word) {
                    total += 1
                } else if word.count >= 3, known.contains(where: { $0.hasPrefix(word) }) {
                    total += 0.7
                } else {
                    matchedAll = false
                    break
                }
            }
            guard matchedAll else { continue }
            // The search names the thing: every word of its title or of a synonym is in the search.
            let named = phrases.contains { !$0.isEmpty && $0.allSatisfy(core.contains) }
            guard named || wantsOpen || wantsSettings else { continue }
            var score = total / Double(core.count)
            if named { score += 0.5 }
            if tokens(item.title).allSatisfy(core.contains) { score += 0.3 }
            if wantsSettings, item.kind == .settings { score += 0.4 }
            if wantsPrivacy, item.isPrivacySection { score += 0.4 }
            if wantsOpen, item.kind == .app { score += 0.2 }
            if !wantsPrivacy, item.isPrivacySection { score -= 0.3 } // "photos" means the app, not its permission page
            scored.append((item, score))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.item.title.count < $1.item.title.count }
            .prefix(limit).map(\.item)
    }

    private static func tokens(_ phrase: String) -> [String] {
        phrase.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { stem(String($0)) }
    }

    /// "notifications" → "notification", so plurals match.
    private static func stem(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
    }

    // MARK: Catalog

    private static let settingsApp = "/System/Applications/System Settings.app"
    private static let extensions = "/System/Library/ExtensionKit/Extensions"

    /// Names the system bundles leave internal, and what people call each page.
    private static let paneNames: [String: String] = [
        "com.apple.Battery-Settings.extension": "Battery",
        "com.apple.HeadphoneSettings": "Headphones",
        "com.apple.Siri-Settings.extension": "Apple Intelligence & Siri",
        "com.apple.ControlCenter-Settings.extension": "Menu Bar",
    ]
    private static let paneSynonyms: [String: [String]] = [
        "com.apple.wifi-settings-extension": ["wifi", "wireless", "internet"],
        "com.apple.BluetoothSettings": ["bluetooth", "airpods"],
        "com.apple.Network-Settings.extension": ["ethernet", "firewall", "proxy", "dns"],
        "com.apple.Battery-Settings.extension": ["power", "energy", "low power mode", "charging"],
        "com.apple.Displays-Settings.extension": ["display", "monitor", "resolution", "brightness", "night shift", "external display"],
        "com.apple.Sound-Settings.extension": ["volume", "audio", "speaker", "sound output", "sound input", "alert sound"],
        "com.apple.Notifications-Settings.extension": ["notification", "alerts", "banners"],
        "com.apple.Focus-Settings.extension": ["do not disturb", "dnd"],
        "com.apple.Appearance-Settings.extension": ["dark mode", "light mode", "theme", "accent color", "highlight color", "scroll bars"],
        "com.apple.Accessibility-Settings.extension": ["voiceover", "zoom", "contrast", "reduce motion", "larger text"],
        "com.apple.Desktop-Settings.extension": ["dock", "hot corners", "stage manager", "mission control", "default browser", "widgets"],
        "com.apple.Wallpaper-Settings.extension": ["background", "desktop picture"],
        "com.apple.Lock-Screen-Settings.extension": ["screen saver", "require password", "display sleep"],
        "com.apple.Touch-ID-Settings.extension": ["fingerprint", "login password", "change password"],
        "com.apple.Users-Groups-Settings.extension": ["users", "guest user", "login options"],
        "com.apple.Internet-Accounts-Settings.extension": ["email accounts", "mail accounts", "google account"],
        "com.apple.Keyboard-Settings.extension": ["keyboard shortcuts", "dictation", "input sources", "key repeat", "text replacement"],
        "com.apple.Trackpad-Settings.extension": ["gestures", "tap to click", "scroll direction"],
        "com.apple.Mouse-Settings.extension": ["tracking speed", "scroll direction"],
        "com.apple.Print-Scan-Settings.extension": ["printer", "scanner", "print"],
        "com.apple.SystemProfiler.AboutExtension": ["about this mac", "serial number", "macos version"],
        "com.apple.Software-Update-Settings.extension": ["update", "upgrade", "macos update"],
        "com.apple.settings.Storage": ["disk space", "free space"],
        "com.apple.AirDrop-Handoff-Settings.extension": ["airplay receiver", "continuity"],
        "com.apple.LoginItems-Settings.extension": ["startup apps", "open at login", "background items"],
        "com.apple.Localization-Settings.extension": ["language", "region", "date format"],
        "com.apple.Date-Time-Settings.extension": ["time zone", "clock"],
        "com.apple.Sharing-Settings.extension": ["screen sharing", "file sharing", "remote login", "ssh", "computer name", "hostname"],
        "com.apple.Time-Machine-Settings.extension": ["backup", "backups"],
        "com.apple.Transfer-Reset-Settings.extension": ["erase", "factory reset"],
        "com.apple.Siri-Settings.extension": ["siri", "apple intelligence", "chatgpt"],
        "com.apple.Spotlight-Settings.extension": ["search index"],
        "com.apple.ControlCenter-Settings.extension": ["control center", "menu bar icons"],
        "com.apple.settings.PrivacySecurity.extension": ["privacy", "security", "filevault", "gatekeeper", "permissions"],
        "com.apple.systempreferences.AppleIDSettings": ["icloud", "apple id", "apple account"],
        "com.apple.WalletSettingsExtension": ["wallet", "apple pay"],
        "com.apple.Family-Settings.extension": ["family sharing"],
        "com.apple.Profiles-Settings.extension": ["profiles", "mdm"],
        "com.apple.Screen-Time-Settings.extension": ["app limits", "downtime"],
    ]

    private static func settingsPages() -> [Launchable] {
        guard let bundles = try? FileManager.default.contentsOfDirectory(atPath: extensions) else { return [] }
        return bundles.filter { $0.hasSuffix(".appex") }.compactMap { bundle -> Launchable? in
            let path = extensions + "/" + bundle
            guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any],
                  let attributes = info["EXAppExtensionAttributes"] as? [String: Any],
                  attributes["EXExtensionPointIdentifier"] as? String == "com.apple.Settings.extension.ui",
                  let id = info["CFBundleIdentifier"] as? String else { return nil }
            // The English names live in a loctable of locale → strings; some entries hold non-string values.
            let english = (NSDictionary(contentsOfFile: path + "/Contents/Resources/InfoPlist.loctable") as? [String: Any])?["en"] as? [String: Any]
            let name = paneNames[id] ?? english?["CFBundleDisplayName"] as? String ?? english?["CFBundleName"] as? String
                ?? info["CFBundleDisplayName"] as? String ?? bundle
            let iconName = (attributes["SettingsExtensionAttributes"] as? [String: Any])?["IconName"] as? String ?? "icon"
            let icon = path + "/Contents/Resources/\(iconName).icns"
            return Launchable(id: "settings:" + id, kind: .settings, title: name, subtitle: "System Settings",
                              target: URL(string: "x-apple.systempreferences:" + id)!,
                              iconPath: FileManager.default.fileExists(atPath: icon) ? icon : settingsApp,
                              phrases: [name] + (paneSynonyms[id] ?? []))
        }
    }

    /// Sections inside Privacy & Security. Anchors found in this Mac's Privacy extension, except the four marked,
    /// which are the widely documented names and are not stored as plain strings in the bundle.
    private static func privacySections() -> [Launchable] {
        let pane = "com.apple.settings.PrivacySecurity.extension"
        let sections: [(anchor: String, title: String, synonyms: [String])] = [
            ("Privacy_ScreenCapture", "Screen & System Audio Recording", ["screen recording", "screen capture", "screenshot permission"]),
            ("Privacy_AudioCapture", "System Audio Recording", ["audio recording"]),
            ("Privacy_Accessibility", "Accessibility Permission", ["accessibility access", "control computer"]),
            ("Privacy_AllFiles", "Full Disk Access", ["disk access"]),              // documented
            ("Privacy_ListenEvent", "Input Monitoring", ["keyboard monitoring"]),    // documented
            ("Privacy_Camera", "Camera", ["webcam"]),
            ("Privacy_Microphone", "Microphone", ["mic"]),
            ("Privacy_Automation", "Automation", ["apple events", "control other apps"]),
            ("Privacy_LocationServices", "Location Services", ["location"]),
            ("Privacy_FilesAndFolders", "Files & Folders", ["folder access"]),
            ("Privacy_Photos", "Photos", []),
            ("Privacy_Calendars", "Calendars", []),
            ("Privacy_Contacts", "Contacts", []),                                   // documented
            ("Privacy_Reminders", "Reminders", []),                                 // documented
            ("Privacy_DevTools", "Developer Tools", []),
            ("Privacy_Pasteboard", "Paste from Other Apps", ["clipboard", "pasteboard"]),
            ("Privacy_Analytics", "Analytics & Improvements", ["analytics"]),
            ("Privacy_Advertising", "Apple Advertising", ["ads"]),
        ]
        let icon = extensions + "/SecurityPrivacyExtension.appex/Contents/Resources/icon.icns"
        return sections.map { section in
            Launchable(id: "privacy:" + section.anchor, kind: .settings, title: section.title,
                       subtitle: "System Settings › Privacy & Security",
                       target: URL(string: "x-apple.systempreferences:\(pane)?\(section.anchor)")!,
                       iconPath: FileManager.default.fileExists(atPath: icon) ? icon : settingsApp,
                       phrases: [section.title] + section.synonyms, isPrivacySection: true)
        }
    }

    private static func places() -> [Launchable] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders: [(String, URL, [String])] = [
            ("Home", home, ["home folder"]),
            ("Desktop", home.appendingPathComponent("Desktop"), []),
            ("Documents", home.appendingPathComponent("Documents"), []),
            ("Downloads", home.appendingPathComponent("Downloads"), []),
            ("Pictures", home.appendingPathComponent("Pictures"), []),
            ("Movies", home.appendingPathComponent("Movies"), []),
            ("Music", home.appendingPathComponent("Music"), []),
            ("iCloud Drive", home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"), ["icloud"]),
            ("Applications", URL(fileURLWithPath: "/Applications"), []),
            ("Trash", home.appendingPathComponent(".Trash"), ["bin"]),
        ]
        return folders.filter { FileManager.default.fileExists(atPath: $0.1.path) }.map { title, url, synonyms in
            Launchable(id: "place:" + url.path, kind: .place, title: title, subtitle: "Folder in Finder", target: url,
                       iconPath: url.path, phrases: [title, title + " folder"] + synonyms)
        }
    }

    private static func apps() -> [Launchable] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", home + "/Applications",
                     "/System/Library/CoreServices/Applications"]
        var seen = Set<String>()
        var found: [Launchable] = []
        func add(_ path: String) {
            let title = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            guard seen.insert(title.lowercased()).inserted else { return }
            let folder = (path as NSString).deletingLastPathComponent
            found.append(Launchable(id: "app:" + path, kind: .app, title: title,
                                    subtitle: folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder,
                                    target: URL(fileURLWithPath: path), iconPath: path, phrases: [title]))
        }
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in names.sorted() {
                let path = root + "/" + name
                if name.hasSuffix(".app") {
                    add(path)
                } else if !name.hasPrefix("."), let inner = try? fm.contentsOfDirectory(atPath: path) {
                    // One level down: /Applications/Utilities, ~/Applications/Chrome Apps and the like.
                    for app in inner.sorted() where app.hasSuffix(".app") { add(path + "/" + app) }
                }
            }
        }
        return found
    }
}
