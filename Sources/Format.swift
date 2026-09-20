import Foundation

enum Format {
    private static let home = NSHomeDirectory()
    private static let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
    private static let cloudStorage = home + "/Library/CloudStorage/"

    private static func formatter(_ format: String, utc: Bool = false) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if utc { formatter.timeZone = TimeZone(identifier: "UTC") }
        return formatter
    }
    private static let dayFormatter = formatter("yyyy-MM-dd")
    private static let todayFormatter = formatter("yyyy-MM-dd, EEEE")
    private static let spotlightFormatter = formatter("yyyy-MM-dd'T'HH:mm:ss'Z'", utc: true)

    /// "2026-09-19, Saturday": how Jev learns what today is.
    static func today(_ date: Date) -> String { todayFormatter.string(from: date) }
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func spotlightTime(_ date: Date) -> String { spotlightFormatter.string(from: date) }
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// "~/Downloads/Invoices"
    static func tildePath(_ url: URL) -> String {
        let path = url.path
        if path.hasPrefix(iCloud) { return "iCloud Drive" + path.dropFirst(iCloud.count) }
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// "Downloads › Invoices"
    static func folder(_ url: URL) -> String {
        var path = url.path
        if path == home { return "Home" }
        if path.hasPrefix(iCloud) {
            path = "iCloud Drive" + path.dropFirst(iCloud.count)
        } else if path.hasPrefix(cloudStorage) {
            path = String(path.dropFirst(cloudStorage.count))
        } else if path.hasPrefix(home + "/") {
            path = String(path.dropFirst(home.count + 1))
        }
        return path.split(separator: "/").joined(separator: " › ")
    }

    /// The site a download came from: the page if Safari or Chrome recorded one, otherwise the file URL.
    static func host(_ sources: [String]) -> String? {
        for source in sources.reversed() {
            if let host = URL(string: source)?.host, !host.isEmpty {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
        }
        return nil
    }

    /// "10:42", "Yesterday", "Mon", "Mar 4", "Mar 4, 2024"
    static func relative(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday " + date.formatted(date: .omitted, time: .shortened) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0, days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
