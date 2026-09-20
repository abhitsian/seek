import AppKit
import CoreServices
import SQLite3

/// Requests that aren't file searches: chat, call or meet a person in Teams; open a site, a URL or a page
/// from browser history; search the web. Read from the words, so they show as you type.
enum Commands {
    // MARK: Reading the request

    enum PersonAction { case chat, call, videoCall, meet }

    private static let personVerbs: [String: PersonAction] = [
        "chat": .chat, "message": .chat, "msg": .chat, "ping": .chat, "text": .chat, "dm": .chat, "tell": .chat,
        "ask": .chat, "talk": .chat, "call": .call, "ring": .call, "phone": .call, "meet": .meet,
    ]
    /// Verbs that only mean "reach this person". Softer ones ("call", "tell", "meet") count only when the name is a real person,
    /// so "call notes" or "meet agenda" stay file searches.
    private static let explicitVerbs: Set<String> = ["chat", "talk", "message", "msg", "ping", "dm"]
    private static let nameSkips: Set<String> = ["with", "to", "a", "an", "the", "my", "up", "schedule", "set", "video"]
    private static let nameStops: Set<String> = ["about", "that", "saying", "re", "regarding", "on", "and", "for", "at",
                                                 "tomorrow", "today", "now", "later", "in", "please"]
    /// Verbs whose words after the name are worth pre-filling as the message.
    private static let messageVerbs: Set<String> = ["tell", "ask", "message", "text", "ping", "msg", "dm"]

    struct PersonRequest {
        let action: PersonAction
        let name: [String]
        let message: String?
        let explicit: Bool
    }

    static func personRequest(_ query: String) -> PersonRequest? {
        let words = Words.split(query).map(\.text)
        let lower = words.map { $0.lowercased() }
        guard let verbIndex = lower.firstIndex(where: { personVerbs[$0] != nil }) else { return nil }
        var action = personVerbs[lower[verbIndex]]!
        if action == .call, lower.contains("video") { action = .videoCall }
        var index = verbIndex + 1
        while index < lower.count, nameSkips.contains(lower[index]) || lower[index] == "call" { index += 1 }
        var name: [String] = []
        while index < lower.count, name.count < 2, !nameStops.contains(lower[index]), !Words.filler.contains(lower[index]) {
            name.append(words[index])
            index += 1
        }
        guard !name.isEmpty else { return nil }
        var rest = Array(words[index...])
        if let first = rest.first?.lowercased(), ["saying", "that", ":"].contains(first) { rest.removeFirst() }
        let message = messageVerbs.contains(lower[verbIndex]) && !rest.isEmpty ? rest.joined(separator: " ") : nil
        // Explicit only as the first word, and "chat"/"talk" only as "chat with X": "chat history export" stays a file search.
        let verb = lower[verbIndex]
        let explicit = explicitVerbs.contains(verb) && verbIndex <= 1
            && (!["chat", "talk"].contains(verb) || (verbIndex + 1 < lower.count && ["with", "to"].contains(lower[verbIndex + 1])))
        return PersonRequest(action: action, name: name, message: message, explicit: explicit)
    }

    private static let searchVerbs: [[String]] = [["google"], ["search", "google", "for"], ["search", "the", "web", "for"],
                                                  ["search", "web", "for"], ["search", "online", "for"], ["look", "up"],
                                                  ["web", "search"], ["search", "for"], ["search"]]

    /// "google swift regex", "look up lisbon weather", "youtube lofi"
    static func webSearch(_ query: String) -> (engine: String, terms: String)? {
        let words = Words.split(query).map(\.text)
        let lower = words.map { $0.lowercased() }
        if lower.first == "youtube" || (lower.starts(with: ["search", "youtube", "for"])) {
            let skip = lower.first == "youtube" ? 1 : 3
            return words.count > skip ? ("YouTube", words[skip...].joined(separator: " ")) : nil
        }
        for pattern in searchVerbs where lower.starts(with: pattern) && words.count > pattern.count {
            // Plain "search X" stays a file search; only the web phrasings go to the browser.
            if pattern == ["search"] || pattern == ["search", "for"] { continue }
            return ("Google", words[pattern.count...].joined(separator: " "))
        }
        return nil
    }

