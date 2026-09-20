import CoreServices
import Foundation

/// One file Spotlight found, with the metadata Seek shows and ranks on.
struct FileHit: Identifiable, Hashable {
    let url: URL
    let kind: String
    let contentType: String
    let modified: Date?
    let lastUsed: Date?
    let added: Date?
    let size: Int64?
    let source: String?
    let title: String?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var isFolder: Bool { contentType == "public.folder" }
    var lastTouched: Date? { [modified, lastUsed, added].compactMap { $0 }.max() }
}

enum Spotlight {
    /// Attributes Spotlight returns with each result, in bulk. Reading them one call at a time is far slower.
    /// kMDItemPath is never returned this way, so the path comes from the item itself.
    private static let attributes: [CFString] = [
        kMDItemKind, kMDItemContentType, kMDItemFSContentChangeDate, kMDItemLastUsedDate,
        kMDItemDateAdded, kMDItemFSSize, kMDItemWhereFroms, kMDItemTitle,
    ]

    /// Runs a Spotlight query synchronously. Call it off the main thread.
    static func query(_ predicate: String, in scopes: [String], limit: Int = 4000) -> [FileHit] {
        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate as CFString, attributes as CFArray, nil) else { return [] }
        MDQuerySetSearchScope(query, scopes as CFArray, 0)
        MDQuerySetMaxCount(query, limit)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var hits: [FileHit] = []
        for index in 0..<MDQueryGetResultCount(query) {
            func value<T>(_ attribute: CFString) -> T? {
                guard let raw = MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index) else { return nil }
                return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? T
            }
            guard let raw = MDQueryGetResultAtIndex(query, index),
                  let path = MDItemCopyAttribute(Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue(), kMDItemPath) as? String,
                  !Noise.contains(path) else { continue }
            let sources: [String]? = value(kMDItemWhereFroms)
            let title: String? = value(kMDItemTitle)
            hits.append(FileHit(
                url: URL(fileURLWithPath: path),
                kind: value(kMDItemKind) ?? "",
                contentType: value(kMDItemContentType) ?? "",
                modified: value(kMDItemFSContentChangeDate),
                lastUsed: value(kMDItemLastUsedDate),
                added: value(kMDItemDateAdded),
                size: (value(kMDItemFSSize) as NSNumber?)?.int64Value,
                source: sources.flatMap(Format.host),
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return hits
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*")
    }

    /// Matches a word in the file name, its title, where it was downloaded from, and optionally its text.
    static func keywordClause(_ word: String, content: Bool) -> String {
        let text = escape(word)
        var parts = ["kMDItemFSName == \"*\(text)*\"cd", "kMDItemTitle == \"*\(text)*\"cd", "kMDItemWhereFroms == \"*\(text)*\"cd"]
        if content { parts += ["kMDItemTextContent == \"\(text)*\"cdw", "kMDItemAuthors == \"*\(text)*\"cd"] }
        return "(" + parts.joined(separator: " || ") + ")"
    }

    /// Files changed, opened or added inside the range.
    static func dateClause(_ range: DateInterval,
                           attributes: [String] = ["kMDItemFSContentChangeDate", "kMDItemLastUsedDate", "kMDItemDateAdded"]) -> String {
        let start = Format.spotlightTime(range.start), end = Format.spotlightTime(range.end)
        return "(" + attributes.map {
            "(\($0) >= $time.iso(\(start)) && \($0) < $time.iso(\(end)))"
        }.joined(separator: " || ") + ")"
    }

    static let everything = "(kMDItemFSName == \"*\")"
}

/// Pulls candidates for a plan out of Spotlight, loosening the search until there are enough to rank.
enum Retrieval {
    /// Where people keep their own files, as opposed to app data and code checkouts.
    static let userFolders: [String] = {
        let home = NSHomeDirectory()
        return ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
                "Library/Mobile Documents/com~apple~CloudDocs", "Library/CloudStorage"]
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }()

    static func scopes(for plan: Plan, folder: URL?) -> [String] {
        if let folder { return [folder.path] }
        if let url = plan.place.url { return [url.path] }
        var scopes = [NSHomeDirectory()]
        if plan.kind == .app { scopes += ["/Applications", "/System/Applications"] }
        return scopes
    }

