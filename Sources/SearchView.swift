import AppKit
import QuickLookThumbnailing
import SwiftUI

/// What the panel does with a result. The panel controller supplies these.
struct Actions {
    var launch: (Launchable) -> Void
    var open: (Ranked) -> Void
    var reveal: (Ranked) -> Void
    var quickLook: (Ranked) -> Void
    var copyPath: (Ranked) -> Void
    var settings: () -> Void
}

struct SearchView: View {
    @ObservedObject var engine: SearchEngine
    let actions: Actions
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            if !engine.chips.isEmpty { chipRow }
            Divider().opacity(0.6)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.6)
            footer
        }
        .onAppear { focused = true }
        .onChange(of: engine.focusToken) { focused = true }
    }

    // MARK: Parts

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("", text: $engine.text, prompt: Text("Describe the file you want"))
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($focused)
            if engine.status == .working {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(engine.chips) { chip in
                    ChipView(chip: chip) { engine.tap(chip) }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 11)
    }

    @ViewBuilder private var content: some View {
        if engine.query.isEmpty {
            EmptyStateView(engine: engine, settings: actions.settings)
        } else if engine.results.isEmpty && engine.launchables.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: engine.status == .working ? "sparkle.magnifyingglass" : "questionmark.folder")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(engine.status == .working ? "Reading your search…" : "No files found")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                if engine.status != .working, engine.chips.contains(where: { $0.on && $0.id != .folder }) {
                    Text("Remove a filter above to widen the search.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            results
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    if engine.intent == .change {
                        Label("Seek finds files but doesn't delete, move or send them. Pick one and press ⌘↩ to do that in Finder.",
                              systemImage: "hand.raised")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    if engine.noClearMatch {
                        Label("Nothing clearly matches. These are the closest files.", systemImage: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    if !engine.launchables.isEmpty {
                        SectionHeader(title: "Apps & actions")
                        ForEach(Array(engine.launchables.enumerated()), id: \.element.id) { index, item in
                            LaunchRow(item: item, selected: index == engine.selected)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { actions.launch(item) }
                                .simultaneousGesture(TapGesture().onEnded { engine.selected = index })
                        }
                        if !engine.results.isEmpty { SectionHeader(title: "Files") }
                    }
                    ForEach(Array(engine.results.enumerated()), id: \.element.id) { index, item in
                        ResultRow(item: item, selected: engine.launchables.count + index == engine.selected, showMatch: engine.isRanked)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { actions.open(item) }
                            .simultaneousGesture(TapGesture().onEnded { engine.select(file: index) })
                            .onDrag { NSItemProvider(contentsOf: item.hit.url) ?? NSItemProvider() }
                            .contextMenu {
                                Button("Open") { actions.open(item) }
                                Button("Show in Finder") { actions.reveal(item) }
                                Button("Quick Look") { actions.quickLook(item) }
                                Divider()
                                Button("Copy Path") { actions.copyPath(item) }
                            }
                    }
                }
                .padding(8)
            }
            .onChange(of: engine.selected) { _, index in
                switch engine.currentItem {
                case .launch(let item): proxy.scrollTo(item.id)
                case .file(let item): proxy.scrollTo(item.id)
                case nil: break
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            switch engine.currentItem {
            case .launch(let item):
                KeyHint(keys: "↩", label: Self.openLabel(item.kind))
            case .file where engine.intent == .reveal:
                KeyHint(keys: "↩", label: "Show in Finder")
            default:
                KeyHint(keys: "↩", label: "Open")
                KeyHint(keys: "⌘↩", label: "Show in Finder")
            }
            if case .file = engine.currentItem { KeyHint(keys: "⌘Y", label: "Quick Look") }
            KeyHint(keys: "⌥⌘C", label: "Copy path")
            Spacer(minLength: 8)
            statusText
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 32)
    }

    static func openLabel(_ kind: Launchable.Kind) -> String {
        switch kind {
        case .app: "Open app"
        case .localApp: "Open local app"
        case .session: "Resume session"
        case .settings: "Open Settings"
        case .place: "Open folder"
        case .person: "Open in Teams"
        case .web: "Open in browser"
        case .deeplink: "Open in app"
        case .tab: "Go to tab"
        case .hint: "Add in Settings"
        }
    }

    @ViewBuilder private var statusText: some View {
        let count = engine.results.count
        let files = "\(count) \(count == 1 ? "file" : "files")"
        switch engine.status {
        case .idle where !engine.launchables.isEmpty:
            Text("\(engine.launchables.count) \(engine.launchables.count == 1 ? "match" : "matches")")
        case .idle:
            if engine.reader == .words {
                Button("Keyword search · turn on Apple Intelligence or add a TypeSafe key", action: actions.settings).buttonStyle(.link)
            } else {
                Text("\(engine.reader.rawValue) ready")
            }
        case .working:
            Text(count > 0 ? "\(files) by keyword · \(engine.reader.rawValue) is reading…" : "\(engine.reader.rawValue) is reading…")
        case .keywords:
            Text("\(files) · keyword match")
        case let .read(reader, milliseconds):
            let time = milliseconds >= 1000 ? String(format: "%.1f s", Double(milliseconds) / 1000) : "\(milliseconds) ms"
            Text("\(files) · \(reader == .jev ? "ranked" : "read") by \(reader.rawValue) in \(time)")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help("Showing keyword results. \(message)")
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

/// An app, Settings page or folder. Opens with ↩ like a file.
struct LaunchRow: View {
    let item: Launchable
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: Thumbnails.icon(for: URL(fileURLWithPath: item.iconPath)))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(item.label)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.07)))
                .foregroundStyle(selected ? Color.white : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Color.accentColor : Color.clear))
    }
}