    /// Rows for the "Apps & actions" section, and whether the search is a command rather than a file search
    /// (then Seek skips the file search). Runs Spotlight and SQLite, so call it off the main thread.
    static func analyze(_ query: String) -> (rows: [Launchable], isCommand: Bool) {
        var rows: [Launchable] = [] // people, URLs and web searches; sites and history pages go after the app matches
        var isCommand = false
        let person = personRequest(query)
        if let person {
            let found = personRows(person)
            if !found.isEmpty, found.first?.kind == .person || person.explicit {
                rows += found
                isCommand = true
            }
        }
        if let url = typedURL(query) {
            rows.append(web("Open \(url.host ?? url.absoluteString)", url.absoluteString, url: url))
            isCommand = true
        }
        let search = webSearch(query)
        if let search {
            let base = search.engine == "YouTube" ? "https://www.youtube.com/results?search_query=" : "https://www.google.com/search?q="
            let encoded = search.terms.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? search.terms
            if let url = URL(string: base + encoded) {
                rows.append(web("Search \(search.engine) for “\(search.terms)”", "Opens in your browser", url: url))
                isCommand = true
            }
        }
        // Open tabs: "figma tab", "switch to jira", "tabs" lists them all.
        let tabs: (rows: [Launchable], isCommand: Bool) = isCommand ? ([], false) : ChromeTabs.rows(for: query)
        if tabs.isCommand { return (tabs.rows, true) }
        rows += tabs.rows
        rows += siteRows(query)
        // "show … in Finder" is about files; a web page can't be shown in Finder.
        if !isCommand, Intent.detect(Words.split(query)) != .reveal {
            // A page that is already open shows once, as its tab.
            let open = Set(tabs.rows.map(\.target.absoluteString))
            rows += BrowserHistory.rows(for: query).filter { !open.contains($0.target.absoluteString) }
        }
        return (rows, isCommand)
    }

    private static func web(_ title: String, _ subtitle: String, url: URL) -> Launchable {
        Launchable(id: "web:" + url.absoluteString, kind: .web, title: title, subtitle: subtitle, target: url,
                   iconPath: browserPath, phrases: [])
    }

    static var browserPath: String {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.path ?? "/Applications/Safari.app"
    }