    /// - Parameters:
    ///   - content: also match words inside files. Slower, so the instant pass skips it.
    ///   - broaden: when little matches, fall back to the filters alone and let Jev judge by metadata.
    static func fetch(_ plan: Plan, scopes: [String], content: Bool, broaden: Bool) -> [FileHit] {
        var found: [String: FileHit] = [:]
        func run(_ clauses: [String], in scopes: [String], limit: Int = 4000) {
            let predicate = clauses.isEmpty ? Spotlight.everything : clauses.joined(separator: " && ")
            for hit in Spotlight.query(predicate, in: scopes, limit: limit) where found[hit.id] == nil {
                found[hit.id] = hit
            }
        }
        let filters = plan.filterClauses
        let keywords = plan.keywords
        let scoped = plan.place != .anywhere || scopes != [NSHomeDirectory()]

        guard !keywords.isEmpty else {
            if let dates = plan.dates, plan.kind == .any, !scoped {
                // A date alone: about 48,000 files in a home folder change in ten days (apps, caches, builds),
                // but only a hundred or so are opened. Opened files first, then changes in the user's own folders.
                let others = filters.filter { $0 != Spotlight.dateClause(dates) }
                run(others + [Spotlight.dateClause(dates, attributes: ["kMDItemLastUsedDate"])], in: scopes, limit: 1500)
                if found.count < 30 { run(filters, in: Retrieval.userFolders, limit: 1500) }
            } else if !filters.isEmpty || scoped {
                // Filters alone can match thousands of files; 1,500 are plenty to sort.
                run(filters, in: scopes, limit: 1500)
            }
            return Array(found.values)
        }
        // Names first: few hits, and the ones people usually mean. Then words inside files, capped,
        // because a common word matches thousands of files and copying their metadata dominates the time.
        run(filters + keywords.map { Spotlight.keywordClause($0, content: false) }, in: scopes)
        if !plan.related.isEmpty {
            // Other words for the subject, as whole words in names: "invoice" also finds bill.pdf, "rental" skips Parental.
            let related = "(" + plan.related.map {
                let word = Spotlight.escape($0)
                return "kMDItemFSName == \"\(word)*\"cdw || kMDItemTitle == \"\(word)*\"cdw"
            }.joined(separator: " || ") + ")"
            run(filters + [related], in: scopes, limit: 400)
        }
        if content {
            run(filters + keywords.map { "kMDItemTextContent == \"\(Spotlight.escape($0))*\"cdw" }, in: scopes, limit: 500)
        }
        if found.count < 20, keywords.count > 1 {
            let any = "(" + keywords.map { Spotlight.keywordClause($0, content: content) }.joined(separator: " || ") + ")"
            run(filters + [any], in: scopes, limit: 800)
        }
        if found.count < 20, plan.kind != .folder {
            // Folders named after the search: "photos from the goa trip" lives in a folder called Goa Trip.
            let names = keywords.map { "kMDItemFSName == \"*\(Spotlight.escape($0))*\"cd" }.joined(separator: " || ")
            let folders = Spotlight.query("(kMDItemContentType == \"public.folder\") && (\(names))", in: scopes, limit: 60)
                .sorted { $0.url.pathComponents.count < $1.url.pathComponents.count }
                .prefix(6).map(\.url.path)
            if !folders.isEmpty { run(filters, in: Array(folders), limit: 600) }
        }
        if broaden, found.count < 12, !filters.isEmpty || scoped {
            run(filters, in: scopes, limit: 1500)
        }
        return Array(found.values)
    }
}

/// Paths nobody means when they search for a file: app internals, caches, dependencies, hidden folders.
enum Noise {
    private static let home = NSHomeDirectory()
    private static let keptLibrary = ["/Library/Mobile Documents/", "/Library/CloudStorage/"]
    private static let folders: Set<String> = [
        "node_modules", "__pycache__", "site-packages", "DerivedData", "Pods", "venv", "bower_components", "Caches",
    ]
    private static let packages = [".app", ".bundle", ".framework", ".photoslibrary", ".xcodeproj", ".xcworkspace",
                                    ".imovielibrary", ".musiclibrary", ".tvlibrary", ".plugin", ".kext", ".lproj"]

    /// File types that are rarely what a person searches for, unless they asked for code.
    static let machineExtensions: Set<String> = [
        "log", "jsonl", "json", "js", "mjs", "ts", "css", "map", "lock", "plist", "xml", "yml", "yaml", "sqlite",
        "db", "br", "gz", "pyc", "swift", "py", "sh", "h", "m", "c", "cpp", "o", "tsx", "jsx", "html", "toml", "ini", "cfg",
    ]

    static func contains(_ path: String) -> Bool {
        let relative = path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path
        if relative.hasPrefix("/Library/"), !keptLibrary.contains(where: relative.hasPrefix) { return true }
        if relative.hasPrefix("/.Trash") { return true }
        if (relative as NSString).lastPathComponent.hasPrefix("~$") { return true } // Office lock files
        let parts = relative.split(separator: "/")
        for (index, part) in parts.enumerated() {
            if part.hasPrefix(".") || folders.contains(String(part)) { return true }
            if index < parts.count - 1, packages.contains(where: { part.hasSuffix($0) }) { return true }
        }
        return false
    }
}
