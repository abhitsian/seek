import Foundation

/// Who read the search.
enum Reader: String {
    case words = "word lists"
    case jev = "Jev"
    case apple = "Apple Intelligence"
}

/// What the user wants done with the file. Seek opens and reveals; it never changes files.
enum Intent: Equatable {
    case find, open, reveal, change

    private static let cues: [(Intent, Set<String>)] = [
        (.change, ["delete", "remove", "trash", "move", "rename", "send", "share", "email", "edit", "upload", "attach"]),
        (.reveal, ["finder", "reveal", "locate", "where", "where's", "wheres"]),
        (.open, ["open", "launch", "play", "watch", "view"]),
    ]

    static func detect(_ words: [Words.Word]) -> Intent {
        let lower = Set(words.filter { !$0.quoted }.map { $0.text.lowercased() })
        return cues.first { !$0.1.isDisjoint(with: lower) }?.0 ?? .find
    }
}

/// What a search asks for, once the words are read: the subject words plus any type, date, place, size and order.
struct Plan: Equatable {
    var query: String
    var keywords: [String] = []
    /// Other words for the same subject, matched against file names only.
    var related: [String] = []
    var kind: FileKind = .any
    var dates: DateInterval?
    var datesLabel = ""
    var place: Place = .anywhere
    var size: SizeHint = .any
    /// Exact bounds from phrases like "over 500 MB". They take precedence over `size`.
    var minBytes: Int64?
    var maxBytes: Int64?
    var order: Order = .best
    var intent: Intent = .find
    var reader: Reader = .words

    var filterClauses: [String] {
        var clauses: [String] = []
        if let clause = kind.clause { clauses.append(clause) }
        if let dates { clauses.append(Spotlight.dateClause(dates)) }
        if minBytes != nil || maxBytes != nil {
            if let minBytes { clauses.append("kMDItemFSSize >= \(minBytes)") }
            if let maxBytes { clauses.append("kMDItemFSSize < \(maxBytes)") }
        } else if let clause = size.clause {
            clauses.append(clause)
        }
        return clauses
    }

    var hasSizeFilter: Bool { size != .any || minBytes != nil || maxBytes != nil }

    var sizeLabel: String {
        if let minBytes { return "Over " + Format.size(minBytes) }
        if let maxBytes { return "Under " + Format.size(maxBytes) }
        return size.label
    }
}

enum FileKind: String, JevOption {
    case any, pdf, document, spreadsheet, presentation, image, screenshot, video, audio, code, archive, folder, app

    var meaning: String {
        switch self {
        case .any: "The search does not say what kind of file"
        case .pdf: "A PDF"
        case .document: "A document: PDF, Word, Pages, Markdown, plain text or rich text"
        case .spreadsheet: "A spreadsheet: Excel, Numbers or CSV"
        case .presentation: "A slide deck: Keynote or PowerPoint"
        case .image: "A photo, picture or image"
        case .screenshot: "A screenshot"
        case .video: "A video, movie or screen recording"
        case .audio: "Audio: a song, voice memo, podcast or sound recording"
        case .code: "Source code or a script"
        case .archive: "A zip file, archive or disk image"
        case .folder: "A folder"
        case .app: "An application"
        }
    }

    var label: String {
        switch self {
        case .any: "Any kind"
        case .pdf: "PDFs"
        case .document: "Documents"
        case .spreadsheet: "Spreadsheets"
        case .presentation: "Presentations"
        case .image: "Images"
        case .screenshot: "Screenshots"
        case .video: "Videos"
        case .audio: "Audio"
        case .code: "Code"
        case .archive: "Archives"
        case .folder: "Folders"
        case .app: "Apps"
        }
    }

    var symbol: String {
        switch self {
        case .any: "doc"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle"
        case .image: "photo"
        case .screenshot: "camera.viewfinder"
        case .video: "film"
        case .audio: "waveform"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .archive: "archivebox"
        case .folder: "folder"
        case .app: "app"
        }
    }

