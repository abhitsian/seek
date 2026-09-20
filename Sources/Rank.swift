import Foundation

/// A file in the results list, with its place in the ranking.
struct Ranked: Identifiable, Equatable {
    let hit: FileHit
    var score: Double
    /// Jev's probability that this file fits the search. Nil when Jev did not rank the list.
    var match: Double?
    var best = false

    var id: String { hit.id }
}

/// Ranks by where the words matched and how recently the file was touched. Used before Jev answers,
/// to pick the shortlist Jev reads, and as the whole ranking when there is no key.
enum QuickRank {
    static func score(_ hit: FileHit, plan: Plan, folder: URL?, now: Date) -> Double {
        let name = hit.name.lowercased()
        let parent = hit.url.deletingLastPathComponent().path.lowercased()
        let extras = ((hit.title ?? "") + " " + (hit.source ?? "")).lowercased()
        var score = 0.0
        let tokens = Self.tokens(of: hit.url.deletingPathExtension().lastPathComponent)
        for keyword in plan.keywords.map({ $0.lowercased() }) {
            let parts = keyword.split(separator: " ").map(String.init)
            if parts.allSatisfy({ part in tokens.contains { $0 == part || $0 == part + "s" || $0 == part + "es" } }) {
                score += 4 // the whole word, or its plural
            } else if parts.allSatisfy({ part in tokens.contains { $0.hasPrefix(part) } }) {
                score += 2.5
            } else if name.contains(keyword) {
                score += 1.5
            } else if parent.contains(keyword) {
                score += 2
            } else if extras.contains(keyword) {
                score += 1.5
            } else {
                score += 0.6 // matched inside the file
            }
        }
        if plan.related.contains(where: { word in tokens.contains { $0.hasPrefix(word.lowercased()) } }) { score += 2 }
        if let touched = hit.lastTouched {
            let days = max(0, now.timeIntervalSince(touched) / 86_400)
            score += 2 * exp(-days / 45)
        }
        if plan.kind != .code, Noise.machineExtensions.contains(hit.url.pathExtension.lowercased()) { score -= 2.5 }
        if let folder, hit.url.path.hasPrefix(folder.path + "/") { score += 1 }
        let home = NSHomeDirectory()
        if ["/Desktop/", "/Documents/", "/Downloads/", "/Library/Mobile Documents/"].contains(where: { hit.url.path.hasPrefix(home + $0) }) {
            score += 0.4
        }
        return score
    }

    /// "Income-Tax_2026 v2" → ["income", "tax", "2026", "v2"]; camelCase splits too.
    static func tokens(of name: String) -> [String] {
        let spaced = name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func rank(_ hits: [FileHit], plan: Plan, folder: URL? = nil, now: Date = Date()) -> [Ranked] {
        let ranked = hits.map { Ranked(hit: $0, score: score($0, plan: plan, folder: folder, now: now)) }
        return order(ranked, by: plan.order) { $0.score > $1.score }
    }

    /// Sorts by the order the search asked for; ties and "best match" fall back to `better`.
    static func order(_ items: [Ranked], by order: Order, better: (Ranked, Ranked) -> Bool) -> [Ranked] {
        let distant = Date.distantPast
        switch order {
        case .best: return items.sorted(by: better)
        case .newest: return items.sorted { ($0.hit.lastTouched ?? distant) > ($1.hit.lastTouched ?? distant) }
        case .oldest: return items.sorted { ($0.hit.lastTouched ?? .distantFuture) < ($1.hit.lastTouched ?? .distantFuture) }
        case .largest: return items.sorted { ($0.hit.size ?? 0) > ($1.hit.size ?? 0) }
        }
    }
}

/// Re-ranks a shortlist with Jev in one request:
/// a Noul per file ("does this one fit?"), a Choice across all of them ("which one is it?"),
/// and a Noul for whether anything fits at all.
enum JevRank {
    static let limit = 100

    struct Outcome {
        var ranked: [Ranked]
        var anyMatch: Double
        var tokens: Int
    }

    static func rank(_ shortlist: [FileHit], plan: Plan, client: Jev.Client, now: Date = Date()) async throws -> Outcome {
        let files = Array(shortlist.prefix(limit))
        let ids = files.indices.map { String(format: "F%02d", $0) }
        var described: [String: String] = [:]
        for (id, file) in zip(ids, files) { described[id] = describe(file) }

        var questions: [String: Jev.Question] = [
            "pick": .choice("Which file in `files` is the user most likely looking for with `search`?",
                            options: ids.map { (key: $0, meaning: nil) } + [(key: "none", meaning: "None of these files fits the search")]),
            "exists": .noul("Does any file in `files` fit what the user describes in `search`?",
                            yes: "At least one file fits the subject and the details the search gives",
                            no: "No file fits; the files only share words with the search"),
        ]
        for id in ids {
            questions["fit_" + id] = .noul("Does `files.\(id)` fit what the user describes in `search`: its subject, and any type, date or place the search gives?")
        }

        let state: [String: Any] = ["search": plan.query, "today": Format.today(now), "files": described]
        let response = try await client.ask(state: state, questions: questions)
        let picks = response.answers["pick"]?.probabilities ?? [:]
        let anyMatch = response.answers["exists"]?.noul ?? 0

        var ranked = zip(ids, files).map { id, file -> Ranked in
            let fit = response.answers["fit_" + id]?.noul ?? 0
            return Ranked(hit: file, score: fit + 0.35 * (picks[id] ?? 0), match: fit)
        }
        if let top = picks.filter({ $0.key != "none" }).max(by: { $0.value < $1.value }), top.value >= 0.5,
           anyMatch >= 0.5, let index = ids.firstIndex(of: top.key), (ranked[index].match ?? 0) >= 0.6 {
            ranked[index].best = true
            ranked[index].score += 1
        }
        // Files that fit come first, in the order the search asked for; the rest follow by fit.
        let fits = ranked.filter { ($0.match ?? 0) >= 0.5 }
        let rest = ranked.filter { ($0.match ?? 0) < 0.5 }.sorted { $0.score > $1.score }
        let byScore: (Ranked, Ranked) -> Bool = { $0.score > $1.score }
        return Outcome(ranked: QuickRank.order(fits, by: plan.order, better: byScore) + rest,
                       anyMatch: anyMatch, tokens: response.usage?.input_tokens ?? 0)
    }

    /// One line per file: everything Jev reads about it. File contents never leave the Mac.
    static func describe(_ file: FileHit) -> String {
        var parts = [file.name, file.kind.isEmpty ? file.contentType : file.kind,
                     "in " + Format.tildePath(file.url.deletingLastPathComponent())]
        if let date = file.modified { parts.append("changed " + Format.day(date)) }
        if let date = file.lastUsed { parts.append("opened " + Format.day(date)) }
        if let size = file.size, !file.isFolder { parts.append(Format.size(size)) }
        if let source = file.source { parts.append("downloaded from " + source) }
        if let title = file.title, !title.isEmpty, title != file.name { parts.append("title: " + String(title.prefix(80))) }
        return parts.joined(separator: " · ")
    }
}
