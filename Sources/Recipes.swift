import AppKit

/// How to open a page in the app that owns it, rather than in the browser.
///
/// The hard part of deep linking is never the scheme, which every app declares, but the ids inside it.
/// Those already exist in your browser history: a Slack channel, a Figma file or a Notion page you
/// have opened carries its own id in the URL. A recipe reads that id back out and rewrites the address
/// for the desktop app. When no recipe matches, or the app is not installed, the web address still works,
/// so a missing recipe costs nothing.
struct Recipe: Codable {
    let app: String
    let bundle: String
    /// What the thing is called, and what you would say to ask for it.
    let entity: String
    /// A regular expression over the address, with named groups the template fills in.
    let match: String
    /// The desktop link, with {group} placeholders.
    let open: String
    var words: [String] = []
}

enum Recipes {
    /// Shipped recipes, merged with anything in ~/Library/Application Support/Seek/recipes.json,
    /// so adding an app is a file, not a build.
    static let shipped: [Recipe] = [
        Recipe(app: "Slack", bundle: "com.tinyspeck.slackmacgap", entity: "channel",
               match: #"app\.slack\.com/client/(?<team>T[A-Z0-9]+)/(?<id>[CDG][A-Z0-9]+)"#,
               open: "slack://channel?team={team}&id={id}", words: ["channel", "dm", "slack"]),
        Recipe(app: "Microsoft Teams", bundle: "com.microsoft.teams2", entity: "chat",
               match: #"teams\.microsoft\.com/l/(?<rest>\S+)"#,
               open: "msteams:/l/{rest}", words: ["chat", "teams", "meeting"]),
        Recipe(app: "Figma", bundle: "com.figma.Desktop", entity: "file",
               match: #"figma\.com/(?:file|design|board)/(?<key>[A-Za-z0-9]+)"#,
               open: "figma://file/{key}", words: ["figma", "design", "board", "mock"]),
        Recipe(app: "Notion", bundle: "notion.id", entity: "page",
               match: #"(?<host>(?:www\.|app\.)?notion\.(?:so|com))/(?<path>[^\s"']+)"#,
               open: "notion://{host}/{path}", words: ["notion", "page", "doc", "database"]),
        Recipe(app: "Zoom", bundle: "us.zoom.xos", entity: "meeting",
               match: #"zoom\.us/j/(?<id>\d+)"#,
               open: "zoommtg://zoom.us/join?confno={id}", words: ["zoom", "meeting", "call"]),
        Recipe(app: "Spotify", bundle: "com.spotify.client", entity: "track",
               match: #"open\.spotify\.com/(?<type>track|album|playlist|artist)/(?<id>[A-Za-z0-9]+)"#,
               open: "spotify:{type}:{id}", words: ["spotify", "track", "album", "playlist", "song"]),
    ]