struct ResultRow: View {
    let item: Ranked
    let selected: Bool
    let showMatch: Bool

    private var subtitle: String {
        var parts = [Format.folder(item.hit.url.deletingLastPathComponent())]
        if let size = item.hit.size, !item.hit.isFolder { parts.append(Format.size(size)) }
        if let source = item.hit.source { parts.append("from \(source)") }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(spacing: 12) {
            FileThumbnail(url: item.hit.url)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(item.hit.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.best {
                        Text("Best match")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(selected ? Color.white.opacity(0.22) : Color.accentColor.opacity(0.15)))
                            .foregroundStyle(selected ? Color.white : Color.accentColor)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if let date = item.hit.lastTouched {
                    Text(Format.relative(date))
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                }
                if showMatch, let match = item.match {
                    MatchMeter(value: match, selected: selected)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Color.accentColor : Color.clear))
    }
}

/// Five ticks for how likely Jev thinks the file is the one you want.
struct MatchMeter: View {
    let value: Double
    let selected: Bool

    var body: some View {
        let filled = Int((value * 5).rounded())
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { tick in
                Capsule()
                    .fill(tick < filled ? (selected ? Color.white : Color.accentColor)
                                        : (selected ? Color.white.opacity(0.3) : Color.primary.opacity(0.12)))
                    .frame(width: 6, height: 3)
            }
        }
        .help("Jev: \(Int((value * 100).rounded()))% likely to be what you described")
    }
}

struct ChipView: View {
    let chip: Chip
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: chip.symbol).font(.system(size: 10.5, weight: .semibold))
                Text(chip.label).font(.system(size: 12, weight: .medium))
                if chip.on {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).opacity(0.5)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .foregroundStyle(chip.on ? Color.accentColor : Color.secondary)
            .background(Capsule().fill(chip.on ? Color.accentColor.opacity(0.13) : Color.clear))
            .overlay(Capsule().strokeBorder(chip.on ? Color.clear : Color.secondary.opacity(0.45),
                                            style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(chip.help)
    }
}

struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
            Text(label)
        }
    }
}

struct EmptyStateView: View {
    @ObservedObject var engine: SearchEngine
    let settings: () -> Void

    private let examples: [(symbol: String, text: String)] = [
        ("camera.viewfinder", "screenshots from yesterday"),
        ("doc.richtext", "PDFs I downloaded last month"),
        ("film", "biggest videos in Downloads"),
        ("rectangle.on.rectangle", "slides I worked on this week"),
        ("doc.text", "notes about the roadmap from March"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if engine.reader == .words {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "key.fill").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Turn on Apple Intelligence to search in plain English")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Seek reads searches with Apple's on-device model. Without it, Seek matches the words you type against file names and contents.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Settings…", action: settings).controlSize(.small)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.08)))
                .padding(.bottom, 12)
            }
            Text("Try")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            ForEach(examples, id: \.text) { example in
                Button { engine.text = example.text } label: {
                    HStack(spacing: 10) {
                        Image(systemName: example.symbol)
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        Text(example.text)
                        Spacer()
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let folder = engine.finderFolder {
                Label("Finder is showing \(folder.lastPathComponent). Turn on “Only in \(folder.lastPathComponent)” to search just that folder, or say “here” in your search.",
                      systemImage: "folder")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Finder-style thumbnail: page previews for documents and images, icons for everything else.
struct FileThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? Thumbnails.icon(for: url))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .task(id: url) { image = await Thumbnails.load(url) }
    }
}

enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        if url.pathExtension == "icns", let image = NSImage(contentsOf: url) { return image }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func load(_ url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 34, height: 34), scale: 2,
                                                   representationTypes: .thumbnail)
        request.iconMode = true
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        cache.setObject(representation.nsImage, forKey: url.path as NSString)
        return representation.nsImage
    }
}