    /// The Spotlight predicate for this kind.
    var clause: String? {
        func tree(_ types: String...) -> String {
            "(" + types.map { "kMDItemContentTypeTree == \"\($0)\"" }.joined(separator: " || ") + ")"
        }
        switch self {
        case .any: return nil
        case .pdf: return tree("com.adobe.pdf")
        case .document:
            // "Tax documents" usually means PDFs too.
            return "(" + [tree("com.adobe.pdf", "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
                               "com.apple.iwork.pages.pages", "com.apple.iwork.pages.sffpages", "public.rtf",
                               "net.daringfireball.markdown", "org.oasis-open.opendocument.text"),
                          "kMDItemContentType == \"public.plain-text\""].joined(separator: " || ") + ")"
        case .spreadsheet: return tree("public.spreadsheet", "public.comma-separated-values-text")
        case .presentation: return tree("public.presentation", "com.apple.iwork.keynote.key", "com.apple.iwork.keynote.sffkey")
        case .image: return tree("public.image")
        case .screenshot: return "(kMDItemIsScreenCapture == 1)"
        case .video:
            // Spotlight files TypeScript sources as MPEG-2 transport streams, which count as movies.
            return "(" + tree("public.movie") + " && kMDItemContentType != \"public.mpeg-2-transport-stream\")"
        case .audio: return tree("public.audio")
        case .code: return tree("public.source-code", "public.script", "public.shell-script")
        case .archive: return tree("public.archive", "com.apple.disk-image")
        case .folder: return "(kMDItemContentType == \"public.folder\")"
        case .app: return "(kMDItemContentType == \"com.apple.application-bundle\")"
        }
    }
}

enum TimeWindow: String, JevOption {
    case any, today, yesterday
    case thisWeek = "this_week", lastWeek = "last_week", thisMonth = "this_month", lastMonth = "last_month"
    case lastFewMonths = "last_few_months", thisYear = "this_year", lastYear = "last_year"
    case overAYearAgo = "over_a_year_ago"

    var meaning: String {
        switch self {
        case .any: "The search gives no time, or names a specific month or year instead"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thisWeek: "This week, or the last few days"
        case .lastWeek: "Last week"
        case .thisMonth: "This month, or the last few weeks"
        case .lastMonth: "Last month"
        case .lastFewMonths: "In the last few months, or recently"
        case .thisYear: "Earlier this year"
        case .lastYear: "Last year"
        case .overAYearAgo: "More than a year ago, or a long time ago"
        }
    }

    var label: String {
        switch self {
        case .any: ""
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thisWeek: "Past 7 days"
        case .lastWeek: "Last week"
        case .thisMonth: "Past 30 days"
        case .lastMonth: "Last month"
        case .lastFewMonths: "Past 3 months"
        case .thisYear: "This year"
        case .lastYear: "Last year"
        case .overAYearAgo: "Over a year ago"
        }
    }

    func interval(now: Date, calendar: Calendar = .current) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        func daysBack(_ days: Int) -> DateInterval {
            DateInterval(start: calendar.date(byAdding: .day, value: -days, to: today)!, end: tomorrow)
        }
        func unit(_ component: Calendar.Component, back: Int) -> DateInterval? {
            guard let anchor = calendar.date(byAdding: component, value: -back, to: now) else { return nil }
            return calendar.dateInterval(of: component, for: anchor)
        }
        switch self {
        case .any: return nil
        case .today: return DateInterval(start: today, end: tomorrow)
        case .yesterday: return DateInterval(start: calendar.date(byAdding: .day, value: -1, to: today)!, end: today)
        case .thisWeek: return daysBack(7)
        case .lastWeek: return unit(.weekOfYear, back: 1)
        case .thisMonth: return daysBack(31)
        case .lastMonth: return unit(.month, back: 1)
        case .lastFewMonths: return daysBack(92)
        case .thisYear: return calendar.dateInterval(of: .year, for: now).map { DateInterval(start: $0.start, end: tomorrow) }
        case .lastYear: return unit(.year, back: 1)
        case .overAYearAgo:
            return DateInterval(start: calendar.date(from: DateComponents(year: 1995))!,
                                end: calendar.date(byAdding: .year, value: -1, to: today)!)
        }
    }
}

enum Month: String, JevOption {
    case unnamed = "none"
    case january, february, march, april, may, june, july, august, september, october, november, december

    var meaning: String { self == .unnamed ? "The search names no month" : rawValue.capitalized }
    var number: Int { Month.allCases.firstIndex(of: self)! }
}

enum Place: String, JevOption {
    case anywhere, here, desktop, downloads, documents, icloud, pictures, movies, music, applications