    /// "github.com/foo", "https://…", "notion.so"
    static func typedURL(_ query: String) -> URL? {
        let text = query.trimmingCharacters(in: .whitespaces)
        let candidate = text.lowercased().hasPrefix("open ") ? String(text.dropFirst(5)) : text
        guard !candidate.contains(" "),
              let match = candidate.lowercased().firstMatch(of: #/^(?:https?://)?(?:[a-z0-9-]+\.)+([a-z]{2,})(?:[/?#]\S*)?$/#),
              domains.contains(String(match.1)) || candidate.lowercased().hasPrefix("http")
        else { return nil }
        return URL(string: candidate.lowercased().hasPrefix("http") ? candidate : "https://" + candidate)
    }

    /// Endings that mean a web address rather than a file name like "report.final".
    private static let domains: Set<String> = ["com", "org", "net", "io", "ai", "so", "dev", "app", "co", "in", "me", "gov",
                                               "edu", "uk", "us", "ly", "gg", "tv", "xyz", "info", "cloud", "tech", "site",
                                               "page", "fm", "to", "sh", "it", "de", "fr", "jp", "ca", "au", "eu", "news"]

    private static let sites: [(names: [String], title: String, url: String)] = [
        (["gmail"], "Gmail", "https://mail.google.com"),
        (["google calendar", "gcal"], "Google Calendar", "https://calendar.google.com"),
        (["google drive", "drive"], "Google Drive", "https://drive.google.com"),
        (["google docs"], "Google Docs", "https://docs.google.com"),
        (["youtube"], "YouTube", "https://www.youtube.com"),
        (["github"], "GitHub", "https://github.com"),
        (["linkedin"], "LinkedIn", "https://www.linkedin.com"),
        (["notion"], "Notion", "https://www.notion.so"),
        (["figma"], "Figma", "https://www.figma.com"),
        (["chatgpt"], "ChatGPT", "https://chatgpt.com"),
        (["claude.ai", "claude web"], "Claude", "https://claude.ai"),
        (["outlook web", "outlook online"], "Outlook on the web", "https://outlook.office.com"),
        (["teams web"], "Teams on the web", "https://teams.microsoft.com"),
    ]

    /// Well-known sites by name: "gmail", "open github".
    private static func siteRows(_ query: String) -> [Launchable] {
        let lower = Words.split(query).map { $0.text.lowercased() }.filter { !["open", "go", "to", "the", "my", "website", "site"].contains($0) }
        let spoken = lower.joined(separator: " ")
        guard !spoken.isEmpty else { return [] }
        return sites.filter { $0.names.contains(spoken) }.map {
            web($0.title, $0.url.replacingOccurrences(of: "https://", with: ""), url: URL(string: $0.url)!)
        }
    }

    // MARK: People

    private static let teamsPath = "/Applications/Microsoft Teams.app"

    private static func personRows(_ request: PersonRequest) -> [Launchable] {
        let candidates = People.find(request.name.joined(separator: " "))
            + (request.name.count > 1 ? People.find(request.name[0]) : [])
        var seen = Set<String>()
        let people = candidates.filter { seen.insert($0.email.lowercased()).inserted }.prefix(3)
        guard !people.isEmpty else {
            let name = request.name.joined(separator: " ")
            return [Launchable(id: "hint:person:" + name, kind: .hint, title: "Add \(name.capitalized)'s email to chat in Teams",
                               subtitle: "No one called \(name) in your People list or documents · opens Seek Settings",
                               target: URL(string: "seek://settings")!, iconPath: teamsPath, phrases: [])]
        }
        return people.compactMap { person in
            let users = person.email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? person.email
            var link: String
            var title: String
            switch request.action {
            case .chat:
                link = "msteams:/l/chat/0/0?users=\(users)"
                if let message = request.message?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                    link += "&message=\(message)"
                }
                title = "Chat with \(person.name)"
            case .call:
                link = "msteams:/l/call/0/0?users=\(users)"
                title = "Call \(person.name)"
            case .videoCall:
                link = "msteams:/l/call/0/0?users=\(users)&withVideo=true"
                title = "Video call \(person.name)"
            case .meet:
                link = "msteams:/l/meeting/new?attendees=\(users)"
                title = "New meeting with \(person.name)"
            }
            guard let url = URL(string: link) else { return nil }
            let note = person.guessed ? " · guessed address" : ""
            let subtitle = "Microsoft Teams · \(person.email)\(note)" + (request.message.map { " · “\($0)”" } ?? "")
            return Launchable(id: "person:\(request.action):\(person.email)", kind: .person, title: title, subtitle: subtitle,
                              target: url, iconPath: teamsPath, phrases: [])
        }
    }
}

/// People Seek can reach in Teams. Your People list in Settings comes first; after that, names Spotlight knows
/// as document authors, with the email guessed as first.last@ your work domain.
enum People {
    struct Person {
        let name: String
        let email: String
        let guessed: Bool
    }

