import Foundation

/// Reads a search with Jev: one request, every question asked at once.
/// Choices pick the kind, time, place, size and order; one Noul per word decides whether it names the file.
enum JevPlanner {
    static func plan(_ query: String, client: Jev.Client, now: Date = Date()) async throws -> Plan {
        let words = Words.split(query)
        let asked = words.filter { !$0.quoted && !Words.filler.contains($0.text.lowercased()) }
        let thisYear = Calendar.current.component(.year, from: now)
        let years = [(key: "none", meaning: Optional("The search names no year"))]
            + (0..<16).map { (key: String(thisYear - $0), meaning: Optional<String>.none) }

        var questions: [String: Jev.Question] = [
            "kind": .pick("What kind of file is the user looking for in `query`?", from: FileKind.self),
            "when": .pick("When was the file made, changed or opened, according to `query`? Today is `today`.", from: TimeWindow.self),
            "month": .pick("Which month does `query` name for the file?", from: Month.self),
            "year": .choice("Which year does `query` name for the file?", options: years),
            "place": .pick("Where on the Mac is the file, according to `query`?", from: Place.self),
            "size": .pick("What size of file does `query` ask for?", from: SizeHint.self),
            "order": .pick("How does `query` want the results ordered?", from: Order.self),
        ]
        for (index, word) in asked.enumerated() {
            questions["word\(index)"] = .noul(
                "In `query`, is the word \"\(word.text)\" part of the name or subject of the file the user wants?",
                yes: "It names the file or what it is about: a title, person, project, place, topic, or a word in the file name",
                no: "It only says what type of file it is, when it was made or opened, where it is, how big it is, or it is a filler word")
        }

        let state: [String: Any] = ["query": query, "today": Format.today(now)]
        let answers = try await client.ask(state: state, questions: questions).answers

        var plan = Plan(query: query, intent: Intent.detect(words), reader: .jev)
        plan.keywords = words.filter(\.quoted).map(\.text)
        // A month, type or place word is already a filter; as a keyword it would also demand the word in the file.
        for (index, word) in asked.enumerated() where (answers["word\(index)"]?.noul ?? 0) >= 0.5
            && !QuickPlanner.filterWords.contains(word.text.lowercased()) {
            plan.keywords.append(word.text)
        }
        // Each filter needs a word in the search behind it: Jev fills "when" and "order" on searches that
        // never mention either ("open slack" came back as files changed today).
        let typed = Set(words.map { $0.text.lowercased() })
        plan.kind = answers["kind"]?.picked(FileKind.self) ?? .any
        if !typed.isDisjoint(with: QuickPlanner.placeWords) {
            plan.place = answers["place"]?.picked(Place.self) ?? .anywhere
        }
        if !typed.isDisjoint(with: QuickPlanner.sizeWords) || QuickPlanner.mentionsNumber(query, unit: true) {
            plan.size = answers["size"]?.picked(SizeHint.self) ?? .any
        }
        if !typed.isDisjoint(with: QuickPlanner.orderWords) || !typed.isDisjoint(with: QuickPlanner.timeWords)
            || !typed.isDisjoint(with: QuickPlanner.sizeWords) {
            plan.order = answers["order"]?.picked(Order.self) ?? .best
        }

        let month = answers["month"]?.picked(Month.self).flatMap { $0 == .unnamed ? nil : $0 }
        let year = answers["year"].flatMap { answer -> Int? in
            guard let choice = answer.choice, (answer.probabilities?[choice] ?? 1) >= 0.5 else { return nil }
            return Int(choice)
        }
        let mentionsTime = !typed.isDisjoint(with: QuickPlanner.timeWords) || QuickPlanner.mentionsNumber(query, unit: false)
        if mentionsTime, month != nil || year != nil {
            (plan.dates, plan.datesLabel) = Dates.named(month: month, year: year, now: now)
        } else if mentionsTime, let window = answers["when"]?.picked(TimeWindow.self), window != .any {
            plan.dates = window.interval(now: now)
            plan.datesLabel = window.label
        }
        return plan
    }
}

