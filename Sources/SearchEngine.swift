import Foundation
import SwiftUI

/// A filter Seek read from the search, shown as a chip the user can remove.
enum ChipID: Hashable {
    case folder, kind, dates, place, size, order, related
    case keyword(String)
}

struct Chip: Identifiable, Equatable {
    let id: ChipID
    let label: String
    let symbol: String
    /// Off chips are suggestions (the Finder folder), drawn dashed. Tapping turns them on.
    var on = true
    var help = ""
}

/// Runs searches as the user types. Two passes per search: an instant keyword pass on file names,
/// then a reader (Jev with a TypeSafe key, otherwise Apple Intelligence) reads the search and the results refresh.
@MainActor
final class SearchEngine: ObservableObject {
    enum Status: Equatable {
        case idle, working, keywords
        case read(Reader, milliseconds: Int)
        case failed(String)
    }

    @Published var text = "" {
        didSet { if text != oldValue { dismissed = []; schedule() } }
    }
    @Published private(set) var results: [Ranked] = []
    /// Apps, Settings pages and folders that match the search, shown above the files. Matched in memory, so instant.
    @Published private(set) var launchables: [Launchable] = []
    @Published private(set) var chips: [Chip] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var noClearMatch = false
    @Published private(set) var reader: Reader = .words
    @Published private(set) var intent: Intent = .find
    @Published var selected = 0
    @Published var focusToken = 0
    @Published private(set) var finderFolder: URL?
    @Published private(set) var onlyInFolder = false

    private var dismissed: Set<ChipID> = []
    private var catalogMatches: [Launchable] = []
    private var readings: [String: Plan] = [:] // each search as its reader read it, so removing a chip does not ask again
    private var plan: Plan?
    private var work: Task<Void, Never>?

    var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    enum Item { case launch(Launchable), file(Ranked) }

    /// Launchables come first in the list, then files; `selected` indexes both.
    var itemCount: Int { launchables.count + results.count }
    var currentItem: Item? {
        if launchables.indices.contains(selected) { return .launch(launchables[selected]) }
        let file = selected - launchables.count
        return results.indices.contains(file) ? .file(results[file]) : nil
    }
    var current: Ranked? { if case .file(let ranked) = currentItem { return ranked } else { return nil } }
    /// Only Jev scores each file, so only Jev results show a match meter.
    var isRanked: Bool { if case .read(.jev, _) = status { return true } else { return false } }