    static var fileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Seek")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("people.txt")
    }

    /// Lines like `Alex Kim <alex.kim@example.com>, alex, ak`. Lines starting with # are notes.
    static var listed: [(name: String, email: String, aliases: [String])] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let open = line.firstIndex(of: "<"), let close = line.firstIndex(of: ">"), open < close else { return nil }
            let name = line[..<open].trimmingCharacters(in: .whitespaces)
            let email = line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            let aliases = line[line.index(after: close)...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            return email.contains("@") ? (name, email, aliases) : nil
        }
    }

    /// The domain for guessed addresses: the setting, else the most common domain in the People list.
    /// Empty means Seek never guesses an address, and an unlisted name asks you to add one.
    static var workDomain: String {
        if let domain = UserDefaults.standard.string(forKey: "workDomain"), !domain.isEmpty { return domain }
        let domains = listed.compactMap { $0.email.split(separator: "@").last.map(String.init) }
        return Dictionary(grouping: domains, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? ""
    }

    static func find(_ name: String) -> [Person] {
        let wanted = name.lowercased().split(separator: " ").map(String.init)
        guard !wanted.isEmpty else { return [] }
        func matches(_ full: String) -> Bool {
            let parts = full.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            return wanted.allSatisfy { word in parts.contains { $0.hasPrefix(word) } }
        }
        let fromList = listed.filter { matches($0.name) || $0.aliases.contains(name.lowercased()) }
            .map { Person(name: $0.name, email: $0.email, guessed: false) }
        if !fromList.isEmpty { return fromList }
        return authors(matching: wanted[0]).filter { matches($0.name) }.prefix(3).compactMap { author in
            if let email = author.email { return Person(name: author.name, email: email, guessed: false) }
            let parts = author.name.folding(options: .diacriticInsensitive, locale: .current).lowercased()
                .split(whereSeparator: { !$0.isLetter }).map(String.init)
            let domain = workDomain
            guard parts.count >= 2, !domain.isEmpty else { return nil }
            return Person(name: author.name, email: "\(parts.first!).\(parts.last!)@\(domain)", guessed: true)
        }
    }

    /// Full names from the Authors field of documents on this Mac, most frequent first.
    private static func authors(matching word: String) -> [(name: String, email: String?)] {
        let escaped = Spotlight.escape(word)
        let attributes = [kMDItemAuthors, kMDItemAuthorEmailAddresses] as CFArray
        guard let query = MDQueryCreate(kCFAllocatorDefault, "kMDItemAuthors == \"*\(escaped)*\"cd" as CFString, attributes, nil) else { return [] }
        MDQuerySetSearchScope(query, [NSHomeDirectory()] as CFArray, 0)
        MDQuerySetMaxCount(query, 300)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var counts: [String: Int] = [:]
        var emails: [String: String] = [:]
        for index in 0..<MDQueryGetResultCount(query) {
            func value<T>(_ attribute: CFString) -> T? {
                guard let raw = MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index) else { return nil }
                return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? T
            }
            let names: [String] = value(kMDItemAuthors) ?? []
            let addresses: [String] = value(kMDItemAuthorEmailAddresses) ?? []
            for (position, name) in names.enumerated() where name.lowercased().contains(word.lowercased()) && name.contains(" ") {
                counts[name, default: 0] += 1
                if addresses.count == names.count { emails[name] = addresses[position] }
            }
        }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, emails[$0.key]) }
    }
}