    var meaning: String {
        switch self {
        case .anywhere: "The search gives no place"
        case .here: "The folder open right now, as in \"here\" or \"in this folder\""
        case .desktop: "The Desktop"
        case .downloads: "The Downloads folder"
        case .documents: "The Documents folder"
        case .icloud: "iCloud Drive"
        case .pictures: "The Pictures folder"
        case .movies: "The Movies folder"
        case .music: "The Music folder"
        case .applications: "The Applications folder"
        }
    }

    var label: String {
        switch self {
        case .anywhere: "Anywhere"
        case .here: "This folder"
        case .desktop: "Desktop"
        case .downloads: "Downloads"
        case .documents: "Documents"
        case .icloud: "iCloud Drive"
        case .pictures: "Pictures"
        case .movies: "Movies"
        case .music: "Music"
        case .applications: "Applications"
        }
    }

    var url: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .anywhere, .here: return nil
        case .desktop: return home.appendingPathComponent("Desktop")
        case .downloads: return home.appendingPathComponent("Downloads")
        case .documents: return home.appendingPathComponent("Documents")
        case .icloud: return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        case .pictures: return home.appendingPathComponent("Pictures")
        case .movies: return home.appendingPathComponent("Movies")
        case .music: return home.appendingPathComponent("Music")
        case .applications: return URL(fileURLWithPath: "/Applications")
        }
    }
}

enum SizeHint: String, JevOption {
    case any, small, large, huge

    var meaning: String {
        switch self {
        case .any: "The search gives no size"
        case .small: "Small files"
        case .large: "Large files, over 100 MB"
        case .huge: "Very large files, over 1 GB"
        }
    }

    var label: String {
        switch self {
        case .any: ""
        case .small: "Under 1 MB"
        case .large: "Over 100 MB"
        case .huge: "Over 1 GB"
        }
    }

    var clause: String? {
        switch self {
        case .any: nil
        case .small: "kMDItemFSSize < 1048576"
        case .large: "kMDItemFSSize >= 104857600"
        case .huge: "kMDItemFSSize >= 1073741824"
        }
    }
}

enum Order: String, JevOption {
    case best, newest, oldest, largest

    var meaning: String {
        switch self {
        case .best: "Best match first"
        case .newest: "Most recent first, as in \"latest\", \"last\" or \"most recent\""
        case .oldest: "Oldest first"
        case .largest: "Largest first, as in \"biggest\" or \"taking up space\""
        }
    }

    var label: String {
        switch self {
        case .best: "Best match"
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .largest: "Largest first"
        }
    }
}

/// Splits a search into words, keeping "quoted phrases" whole.
enum Words {
    struct Word: Equatable {
        let text: String
        let quoted: Bool
    }

    static let filler: Set<String> = [
        "a", "an", "the", "my", "our", "your", "me", "i", "i'm", "im", "i've", "ive", "of", "from", "for", "to", "in",
        "on", "at", "by", "with", "about", "and", "or", "that", "these", "those", "some", "any", "all", "it", "its",
        "is", "was", "were", "be", "been", "find", "show", "get", "open", "search", "where", "which", "what", "whats",
        "did", "do", "does", "have", "had", "got", "file", "files", "one", "ones", "thing", "things", "stuff", "please",
        "can", "you", "there", "saved", "put", "kept", "made", "sent", "look", "looking", "need", "want", "like",
        "delete", "remove", "trash", "move", "rename", "send", "share", "email", "edit", "upload", "attach", "copy",
        "finder", "reveal", "locate", "where's", "wheres", "launch", "play", "watch", "view", "help", "called", "named",
        "titled", "make", "created", "worked", "wrote", "every",
    ]

    static func split(_ query: String) -> [Word] {
        var words: [Word] = []
        var current = ""
        var quote: Character?
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",.;:!?()[]{}'’"))
        func flush(_ quoted: Bool) {
            let text = current.trimmingCharacters(in: quoted ? .whitespaces : trim)
            if !text.isEmpty { words.append(Word(text: text, quoted: quoted)) }
            current = ""
        }
        for character in query {
            if let open = quote {
                if character == open || (open == "“" && character == "”") {
                    flush(true)
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "“" {
                flush(false)
                quote = character
            } else if character.isWhitespace {
                flush(false)
            } else {
                current.append(character)
            }
        }
        flush(quote != nil)
        return words
    }
}