/// Reads a search with word lists. Used for instant results while typing, and when there is no TypeSafe key.
enum QuickPlanner {
    private static let kinds: [String: FileKind] = [
        "pdf": .pdf, "pdfs": .pdf,
        "doc": .document, "docs": .document, "docx": .document, "document": .document, "word": .document, "markdown": .document, "txt": .document,
        "sheet": .spreadsheet, "sheets": .spreadsheet, "spreadsheet": .spreadsheet, "spreadsheets": .spreadsheet,
        "excel": .spreadsheet, "xlsx": .spreadsheet, "csv": .spreadsheet,
        "deck": .presentation, "decks": .presentation, "slides": .presentation, "slide": .presentation, "ppt": .presentation,
        "pptx": .presentation, "keynote": .presentation, "presentation": .presentation, "presentations": .presentation,
        "photo": .image, "photos": .image, "image": .image, "images": .image, "picture": .image, "pictures": .image,
        "pic": .image, "pics": .image, "jpg": .image, "jpeg": .image, "png": .image, "heic": .image,
        "screenshot": .screenshot, "screenshots": .screenshot,
        "video": .video, "videos": .video, "movie": .video, "movies": .video, "mp4": .video, "mov": .video,
        "audio": .audio, "song": .audio, "songs": .audio, "mp3": .audio, "m4a": .audio,
        "code": .code, "script": .code, "scripts": .code,
        "zip": .archive, "zips": .archive, "archive": .archive, "archives": .archive, "dmg": .archive,
        "folder": .folder, "folders": .folder, "directory": .folder,
        "app": .app, "apps": .app, "application": .app, "applications": .app,
    ]
    private static let places: [String: Place] = [
        "desktop": .desktop, "downloads": .downloads, "downloaded": .downloads, "download": .downloads,
        "icloud": .icloud, "here": .here,
    ]
    private static let windows: [String: TimeWindow] = [
        "today": .today, "yesterday": .yesterday, "this week": .thisWeek, "past week": .thisWeek, "last week": .lastWeek,
        "this month": .thisMonth, "last month": .lastMonth, "recent": .lastFewMonths, "recently": .lastFewMonths,
        "lately": .lastFewMonths, "this year": .thisYear, "last year": .lastYear,
    ]
    private static let orders: [String: Order] = [
        "latest": .newest, "newest": .newest, "last": .newest, "oldest": .oldest, "old": .oldest, "older": .oldest,
        "earliest": .oldest,
        "biggest": .largest, "largest": .largest, "big": .largest, "large": .largest, "huge": .largest,
    ]
    private static let months: [String: Month] = {
        var map: [String: Month] = [:]
        for month in Month.allCases where month != .unnamed {
            map[month.rawValue] = month
            if month.rawValue.count > 4 { map[String(month.rawValue.prefix(3))] = month }
        }
        map["sept"] = .september
        return map
    }()

    /// Words that support a filter. A reader may only set a filter the search actually mentions:
    /// both Jev and Apple's model otherwise invent a date, a place or an order the user never gave.
    static let timeWords: Set<String> = {
        var words = Set(months.keys)
        for phrase in windows.keys { words.formUnion(phrase.split(separator: " ").map(String.init)) }
        return words.union(["ago", "day", "days", "week", "weeks", "month", "months", "year", "years",
                            "earlier", "since", "before", "after", "morning", "night", "weekend"])
    }()
    static let placeWords: Set<String> = Set(places.keys).union(["documents", "folder", "folders", "drive", "finder"])
    static let sizeWords: Set<String> = ["big", "bigger", "biggest", "large", "larger", "largest", "huge", "small",
                                         "smaller", "smallest", "tiny", "size", "gb", "mb", "kb", "heavy"]
    static let orderWords: Set<String> = Set(orders.keys).union(["first", "recent", "recently", "newer", "older"])