/// Pages from Chrome's history and bookmarks, matched by title. Chrome keeps History locked,
/// so Seek reads a copy it refreshes at most every ten minutes. Nothing leaves the Mac.
enum BrowserHistory {
    private static let chrome = NSHomeDirectory() + "/Library/Application Support/Google/Chrome"
    private static var cues: Set<String> {
        // "channel", "figma", "page": the words that name something a recipe can open in its own app.
        Set(["site", "page", "tab", "link", "website", "web", "doc", "docs", "sheet", "dashboard", "browser",
             "url", "chrome", "wiki", "ticket", "board"]).union(Recipes.entityWords)
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var copiedAt = Date.distantPast

    private static var profiles: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: chrome)) ?? []
        return names.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.map { chrome + "/" + $0 }
    }

    private static func copyPath(_ profile: String) -> String {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "Seek")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("history-\((profile as NSString).lastPathComponent).sqlite").path
    }

    static func refreshIfStale() {
        let stale = lock.withLock { Date().timeIntervalSince(copiedAt) > 600 }
        guard stale else { return }
        for profile in profiles where FileManager.default.fileExists(atPath: profile + "/History") {
            let copy = copyPath(profile)
            try? FileManager.default.removeItem(atPath: copy)
            try? FileManager.default.copyItem(atPath: profile + "/History", toPath: copy)
        }
        lock.withLock { copiedAt = Date() }
    }

    static func rows(for query: String, limit: Int = 3) -> [Launchable] {
        let lower = Words.split(query).map { $0.text.lowercased() }
        let core = lower.filter { !Words.filler.contains($0) && !cues.contains($0) && $0.count > 1 }
        let wantsWeb = lower.contains(where: cues.contains) || lower.contains("open")
        guard !core.isEmpty, core.count >= 2 || wantsWeb else { return [] }
        refreshIfStale()
        var pages: [(title: String, url: String, score: Double)] = []
        for profile in profiles {
            pages += bookmarks(profile, core)
            pages += history(copyPath(profile), core)
        }
        var seen = Set<String>()
        return pages.sorted { $0.score > $1.score }
            .filter { seen.insert($0.title.lowercased()).inserted }
            .prefix(limit)
            .compactMap { page in
                guard let url = URL(string: page.url) else { return nil }
                // A page whose app is on this Mac opens there instead of in a tab.
                if let (recipe, link) = Recipes.rewrite(page.url) {
                    return Launchable(id: "deeplink:\(recipe.bundle)|\(page.url)", kind: .deeplink, title: page.title,
                                      subtitle: "Opens in \(recipe.app) · \(url.host ?? "") · from your browser history",
                                      target: link, iconPath: Recipes.appPath(recipe.bundle) ?? Commands.browserPath,
                                      phrases: [], badge: recipe.app)
                }
                return Launchable(id: "page:" + page.url, kind: .web, title: page.title,
                                  subtitle: (url.host ?? "") + " · from your browser history",
                                  target: url, iconPath: Commands.browserPath, phrases: [])
            }
    }

    private static func history(_ path: String, _ words: [String]) -> [(title: String, url: String, score: Double)] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        let conditions = words.map { _ in "title LIKE ?" }.joined(separator: " AND ")
        let sql = "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 AND \(conditions) "
            + "AND url NOT LIKE '%google.com/search%' AND url NOT LIKE 'file:%' ORDER BY visit_count DESC, last_visit_time DESC LIMIT 20"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, word) in words.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), "%\(word)%", -1, transient) }
        var rows: [(String, String, Double)] = []
        let now = Date().timeIntervalSince1970
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let url = sqlite3_column_text(statement, 0), let title = sqlite3_column_text(statement, 1) else { continue }
            let visits = Double(sqlite3_column_int64(statement, 2))
            // Chrome counts microseconds since 1601.
            let visited = Double(sqlite3_column_int64(statement, 3)) / 1_000_000 - 11_644_473_600
            let days = max(0, (now - visited) / 86_400)
            rows.append((String(cString: title), String(cString: url), log(1 + visits) + 2 * exp(-days / 30)))
        }
        return rows
    }

    private static func bookmarks(_ profile: String, _ words: [String]) -> [(title: String, url: String, score: Double)] {
        guard let data = FileManager.default.contents(atPath: profile + "/Bookmarks"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { return [] }
        var found: [(String, String, Double)] = []
        func walk(_ node: [String: Any]) {
            if node["type"] as? String == "url", let name = node["name"] as? String, let url = node["url"] as? String,
               words.allSatisfy({ name.lowercased().contains($0) }) {
                found.append((name, url, 5)) // a bookmark beats most history
            }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        for case let root as [String: Any] in roots.values { walk(root) }
        return found
    }
}
