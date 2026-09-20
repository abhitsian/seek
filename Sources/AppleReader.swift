import Foundation
import FoundationModels

/// Reads a search with Apple's on-device model (Apple Intelligence). Free, private, no key.
///
/// The model is good at subject words, other words for the same subject, file size and "N weeks ago".
/// Tested on 13 searches, it also invented dates, places and sort orders the search never gave,
/// so those come from the word lists, and code keeps a model answer only when a word in the search supports it.
enum AppleReader {
    @Generable enum Kind { case notMentioned, pdf, document, spreadsheet, presentation, image, screenshot, video, audio, code, archive, folder, app }
    @Generable enum Size { case notMentioned, small, over100MB, over1GB }

    @Generable struct Reading {
        @Guide(description: "Words from the search that name the file or its topic. Never words about type, date, place, size or order.")
        var subjectWords: [String]
        @Guide(description: "Other words for the same topic that could be in the file name.", .maximumCount(4))
        var relatedWords: [String]
        var kind: Kind
        @Guide(description: "For 'N days/weeks/months ago', the number of days, else 0")
        var daysAgo: Int
        var size: Size
    }

    static let instructions = """
    You turn a search for files on a Mac into a plan. Fill a field only when the search says it; otherwise use notMentioned, 0 or an empty list.
    Examples:
    "open the lease pdf" → subjectWords [lease], relatedWords [agreement, rental], kind pdf.
    "delete old screenshots on my desktop" → subjectWords [], relatedWords [], kind screenshot.
    "budget I sent 3 weeks ago" → subjectWords [budget], relatedWords [expenses, forecast], kind notMentioned, daysAgo 21.
    """

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static var status: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "Apple Intelligence is on. Seek uses it to read searches when there is no TypeSafe key."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to search in plain English."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading its model."
        case .unavailable(.deviceNotEligible): return "This Mac can't run Apple Intelligence."
        case .unavailable: return "Apple Intelligence is unavailable."
        }
    }

    // A session costs a model load, so one is warmed when the panel opens and handed to the next search.
    private static let lock = NSLock()
    private static var warmed: LanguageModelSession?

    static func prewarm() {
        guard isAvailable else { return }
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        lock.withLock { warmed = session }
    }

    private static func session() -> LanguageModelSession {
        lock.withLock {
            defer { warmed = nil }
            return warmed ?? LanguageModelSession(instructions: instructions)
        }
    }

    static func plan(_ query: String, now: Date = Date()) async throws -> Plan {
        let reading = try await session().respond(to: query, generating: Reading.self,
                                                  options: GenerationOptions(sampling: .greedy)).content
        prewarm()
        return merge(reading, into: QuickPlanner.plan(query, now: now), query: query, now: now)
    }

    static func merge(_ reading: Reading, into base: Plan, query: String, now: Date) -> Plan {
        var plan = base
        plan.reader = .apple
        let typed = Set(Words.split(query).map { $0.text.lowercased() })
        func clean(_ phrases: [String]) -> [String] {
            phrases.flatMap { $0.split(separator: " ").map(String.init) }
                .filter { word in
                    let key = word.lowercased()
                    return key.count > 1 && !Words.filler.contains(key) && !QuickPlanner.filterWords.contains(key)
                }
        }

        // The model may narrow the word lists' keywords (drop "linkedin" from "invoice from linkedin") but never add one.
        let listed = Set(base.keywords.map { $0.lowercased() })
        let subject = unique(clean(reading.subjectWords).filter { listed.contains($0.lowercased()) })
        let quoted = Words.split(query).filter(\.quoted).map(\.text)
        if !subject.isEmpty { plan.keywords = unique(quoted + subject) }
        // Related words only make sense next to a subject; without one the model free-associates.
        let taken = Set(plan.keywords.map { $0.lowercased() })
        plan.related = plan.keywords.isEmpty ? []
            : Array(unique(clean(reading.relatedWords)).filter { !taken.contains($0.lowercased()) }.prefix(4))

        // Filters the word lists missed, each kept only when the search has a word that supports it.
        if plan.kind == .any, reading.kind != .notMentioned, !typed.isDisjoint(with: QuickPlanner.kindWords),
           let kind = FileKind.allCases.first(where: { "\($0)" == "\(reading.kind)" }) {
            plan.kind = kind
        }
        let mentionsSize = !typed.isDisjoint(with: QuickPlanner.sizeWords) || QuickPlanner.mentionsNumber(query, unit: true)
        if !plan.hasSizeFilter, mentionsSize {
            switch reading.size {
            case .small: plan.size = .small
            case .over100MB: plan.size = .large
            case .over1GB: plan.size = .huge
            case .notMentioned: break
            }
        }
        if plan.dates == nil, reading.daysAgo > 0, typed.contains("ago") {
            (plan.dates, plan.datesLabel) = Dates.around(daysAgo: reading.daysAgo, now: now)
        }
        return plan
    }

    private static func unique(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.filter { seen.insert($0.lowercased()).inserted }
    }
}
