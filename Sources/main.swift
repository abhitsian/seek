import AppKit

let arguments = CommandLine.arguments

/// `Seek --search "the lease pdf from march" [--keywords] [--in <folder>]` runs one search in the terminal
/// and prints how it was read, what Spotlight found and how it ranked.
if let flag = arguments.firstIndex(of: "--search"), flag + 1 < arguments.count {
    let folder = arguments.firstIndex(of: "--in").flatMap { $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
    CommandLineSearch.run(arguments[flag + 1], keywordsOnly: arguments.contains("--keywords"), folder: folder)
    exit(0)
}

/// `… | Seek --store-key` saves a TypeSafe key read from standard input, so the key never appears in a command line.
if arguments.contains("--store-key") {
    let key = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    print(!key.isEmpty && KeyFile.save(key) ? "saved" : "not saved")
    exit(0)
}

/// `Seek --rewrite <url>` shows which recipe, if any, turns a web address into an app link.
if let flag = arguments.firstIndex(of: "--rewrite"), flag + 1 < arguments.count {
    let address = arguments[flag + 1]
    if let (recipe, link) = Recipes.rewrite(address) {
        print("\(recipe.app) · \(link.absoluteString)")
    } else {
        print("no recipe matched (installed apps only)")
    }
    exit(0)
}

/// `Seek --teach <App> <example url>` learns how that app's links are shaped, from one address you paste.
if let flag = arguments.firstIndex(of: "--teach"), flag + 2 < arguments.count {
    if let recipe = Recipes.teach(app: arguments[flag + 1], example: arguments[flag + 2]) {
        Recipes.remember(recipe)
        print("learned \(recipe.app): \(recipe.match)\n  opens \(recipe.open)")
    } else {
        print("could not learn it: the app needs a URL scheme in its Info.plist, and the address needs an id in its path")
    }
    exit(0)
}

/// `Seek --launchables` lists every app, Settings page and folder Seek can open.
if arguments.contains("--launchables") {
    Launcher.refresh()
    for item in Launcher.catalog where item.kind != .app { print("\(item.label.padding(toLength: 9, withPad: " ", startingAt: 0)) \(item.title)  ·  \(item.subtitle)") }
    print("apps: \(Launcher.catalog.filter { $0.kind == .app }.count)")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    if let flag = arguments.firstIndex(of: "--show"), flag + 1 < arguments.count {
        delegate.initialQuery = arguments[flag + 1]
    }
    // `--snapshot out.png` renders the panel three seconds after launch, then quits.
    if let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count {
        delegate.snapshotPath = arguments[flag + 1]
    }
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
