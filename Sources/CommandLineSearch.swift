import Foundation

/// The whole pipeline without the panel, for checking a search from the terminal.
enum CommandLineSearch {
    static func run(_ rawQuery: String, keywordsOnly: Bool, folder: URL?) {
        // Keep the main run loop turning while the search runs: AppleScript (Chrome tabs) has to run on the main thread.
        final class Flag: @unchecked Sendable { var done = false }
        let flag = Flag()
        Task.detached {
            await search(rawQuery, keywordsOnly: keywordsOnly, folder: folder)
            DispatchQueue.main.async { flag.done = true }
        }
        while !flag.done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
    }

    private static func milliseconds(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    private static func search(_ rawQuery: String, keywordsOnly: Bool, folder: URL?) async {
        Launcher.refresh()
        // Same order the panel uses: scopes narrow the sources, then apps, tabs, sessions, web.
        let (only, query) = Scope.read(rawQuery)
        func wants(_ scope: Scope) -> Bool { only.isEmpty || only.contains(scope) }
        if !only.isEmpty { print("scope    " + only.map { $0.label }.sorted().joined(separator: ", ")) }
        let catalog = Launcher.matches(query)
            .filter { match in only.isEmpty || only.contains { $0.kinds.contains(match.kind) } }
        let commands = Commands.analyze(query, scopes: only)
        var sessions: [Launchable] = []
        let asksForSession = query.lowercased().split(whereSeparator: { !$0.isLetter }).contains {
            ["session", "sessions", "transcript", "conversation", "earlier", "yesterday", "built", "worked"].contains(String($0))
        }
        if wants(.sessions), only.contains(.sessions) || asksForSession {
            sessions = Sessions.rows(for: query, limit: only.contains(.sessions) ? 8 : 2)
        }
        for item in commands.rows.filter({ $0.kind == .person || $0.kind == .hint }) + catalog + sessions
            + commands.rows.filter({ $0.kind != .person && $0.kind != .hint }) {
            print("row      [\(item.label)] \(item.title) · \(item.subtitle)")
        }
        if commands.isCommand || (!only.isEmpty && !only.contains(.files)) { return }

        let client = keywordsOnly ? nil : Prefs.client
        let useApple = !keywordsOnly && client == nil && AppleReader.isAvailable
        print("search   \(rawQuery)")
        print("reader   \(client.map { "Jev (\($0.model), key from \(Prefs.keySource))" } ?? (useApple ? "Apple Intelligence" : "word lists"))")

        var started = Date()
        var plan = QuickPlanner.plan(query)
        do {
            if let client { plan = try await JevPlanner.plan(query, client: client) }
            if useApple { plan = try await AppleReader.plan(query) }
        } catch {
            print("plan     reader failed, using word lists: \(error.localizedDescription)")
        }
        print("plan     \(milliseconds(since: started)) ms, read by \(plan.reader.rawValue)")
        print("         keywords \(plan.keywords)  related \(plan.related)  kind \(plan.kind.rawValue)  dates \(plan.datesLabel.isEmpty ? "-" : plan.datesLabel)"
            + "  place \(plan.place.rawValue)  size \(plan.hasSizeFilter ? plan.sizeLabel : "-")  order \(plan.order.rawValue)  intent \(plan.intent)")

        started = Date()
        let scopes = Retrieval.scopes(for: plan, folder: folder ?? (plan.place == .here ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath) : nil))
        let hits = Retrieval.fetch(plan, scopes: scopes, content: true, broaden: client != nil)
        print("spotlight \(hits.count) files in \(milliseconds(since: started)) ms, scope \(scopes.map { Format.tildePath(URL(fileURLWithPath: $0)) })")

        var ranked = QuickRank.rank(hits, plan: plan, folder: folder)
        if let client, !ranked.isEmpty {
            started = Date()
            do {
                let outcome = try await JevRank.rank(ranked.prefix(JevRank.limit).map(\.hit), plan: plan, client: client)
                ranked = outcome.ranked
                print("rank     Jev in \(milliseconds(since: started)) ms, \(outcome.tokens) input tokens, any match \(String(format: "%.2f", outcome.anyMatch))")
            } catch {
                print("rank     Jev failed, keeping keyword order: \(error.localizedDescription)")
            }
        }
        print("")
        for (index, item) in ranked.prefix(15).enumerated() {
            let match = item.match.map { String(format: "%.2f", $0) } ?? "  - "
            let date = item.hit.lastTouched.map(Format.day) ?? "          "
            print(String(format: "%2d  ", index + 1) + "\(match)  \(String(format: "%5.2f", item.score))  \(date)  \(item.best ? "★ " : "")\(Format.tildePath(item.hit.url))")
        }
        if ranked.isEmpty { print("no files found") }
    }
}
