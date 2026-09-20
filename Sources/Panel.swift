import AppKit
import Quartz
import SwiftUI

/// A floating search panel that takes the keyboard without activating Seek, so Finder stays frontmost.
final class SearchPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    weak var previewSource: (QLPreviewPanelDataSource & QLPreviewPanelDelegate)?

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = previewSource
        panel.delegate = previewSource
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let engine = SearchEngine()
    var openSettings: () -> Void = {}
    private var panel: SearchPanel!
    private var hosting: NSView!
    private let size = NSSize(width: 740, height: 500)

    override init() {
        super.init()
        panel = SearchPanel(size: size)
        panel.delegate = self
        panel.previewSource = self
        panel.keyHandler = { [weak self] event in self?.handle(event) ?? false }

        let actions = Actions(
            launch: { [weak self] in self?.launch($0) },
            open: { [weak self] in self?.open($0) },
            reveal: { [weak self] in self?.reveal($0) },
            quickLook: { [weak self] item in
                guard let self else { return }
                if let index = self.engine.results.firstIndex(of: item) { self.engine.selected = index }
                self.toggleQuickLook()
            },
            copyPath: { Finder.copyPath($0.hit.url) },
            settings: { [weak self] in self?.showSettings() })
        hosting = NSHostingView(rootView: SearchView(engine: engine, actions: actions))
        panel.contentView = Self.background(around: hosting, size: size)
    }

    /// Liquid Glass, like Spotlight.
    private static func background(around content: NSView, size: NSSize) -> NSView {
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = 20
        glass.contentView = content
        return glass
    }

    var isVisible: Bool { panel.isVisible }

    /// Renders the panel's content over a plain backdrop, for checking the layout without screen-recording permission.
    func snapshot(to url: URL) {
        guard let view = hosting, let content = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: content)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
        NSBezierPath(roundedRect: view.bounds, xRadius: 20, yRadius: 20).fill()
        content.draw(in: view.bounds)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    func toggle() { panel.isVisible && panel.isKeyWindow ? hide() : show() }

    func show(query: String? = nil) {
        let finderInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Finder.bundleID
        engine.prepareToShow()
        position()
        panel.makeKeyAndOrderFront(nil)
        if let query { engine.text = query }
        if finderInFront {
            // Read Finder's folder after the panel is up, so the shortcut feels instant.
            DispatchQueue.main.async { [weak self] in
                guard let self, let folder = Finder.frontFolder() else { return }
                self.engine.prepareFolder(folder)
            }
        }
    }

    func hide() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        panel.orderOut(nil)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.16 - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    // MARK: Keys

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 125: engine.move(1); refreshPreview(); return true // ↓
        case 126: engine.move(-1); refreshPreview(); return true // ↑
        case 36, 76: // ↩
            switch engine.currentItem {
            case .launch(let item):
                // ⌘↩ shows an app or folder in Finder; a Settings page can only be opened.
                if modifiers.contains(.command), [.app, .place].contains(item.kind) {
                    hide()
                    Finder.reveal(item.target)
                } else {
                    launch(item)
                }
            case .file(let item):
                modifiers.contains(.command) || engine.intent == .reveal ? reveal(item) : open(item)
            case nil: break
            }
            return true
        case 0 where modifiers == .command: // ⌘A and the other editing keys: the panel has no Edit menu to route them
            return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case 8 where modifiers == .command: // ⌘C
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        case 9 where modifiers == .command: // ⌘V
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case 7 where modifiers == .command: // ⌘X
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        case 6 where modifiers == .command: // ⌘Z
            return NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        case 6 where modifiers == [.command, .shift]: // ⇧⌘Z
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        case 53: // esc
            if engine.text.isEmpty { hide() } else { engine.text = "" }
            return true
        case 16 where modifiers == .command: // ⌘Y
            toggleQuickLook()
            return true
        case 8 where modifiers == [.command, .option]: // ⌥⌘C
            switch engine.currentItem {
            case .launch(let item): Finder.copyPath(item.target)
            case .file(let item): Finder.copyPath(item.hit.url)
            case nil: break
            }
            return true
        case 43 where modifiers == .command: // ⌘,
            showSettings()
            return true
        case 51 where engine.text.isEmpty && modifiers.isEmpty: // ⌫ on an empty field
            engine.dropScope()
            return true
        default:
            return false
        }
    }

    // MARK: Actions

    private func launch(_ item: Launchable) {
        hide()
        if item.kind == .hint { openSettings() } else { Launcher.open(item) }
    }

    private func open(_ item: Ranked) {
        hide()
        Finder.open(item.hit.url)
    }

    private func reveal(_ item: Ranked) {
        hide()
        Finder.reveal(item.hit.url)
    }

    private func showSettings() {
        hide()
        openSettings()
    }

    private func toggleQuickLook() {
        guard engine.current != nil, let preview = QLPreviewPanel.shared() else { return }
        if preview.isVisible { preview.orderOut(nil) } else { preview.makeKeyAndOrderFront(nil) }
    }

    private func refreshPreview() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
        hide()
    }

    // MARK: Quick Look

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { engine.current == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { engine.current.map { $0.hit.url as NSURL } }
    }
}