    /// Whether the search mentions a year (2026) or a size (500mb), which no word list can enumerate.
    static func mentionsNumber(_ query: String, unit: Bool) -> Bool {
        let pattern = unit ? #"\d+\s*(kb|mb|gb|k|m|g|megs|gigs)\b"# : #"\b(19|20)\d{2}\b"#
        return query.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Words that name a kind of file, including a few the lists leave to Apple's model to map.
    static let kindWords: Set<String> = Set(kinds.keys).union(["documents", "recording", "recordings", "clip", "clips", "footage"])

    /// Every word the lists read as a type, date, place, size or order. Subject words never include these.
    static let filterWords: Set<String> = {
        var words = Set(kinds.keys).union(places.keys).union(orders.keys).union(months.keys)
        for phrase in windows.keys { words.formUnion(phrase.split(separator: " ").map(String.init)) }
        words.formUnion(["documents", "folder", "ago", "day", "days", "weeks", "months", "years", "past", "earlier",
                         "gb", "mb", "kb", "size", "small", "smaller", "tiny", "bigger", "larger", "recording", "recordings",
                         "over", "under", "above", "below", "than", "less", "more", "opened", "edited", "changed",
                         "modified", "added"])
        return words
    }()

    static func plan(_ query: String, now: Date = Date()) -> Plan {
        let words = Words.split(query)
        var plan = Plan(query: query, intent: Intent.detect(words))
        let lower = words.map { $0.text.lowercased() }
        var used = Set<Int>()
        var month: Month?
        var year: Int?

        for (index, word) in lower.enumerated() where !words[index].quoted {
            let next = index + 1 < lower.count ? lower[index + 1] : ""
            if let window = windows["\(word) \(next)"] {
                plan.dates = window.interval(now: now)
                plan.datesLabel = window.label
                used.formUnion([index, index + 1])
            } else if used.contains(index) {
                continue
            } else if let window = windows[word] {
                plan.dates = window.interval(now: now)
                plan.datesLabel = window.label
                used.insert(index)
            } else if let kind = kinds[word] {
                plan.kind = kind
                used.insert(index)
            } else if word == "documents", index > 0, ["in", "my"].contains(lower[index - 1]) || next == "folder" {
                plan.place = .documents
                used.insert(index)
            } else if word == "documents" {
                plan.kind = .document
                used.insert(index)
            } else if let place = places[word] {
                plan.place = place
                used.insert(index)
            } else if ["work", "worked", "working"].contains(word), next == "on" {
                used.formUnion([index, index + 1]) // "what did I work on", not a subject
            } else if word == "this", next == "folder" {
                plan.place = .here
                used.formUnion([index, index + 1])
            } else if let order = orders[word] {
                plan.order = order
                used.insert(index)
            } else if let found = months[word] {
                month = found
                used.insert(index)
            } else if word.count == 4, let number = Int(word), (1990...2100).contains(number) {
                year = number
                used.insert(index)
            }
        }
        if month != nil || year != nil {
            (plan.dates, plan.datesLabel) = Dates.named(month: month, year: year, now: now)
        }
        readSize(lower, into: &plan, used: &used)
        readAgo(lower, into: &plan, used: &used, now: now)
        plan.keywords = words.enumerated().compactMap { index, word in
            if word.quoted { return word.text }
            guard !used.contains(index), !Words.filler.contains(lower[index]), !filterWords.contains(lower[index]),
                  word.text.count > 1 else { return nil }
            return word.text
        }
        return plan
    }

    private static let units: [String: Int64] = ["kb": 1_000, "k": 1_000, "mb": 1_000_000, "m": 1_000_000, "megs": 1_000_000,
                                                 "gb": 1_000_000_000, "g": 1_000_000_000, "gigs": 1_000_000_000]

    /// "over 1gb", "bigger than 500 MB", "under 2 mb"
    private static func readSize(_ lower: [String], into plan: inout Plan, used: inout Set<Int>) {
        for (index, word) in lower.enumerated() {
            var amount: Double?
            var unit: Int64?
            var span = [index]
            if let match = word.firstMatch(of: #/^(\d+(?:\.\d+)?)(kb|k|mb|m|megs|gb|g|gigs)$/#) {
                amount = Double(match.1)
                unit = units[String(match.2)]
            } else if let number = Double(word), index + 1 < lower.count, let next = units[lower[index + 1]] {
                amount = number
                unit = next
                span.append(index + 1)
            }
            guard let amount, let unit else { continue }
            let bytes = Int64(amount * Double(unit))
            let before = lower[max(0, index - 2)..<index]
            if before.contains(where: { ["under", "below", "less", "smaller"].contains($0) }) {
                plan.maxBytes = bytes
            } else {
                plan.minBytes = bytes
            }
            used.formUnion(span)
            for (offset, word) in before.enumerated() where ["over", "above", "more", "bigger", "larger", "under", "below", "less", "smaller", "than"].contains(word) {
                used.insert(index - before.count + offset)
            }
            return
        }
    }

    /// "2 weeks ago", "a month ago", "3 days ago"
    private static func readAgo(_ lower: [String], into plan: inout Plan, used: inout Set<Int>, now: Date) {
        guard plan.dates == nil, let ago = lower.firstIndex(of: "ago"), ago >= 2 else { return }
        let days: [String: Int] = ["day": 1, "days": 1, "week": 7, "weeks": 7, "month": 30, "months": 30, "year": 365, "years": 365]
        let counts: [String: Int] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "few": 3, "couple": 2]
        guard let unit = days[lower[ago - 1]], let count = Int(lower[ago - 2]) ?? counts[lower[ago - 2]] else { return }
        (plan.dates, plan.datesLabel) = Dates.around(daysAgo: count * unit, now: now)
        used.formUnion([ago - 2, ago - 1, ago])
    }
}

enum Dates {
    /// "2 weeks ago" is fuzzy, so the range is 14 days ago give or take a third.
    static func around(daysAgo days: Int, now: Date, calendar: Calendar = .current) -> (DateInterval?, String) {
        let slack = max(1, days / 3)
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        guard let start = calendar.date(byAdding: .day, value: -(days + slack), to: today),
              let end = calendar.date(byAdding: .day, value: -(days - slack) + 1, to: today) else { return (nil, "") }
        let label = days % 365 == 0 ? "About \(days / 365) year\(days == 365 ? "" : "s") ago"
            : days % 30 == 0 ? "About \(days / 30) month\(days == 30 ? "" : "s") ago"
            : days % 7 == 0 ? "About \(days / 7) week\(days == 7 ? "" : "s") ago"
            : "About \(days) day\(days == 1 ? "" : "s") ago"
        return (DateInterval(start: start, end: min(end, tomorrow)), label)
    }

    /// The date range for a named month and/or year. A month with no year means its most recent occurrence.
    static func named(month: Month?, year: Int?, now: Date, calendar: Calendar = .current) -> (DateInterval?, String) {
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)
        if let month {
            let resolvedYear = year ?? (month.number <= currentMonth ? currentYear : currentYear - 1)
            guard let start = calendar.date(from: DateComponents(year: resolvedYear, month: month.number, day: 1)),
                  let interval = calendar.dateInterval(of: .month, for: start) else { return (nil, "") }
            return (interval, "\(month.rawValue.capitalized) \(resolvedYear)")
        }
        if let year, let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
           let interval = calendar.dateInterval(of: .year, for: start) {
            return (interval, String(year))
        }
        return (nil, "")
    }
}