    init() {
        refreshReader()
        // The catalog builds in the background at launch; match again once it is there.
        NotificationCenter.default.addObserver(forName: Launcher.refreshed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.query.isEmpty, Launcher.matches(self.query) != self.launchables else { return }
                self.schedule(now: true)
            }
        }
    }

    /// Jev when there is a TypeSafe key, otherwise Apple Intelligence when it is on, otherwise word lists.
    func refreshReader() {
        let next: Reader = Prefs.apiKey != nil ? .jev : AppleReader.isAvailable ? .apple : .words
        if next != reader { readings = [:] }
        reader = next
    }

    /// The folder Finder was showing when the panel opened. Offered as a scope, and used when the search says "here".
    func prepareFolder(_ folder: URL) {
        finderFolder = folder
        chips = makeChips(plan)
        if plan?.place == .here { schedule(now: true) }
    }

    func prepareToShow() {
        refreshReader()
        Launcher.refreshIfStale()
        DispatchQueue.global(qos: .utility).async { BrowserHistory.refreshIfStale() }
        if reader == .apple { AppleReader.prewarm() }
        finderFolder = nil
        onlyInFolder = false
        text = ""
        results = []
        launchables = []
        chips = makeChips(nil)
        status = .idle
        intent = .find
        selected = 0
        focusToken += 1
    }

    func move(_ delta: Int) {
        guard itemCount > 0 else { return }
        selected = min(max(selected + delta, 0), itemCount - 1)
    }

    func select(file index: Int) { selected = launchables.count + index }

    func tap(_ chip: Chip) {
        if chip.id == .folder {
            onlyInFolder = !chip.on
            if chip.on, plan?.place == .here { dismissed.insert(.place) }
        } else {
            dismissed.insert(chip.id)
        }
        schedule(now: true)
    }

    /// ⌫ on an empty field turns off the folder scope.
    func dropScope() {
        guard onlyInFolder else { return }
        onlyInFolder = false
        chips = makeChips(plan)
    }

    func schedule(now: Bool = false) {
        work?.cancel()
        let query = self.query
        catalogMatches = query.isEmpty ? [] : Launcher.matches(query)
        if catalogMatches != launchables {
            launchables = catalogMatches
            selected = 0
        }
        // An empty search, or a request for a Settings page that matched one: no file search.
        guard !query.isEmpty, launchables.isEmpty || !Launcher.isSettingsRequest(query) else {
            plan = nil
            results = []
            chips = makeChips(nil)
            status = .idle
            intent = .find
            noClearMatch = false
            return
        }
        work = Task { [weak self] in
            if !now { try? await Task.sleep(for: .milliseconds(80)) }
            guard let self, !Task.isCancelled else { return }
            // Chat with someone, open a site, search the web: read before the file search, which a command replaces.
            if self.results.isEmpty { self.status = .working }
            let commands = await Task.detached(priority: .userInitiated) { Commands.analyze(query) }.value
            guard !Task.isCancelled else { return }
            self.merge(commands.rows)
            if commands.isCommand {
                self.showCommandOnly()
                return
            }
            await self.quickPass(query)
            guard !Task.isCancelled else { return }
            if !now { try? await Task.sleep(for: .milliseconds(self.reader == .apple ? 450 : 300)) }
            guard !Task.isCancelled else { return }
            await self.deepPass(query)
        }
    }

    // MARK: Passes

    private func quickPass(_ query: String) async {
        if reader != .words, readings[query] != nil { return }
        var plan = QuickPlanner.plan(query)
        adjust(&plan)
        let hits = await fetch(plan, content: false, broaden: false)
        guard !Task.isCancelled else { return }
        publish(plan, QuickRank.rank(hits, plan: plan, folder: finderFolder), status: reader == .words ? .keywords : .working)
    }

    private func deepPass(_ query: String) async {
        let started = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        do {
            switch reader {
            case .words:
                var plan = QuickPlanner.plan(query)
                adjust(&plan)
                let hits = await fetch(plan, content: true, broaden: false)
                guard !Task.isCancelled else { return }
                publish(plan, QuickRank.rank(hits, plan: plan, folder: finderFolder), status: .keywords)

            case .apple:
                status = .working
                var plan = try await reading(query) { try await AppleReader.plan(query) }
                guard !Task.isCancelled else { return }
                adjust(&plan)
                let hits = await fetch(plan, content: true, broaden: false)
                guard !Task.isCancelled else { return }
                publish(plan, QuickRank.rank(hits, plan: plan, folder: finderFolder), status: .read(.apple, milliseconds: elapsed()))

            case .jev:
                guard let client = Prefs.client else { return }
                status = .working
                var plan = try await reading(query) { try await JevPlanner.plan(query, client: client) }
                guard !Task.isCancelled else { return }
                adjust(&plan)
                let hits = await fetch(plan, content: true, broaden: true)
                guard !Task.isCancelled else { return }
                let shortlist = QuickRank.rank(hits, plan: plan, folder: finderFolder).prefix(JevRank.limit).map(\.hit)
                var outcome = JevRank.Outcome(ranked: [], anyMatch: 0, tokens: 0)
                if !shortlist.isEmpty { outcome = try await JevRank.rank(Array(shortlist), plan: plan, client: client) }
                guard !Task.isCancelled else { return }
                noClearMatch = !outcome.ranked.isEmpty && outcome.anyMatch < 0.35
                publish(plan, outcome.ranked, status: .read(.jev, milliseconds: elapsed()))
            }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { return }
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: Helpers

    /// Where ↩ starts: the first app, setting, tab or command; when the only rows above the files are pages from
    /// browser history, the first file, so a history match never takes ↩ away from the files the search was about.
    private var preferredStart: Int {
        if let first = launchables.firstIndex(where: { !$0.id.hasPrefix("page:") }) { return first }
        return results.isEmpty ? 0 : launchables.count
    }

    /// People, URLs and web searches first, then apps and Settings, then open tabs, then sites and history pages.
    private func merge(_ commands: [Launchable]) {
        let first = commands.filter { $0.kind == .person || $0.kind == .hint || $0.id.hasPrefix("web:") && $0.title.hasPrefix("Search ") || $0.title.hasPrefix("Open ") && $0.kind == .web }
        let tabs = commands.filter { $0.kind == .tab }
        let later = commands.filter { row in !first.contains(row) && row.kind != .tab }
        var seen = Set<String>()
        // No cap: "tabs" lists every open tab; other searches bring a handful of rows.
        let merged = (first + catalogMatches + tabs + later).filter { seen.insert($0.id).inserted }
        if merged != launchables {
            launchables = merged
            selected = preferredStart
        }
    }

    private func showCommandOnly() {
        plan = nil
        results = []
        chips = makeChips(nil)
        status = .idle
        intent = .find
        noClearMatch = false
    }

    private func reading(_ query: String, read: () async throws -> Plan) async throws -> Plan {
        if let known = readings[query] { return known }
        let plan = try await read()
        readings[query] = plan
        return plan
    }

    private func adjust(_ plan: inout Plan) {
        for id in dismissed {
            switch id {
            case .kind: plan.kind = .any
            case .dates: plan.dates = nil
            case .place: plan.place = .anywhere
            case .size: plan.size = .any; plan.minBytes = nil; plan.maxBytes = nil
            case .order: plan.order = .best
            case .related: plan.related = []
            case .keyword(let word): plan.keywords.removeAll { $0 == word }
            case .folder: break
            }
        }
    }

    private func scopeFolder(for plan: Plan) -> URL? {
        guard let finderFolder else { return nil }
        return onlyInFolder || plan.place == .here ? finderFolder : nil
    }

    private func fetch(_ plan: Plan, content: Bool, broaden: Bool) async -> [FileHit] {
        let scopes = Retrieval.scopes(for: plan, folder: scopeFolder(for: plan))
        return await Task.detached(priority: .userInitiated) {
            Retrieval.fetch(plan, scopes: scopes, content: content, broaden: broaden)
        }.value
    }

    private func publish(_ plan: Plan, _ ranked: [Ranked], status: Status) {
        let keepSelection = results.first?.id == ranked.first?.id
        self.plan = plan
        intent = plan.intent
        results = Array(ranked.prefix(60))
        chips = makeChips(plan)
        self.status = status
        if case .read(.jev, _) = status {} else { noClearMatch = false }
        let onLaunchable = selected < launchables.count && selected == preferredStart
        if !(keepSelection || onLaunchable) || selected >= itemCount { selected = preferredStart }
    }

    private func makeChips(_ plan: Plan?) -> [Chip] {
        var chips: [Chip] = []
        if let folder = finderFolder {
            let on = plan.map { scopeFolder(for: $0) != nil } ?? onlyInFolder
            chips.append(Chip(id: .folder, label: "Only in \(folder.lastPathComponent)", symbol: on ? "folder.fill" : "folder",
                              on: on, help: on ? "Searching the folder open in Finder. Click to search everywhere."
                                              : "Click to search only the folder open in Finder."))
        }
        guard let plan else { return chips }
        if plan.kind != .any { chips.append(Chip(id: .kind, label: plan.kind.label, symbol: plan.kind.symbol)) }
        if plan.dates != nil { chips.append(Chip(id: .dates, label: plan.datesLabel, symbol: "calendar")) }
        if plan.place != .anywhere, plan.place != .here { chips.append(Chip(id: .place, label: plan.place.label, symbol: "folder")) }
        if plan.hasSizeFilter { chips.append(Chip(id: .size, label: plan.sizeLabel, symbol: "internaldrive")) }
        if plan.order != .best { chips.append(Chip(id: .order, label: plan.order.label, symbol: "arrow.up.arrow.down")) }
        for word in plan.keywords { chips.append(Chip(id: .keyword(word), label: "“\(word)”", symbol: "textformat")) }
        if !plan.related.isEmpty {
            chips.append(Chip(id: .related, label: "Also " + plan.related.joined(separator: ", "), symbol: "text.badge.plus",
                              help: "Other words for the same subject, matched against file names. Click to drop them."))
        }
        return chips.map { chip in
            var chip = chip
            if chip.help.isEmpty { chip.help = "Remove this filter" }
            return chip
        }
    }
}
