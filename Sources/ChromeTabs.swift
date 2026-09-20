import AppKit

/// Open Chrome tabs, searchable by title, address and page text, and brought to the front on ↩.
/// The list comes from Handle (localhost:4910), whose extension keeps it current within seconds and
/// stores a text snippet of each page. Without Handle, Seek asks Chrome directly for titles and addresses.
enum ChromeTabs {
    struct Tab {
        var handle: String?
        let chromeID: String?
        let title: String
        let url: String
        var snippet: String
        var lastVisit: Date?
        /// Position in Chrome (window, then tab), for listing tabs in the order Chrome shows them.
        let order: Int
    }

    private static let handleState = URL(string: "http://127.0.0.1:4910/api/state")!
    private static let chromeBundle = "com.google.Chrome"
    /// Words that ask for a tab: "the figma tab", "switch to jira", "tabs about pricing".
    private static let cues: Set<String> = ["tab", "tabs", "switch", "chrome"]

    static var chromeRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundle).isEmpty
    }

    // MARK: Listing

    /// Every open tab. Call off the main thread: it waits up to a second on Handle and asks Chrome.
    ///
    /// Chrome's own list is complete: Handle keeps one record per address, so two tabs on the same page show as one
    /// (38 records for 41 tabs here). Seek reads Chrome's list once it may control Chrome (asked on the first tab
    /// switch) and adds Handle's page text and t-labels by address; until then, Handle's list.
    static func list() -> [Tab] {
        guard chromeRunning else { return [] }
        let handle = fromHandle()
        if handle == nil || mayControlChrome, let chrome = fromChrome(), !chrome.isEmpty {
            let known = Dictionary((handle ?? []).map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
            return chrome.map { tab in
                var tab = tab
                if let match = known[tab.url] {
                    tab.handle = match.handle
                    tab.snippet = match.snippet
                    tab.lastVisit = match.lastVisit
                }
                return tab
            }
        }
        return handle ?? []
    }

    /// Whether macOS already lets Seek control Chrome, checked without showing the permission prompt.
    private static var mayControlChrome: Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: chromeBundle)
        guard let descriptor = target.aeDesc else { return false }
        return AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, false) == noErr
    }

    private static func fromHandle() -> [Tab]? {
        var request = URLRequest(url: handleState, timeoutInterval: 1)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let done = DispatchSemaphore(value: 0)
        var body: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { body = data }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 1.5) == .success, let body,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let state = root["state"] as? [String: Any],
              state["source"] as? String == "extension", // AppleScript-sourced snapshots go stale; ask Chrome instead
              let tabs = state["tabs"] as? [String: [String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return tabs.values.map { tab in
            let handle = tab["id"] as? String
            return Tab(handle: handle, chromeID: (tab["ext_tab_id"] as? String) ?? (tab["ext_tab_id"] as? Int).map(String.init),
                       title: tab["title"] as? String ?? "", url: tab["url"] as? String ?? "",
                       snippet: tab["snippet"] as? String ?? "",
                       lastVisit: (tab["last_visit"] as? String).flatMap { iso.date(from: $0) },
                       order: handle.flatMap { Int($0.dropFirst()) } ?? 0)
        }
    }

    /// Three bulk requests (ids, titles, addresses of every tab of every window): about 0.2 s for 40 tabs,
    /// where asking tab by tab takes 2.7 s.
    private static func fromChrome() -> [Tab]? {
        let script = """
        tell application "Google Chrome"
            return {id of every tab of every window, title of every tab of every window, URL of every tab of every window}
        end tell
        """
        guard let result = onMain({ () -> NSAppleEventDescriptor? in
                  var error: NSDictionary?
                  return NSAppleScript(source: script)?.executeAndReturnError(&error)
              }), result.numberOfItems == 3,
              let ids = result.atIndex(1), let titles = result.atIndex(2), let urls = result.atIndex(3) else { return nil }
        var tabs: [Tab] = []
        for window in 1...max(1, ids.numberOfItems) where ids.numberOfItems > 0 {
            guard let windowIDs = ids.atIndex(window), let windowTitles = titles.atIndex(window),
                  let windowURLs = urls.atIndex(window) else { continue }
            for index in 1...max(1, windowIDs.numberOfItems) where windowIDs.numberOfItems > 0 {
                tabs.append(Tab(handle: nil, chromeID: windowIDs.atIndex(index)?.stringValue,
                                title: windowTitles.atIndex(index)?.stringValue ?? "",
                                url: windowURLs.atIndex(index)?.stringValue ?? "",
                                snippet: "", lastVisit: nil, order: window * 10_000 + index))
            }
        }
        return tabs
    }

    /// NSAppleScript is main-thread only; off the main thread, compiling a `tell application` script can hang.
    private static func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    // MARK: Matching

    /// Tab rows for a search, and whether it is a request for tabs (then the file search is skipped).
    /// "tabs" alone lists them all; "figma tab" or "switch to jira" matches; plain words match a title strongly enough.
    static func rows(for query: String) -> (rows: [Launchable], isCommand: Bool) {
        let typed = Words.split(query).map { $0.text.lowercased() }
        let wantsTabs = typed.contains(where: cues.contains)
        let core = typed.filter { !cues.contains($0) && !Words.filler.contains($0) && !["to", "go"].contains($0) }
        guard wantsTabs || !core.isEmpty else { return ([], false) }
        let tabs = list()
        guard !tabs.isEmpty else { return ([], false) }
        if core.isEmpty {
            // "tabs" on its own: every tab, in the order Chrome shows them.
            return (tabs.sorted { $0.order < $1.order }.map(row(for:)), true)
        }

        var scored: [(tab: Tab, score: Double)] = []
        for tab in tabs {
            let titleWords = words(of: tab.title)
            let address = URL(string: tab.url).map { words(of: ($0.host ?? "") + " " + $0.path) } ?? []
            let page = wantsTabs ? words(of: String(tab.snippet.prefix(4000))) : []
            var score = 0.0
            var all = true
            for word in core {
                if titleWords.contains(where: { $0.hasPrefix(word) }) { score += 2 }
                else if address.contains(where: { $0.hasPrefix(word) }) { score += 1.5 }
                else if page.contains(word) { score += 0.5 }
                else { all = false; break }
            }
            guard all else { continue }
            if let visited = tab.lastVisit { score += exp(-Date().timeIntervalSince(visited) / 86_400) }
            scored.append((tab, score))
        }
        // Without "tab" in the search, only strong title matches show, so ordinary file searches stay clean.
        if !wantsTabs { scored = scored.filter { $0.score >= 2 * Double(core.count) } }
        let limit = wantsTabs ? 50 : 2
        let rows = scored.sorted { $0.score > $1.score }.prefix(limit).map { row(for: $0.tab) }
        return (rows, wantsTabs && !rows.isEmpty)
    }

    private static func words(of text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func row(for tab: Tab) -> Launchable {
        let url = URL(string: tab.url) ?? URL(string: "about:blank")!
        let place = url.isFileURL ? "file" : (url.host ?? tab.url)
        let handle = tab.handle.map { " · \($0)" } ?? ""
        return Launchable(id: "tab:\(tab.chromeID ?? "")|\(tab.url)", kind: .tab,
                          title: tab.title.isEmpty ? tab.url : tab.title,
                          subtitle: "Open in Chrome · \(place)\(handle)", target: url,
                          iconPath: NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundle)?.path ?? "/Applications/Google Chrome.app",
                          phrases: [])
    }

    // MARK: Focusing

    /// Brings the tab to the front: by Chrome's tab id, which is exact even when two tabs share an address,
    /// then by address. The first time, macOS asks whether Seek may control Chrome.
    static func focus(_ item: Launchable) {
        let body = item.id.dropFirst("tab:".count)
        let chromeID = body.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
        let address = item.target.absoluteString.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let test = Int(chromeID) != nil ? "(id of t as text) is \"\(chromeID)\"" : "(URL of t) is \"\(address)\""
        func script(_ condition: String) -> String {
            """
            tell application "Google Chrome"
                repeat with w in windows
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        if \(condition) then
                            set active tab index of w to i
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
                return "missing"
            end tell
            """
        }
        DispatchQueue.main.async {
            var error: NSDictionary?
            let first = NSAppleScript(source: script(test))?.executeAndReturnError(&error).stringValue
            if first != "ok" {
                // The tab navigated or closed since the list was read: try the address, then just open it.
                let second = NSAppleScript(source: script("(URL of t) is \"\(address)\""))?.executeAndReturnError(&error).stringValue
                if second != "ok" { NSWorkspace.shared.open(item.target) }
            }
        }
    }
}