    static var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Seek")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("recipes.json")
    }

    static var all: [Recipe] {
        guard let data = try? Data(contentsOf: file),
              let extra = try? JSONDecoder().decode([Recipe].self, from: data) else { return shipped }
        let added = Set(extra.map(\.match))
        return extra + shipped.filter { !added.contains($0.match) }
    }

    /// The desktop link for an address, when a recipe matches and the app is on this Mac.
    static func rewrite(_ address: String) -> (recipe: Recipe, link: URL)? {
        for recipe in all where installed(recipe.bundle) {
            guard let expression = try? NSRegularExpression(pattern: recipe.match, options: [.caseInsensitive]),
                  let hit = expression.firstMatch(in: address, range: NSRange(address.startIndex..., in: address))
            else { continue }
            var link = recipe.open
            for name in groupNames(recipe.match) {
                let range = hit.range(withName: name)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: address) else { continue }
                link = link.replacingOccurrences(of: "{\(name)}", with: String(address[swiftRange]))
            }
            guard !link.contains("{"), let url = URL(string: link) else { continue }
            return (recipe, url)
        }
        return nil
    }

    private static func groupNames(_ pattern: String) -> [String] {
        guard let finder = try? NSRegularExpression(pattern: #"\(\?<([A-Za-z][A-Za-z0-9]*)>"#) else { return [] }
        return finder.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)).compactMap {
            Range($0.range(at: 1), in: pattern).map { String(pattern[$0]) }
        }
    }

    static func installed(_ bundle: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil
    }

    static func appPath(_ bundle: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?.path
    }

    /// Words that name a kind of thing a recipe can open ("channel", "figma", "page").
    static var entityWords: Set<String> {
        Set(all.flatMap { $0.words + [$0.entity, $0.app.lowercased()] }.map { $0.lowercased() })
    }

    /// Derives a recipe from one example address, so an app Seek has never seen takes one paste to learn.
    ///
    /// Segments that look like identifiers become named groups, and the scheme comes from the app's own
    /// Info.plist. The result is a starting point, not a certainty: the fallback in `open` catches a
    /// template the app refuses, and you can edit recipes.json by hand.
    static func teach(app name: String, example address: String) -> Recipe? {
        // A recipe that already handles this address knows the app's real grammar; a derived one would only
        // guess at it, so teaching fills gaps rather than overwriting what works.
        if let existing = rewrite(address) {
            print("\(existing.recipe.app) already handles that address: \(existing.link.absoluteString)")
            return nil
        }
        let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        let path = roots.map { "\($0)/\(name).app" }.first { FileManager.default.fileExists(atPath: $0) }
        guard let path,
              let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any],
              let bundle = info["CFBundleIdentifier"] as? String,
              let types = info["CFBundleURLTypes"] as? [[String: Any]],
              let scheme = types.compactMap({ ($0["CFBundleURLSchemes"] as? [String])?.first })
                  .first(where: { !$0.hasPrefix("com.") && $0.count > 2 }),
              let url = URL(string: address), let host = url.host
        else { return nil }
        var pattern = NSRegularExpression.escapedPattern(for: host)
        var template = "\(scheme)://\(host)"
        var index = 0
        for segment in url.path.split(separator: "/") {
            let text = String(segment)
            // An identifier: long, mixed, and not a word you would type.
            let looksLikeID = text.count >= 8 && text.rangeOfCharacter(from: .decimalDigits) != nil
                && text.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "-_"))) == nil
            if looksLikeID {
                index += 1
                pattern += "/(?<id\(index)>[A-Za-z0-9_-]+)"
                template += "/{id\(index)}"
            } else {
                pattern += "/" + NSRegularExpression.escapedPattern(for: text)
                template += "/" + text
            }
        }
        guard index > 0 else { return nil }  // nothing to fill in means nothing to learn
        return Recipe(app: name, bundle: bundle, entity: "item", match: pattern, open: template,
                      words: [name.lowercased()])
    }

    static func remember(_ recipe: Recipe) {
        var recipes = (try? JSONDecoder().decode([Recipe].self, from: Data(contentsOf: file))) ?? []
        recipes.removeAll { $0.match == recipe.match }
        recipes.append(recipe)
        if let data = try? JSONEncoder().encode(recipes) { try? data.write(to: file) }
    }

    /// Opens a desktop link and falls back to the web address when the app does not take it.
    ///
    /// A rewritten link is a guess about another app's grammar, so it is checked rather than trusted:
    /// if that app is not frontmost shortly after, the browser gets the original address.
    static func open(_ link: URL, bundle: String, fallback: URL?) {
        NSWorkspace.shared.open(link)
        guard let fallback else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if front != bundle {
                NSWorkspace.shared.open(fallback)
                note(failure: bundle)
            }
        }
    }

    /// Recipes that keep missing are worth knowing about; the count lands next to the recipes themselves.
    private static func note(failure bundle: String) {
        let path = file.deletingLastPathComponent().appendingPathComponent("recipe-misses.json")
        let stored = (try? Data(contentsOf: path)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        var counts = (stored as? [String: Int]) ?? [:]
        counts[bundle, default: 0] += 1
        if let data = try? JSONSerialization.data(withJSONObject: counts, options: [.prettyPrinted]) {
            try? data.write(to: path)
        }
    }
}
