import AppKit
import SQLite3

/// Past Claude Code sessions, searchable by what you asked for.
///
/// Transcripts live as JSONL under ~/.claude/projects, about a gigabyte of them, so they are indexed
/// once into SQLite full-text search and updated only where a file changed. Only what you typed is
/// indexed: the assistant's replies and tool traffic are the bulk of the bytes and the least searchable
/// thing in them.
enum Sessions {
    struct Hit {
        let id: String
        let project: String
        let path: String
        let modified: Date
        let title: String
        let snippet: String
    }

    private static let transcripts = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var indexing = false

    static var database: URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Seek")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("sessions.sqlite")
    }

    // MARK: Index

    private static func open() -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK else { return nil }
        let schema = """
        CREATE VIRTUAL TABLE IF NOT EXISTS sessions USING fts5(
            id UNINDEXED, project UNINDEXED, path UNINDEXED, modified UNINDEXED, title, body);
        CREATE TABLE IF NOT EXISTS seen(path TEXT PRIMARY KEY, modified REAL);
        """
        sqlite3_exec(handle, schema, nil, nil, nil)
        return handle
    }

    /// Walks the transcripts and indexes anything new. Cheap after the first run: one stat per file.
    static func refresh(limit: Int = 0) {
        let busy = lock.withLock { () -> Bool in
            if indexing { return true }
            indexing = true
            return false
        }
        if busy { return }
        defer { lock.withLock { indexing = false } }
        guard let handle = open() else { return }
        defer { sqlite3_close(handle) }

        var known: [String: Double] = [:]
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT path, modified FROM seen", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                known[String(cString: sqlite3_column_text(statement, 0))] = sqlite3_column_double(statement, 1)
            }
        }
        sqlite3_finalize(statement)

        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil) else { return }
        var done = 0
        sqlite3_exec(handle, "BEGIN", nil, nil, nil)
        for project in projects {
            let files = (try? manager.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey]))?
                .filter { $0.pathExtension == "jsonl" } ?? []
            for file in files {
                let modified = ((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast).timeIntervalSince1970
                if let seen = known[file.path], abs(seen - modified) < 1 { continue }
                guard let session = read(file) else { continue }
                write(session, modified: modified, into: handle)
                done += 1
                if limit > 0, done >= limit { break }
            }
            if limit > 0, done >= limit { break }
        }
        sqlite3_exec(handle, "COMMIT", nil, nil, nil)
    }

    private struct Session {
        let id: String
        let project: String
        let path: String
        let title: String
        let body: String
    }

    /// Pulls the prompts out of one transcript. Lines are checked as text before being parsed,
    /// because most of a transcript is assistant and tool output that never gets indexed.
    private static func read(_ file: URL) -> Session? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var prompts: [String] = []
        var project = ""
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"type\":\"user\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = row["message"] as? [String: Any] else { continue }
            if project.isEmpty, let cwd = row["cwd"] as? String { project = cwd }
            // A string is something the user typed; an array is a tool result coming back.
            if let text = message["content"] as? String, !text.isEmpty {
                prompts.append(text)
            }
            if prompts.joined().count > 14_000 { break }
        }
        // Headless runs (the history labeller, watchers, cron jobs) open with an instruction to the model
        // rather than a request from the user, and they would swamp everything you actually typed.
        guard let first = prompts.first, !first.hasPrefix("You are"), !first.hasPrefix("You write"),
              !(first.count > 600 && prompts.count < 3) else { return nil }
        let home = NSHomeDirectory()
        return Session(id: file.deletingPathExtension().lastPathComponent,
                       project: project.hasPrefix(home) ? "~" + project.dropFirst(home.count) : project,
                       path: file.path,
                       title: String(prompts[0].prefix(140)).replacingOccurrences(of: "\n", with: " "),
                       body: prompts.joined(separator: " \n ").replacingOccurrences(of: "\n", with: " "))
    }

    private static func write(_ session: Session, modified: Double, into handle: OpaquePointer) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, "DELETE FROM sessions WHERE id = ?", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, session.id, -1, transient)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        let insert = "INSERT INTO sessions(id, project, path, modified, title, body) VALUES(?,?,?,?,?,?)"
        if sqlite3_prepare_v2(handle, insert, -1, &statement, nil) == SQLITE_OK {
            for (index, value) in [session.id, session.project, session.path, String(modified),
                                   session.title, session.body].enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            }
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        if sqlite3_prepare_v2(handle, "INSERT OR REPLACE INTO seen(path, modified) VALUES(?,?)", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, session.path, -1, transient)
            sqlite3_bind_double(statement, 2, modified)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    static var count: Int {
        guard let handle = open() else { return 0 }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        var total = 0
        if sqlite3_prepare_v2(handle, "SELECT count(*) FROM sessions", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            total = Int(sqlite3_column_int64(statement, 0))
        }
        sqlite3_finalize(statement)
        return total
    }

    // MARK: Search

    static func search(_ words: [String], limit: Int = 6) -> [Hit] {
        guard !words.isEmpty, let handle = open() else { return [] }
        defer { sqlite3_close(handle) }
        // Every word must appear; quoting keeps punctuation from being read as FTS syntax.
        let query = words.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " AND ")
        let sql = """
        SELECT id, project, path, modified, title, snippet(sessions, 5, '', '', '…', 12)
        FROM sessions WHERE sessions MATCH ? ORDER BY modified DESC LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, query, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(statement, 2, Int32(limit))
        var hits: [Hit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            hits.append(Hit(id: text(0), project: text(1), path: text(2),
                            modified: Date(timeIntervalSince1970: Double(text(3)) ?? 0),
                            title: text(4), snippet: text(5)))
        }
        return hits
    }

    static func rows(for query: String, limit: Int = 6) -> [Launchable] {
        let words = Words.split(query).map { $0.text.lowercased() }
            .filter { !Words.filler.contains($0) && !["session", "sessions", "claude", "transcript", "chat"].contains($0) && $0.count > 2 }
        guard !words.isEmpty else { return [] }
        return search(words, limit: limit).map { hit in
            Launchable(id: "session:\(hit.id)|\(hit.project)", kind: .session,
                       title: hit.title.isEmpty ? hit.id : hit.title,
                       subtitle: "\(hit.project) · \(Format.relative(hit.modified)) · \(hit.snippet)",
                       target: URL(fileURLWithPath: hit.path), iconPath: "/Applications/Utilities/Terminal.app",
                       phrases: [], badge: "Session")
        }
    }

    /// Picks the session up where it stopped, in a new Terminal window.
    static func resume(_ item: Launchable) {
        let parts = item.id.dropFirst("session:".count).split(separator: "|", maxSplits: 1).map(String.init)
        guard let id = parts.first else { return }
        let folder = parts.count > 1 ? parts[1].replacingOccurrences(of: "~", with: NSHomeDirectory()) : NSHomeDirectory()
        let command = "cd \(folder.replacingOccurrences(of: "\"", with: "\\\"")) && claude --resume \(id)"
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
        DispatchQueue.main.async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }
}
