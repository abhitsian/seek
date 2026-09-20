# Seek

Menu-bar Mac app for finding files by describing them. Press ⌃⌥F, type "the lease PDF I downloaded in March", and Seek shows the files that fit. It uses Spotlight's index and Apple's on-device model (Apple Intelligence, macOS 26), or TypeSafe's Jev when a key is set.

## Install

```
./build.sh              # builds, installs to ~/Applications/Seek.app, launches
./build.sh --no-launch  # builds and installs only
```

Seek reads searches with Apple Intelligence when it is on (System Settings → Apple Intelligence & Siri). Nothing leaves the Mac. A TypeSafe key is optional: paste one in Settings (⌘, in the panel) and Jev reads and re-ranks instead. The key lives in `~/Library/Application Support/Seek/typesafe-key`, readable only by your user (mode 600). Not the Keychain: without an Apple team ID, Keychain ties an entry to one exact build, so every rebuild asked for access again. `printf %s "$KEY" | Seek --store-key` saves a key without putting it on a command line. With neither, Seek matches the typed words against file names, titles, download sites and file contents.

## Using it

| Key | Action |
|---|---|
| ⌃⌥F | Open or close the panel (⌥Space and ⌃⌥⌘F are available in Settings) |
| ↑ ↓ | Move through results |
| ↩ | Open the file |
| ⌘↩ | Show it in Finder |
| ⌘Y | Quick Look |
| ⌥⌘C | Copy its path |
| Esc | Clear the search, then close |

The standard editing keys work in the search field: ⌘A, ⌘C, ⌘V, ⌘X, ⌘Z and ⇧⌘Z.

**Apps, Settings and folders.** Above the files, an "Apps & Settings" section lists matching apps, System Settings pages, Privacy & Security sections and Finder folders. ↩ opens them; a Settings item opens System Settings on that page or section through its `x-apple.systempreferences:` link. They show when the search names one ("bluetooth", "slack", "dark mode") or asks to open or change something ("open slack", "screen recording permission", "turn on dark mode"). A search that asks for Settings and matches a page shows no files.

- Settings pages come from the Mac's own `/System/Library/ExtensionKit/Extensions` bundles (51 on macOS 26.2), with each page's English name, icon and a list of synonyms ("dark mode" → Appearance, "wifi" → Wi‑Fi).
- Privacy & Security sections use the anchors found in that pane's bundle (`Privacy_ScreenCapture`, `Privacy_Camera`, …). Full Disk Access, Input Monitoring, Contacts and Reminders use their widely documented anchors, which the bundle does not store as plain strings.
- Apps come from /Applications, /System/Applications, ~/Applications and one folder level below them; the list rebuilds when the panel opens, at most once a minute.
- `Seek --launchables` prints the whole catalog.

Other apps' internal sections have no public list, so deep links go only as far as opening the app, with two exceptions below.

**Teams and the browser.** Seek reads a few kinds of request from the words and replaces the file search with the action:

| You type | Seek opens |
|---|---|
| "chat with alex", "message alex saying the draft is ready", "ping sam" | A Teams chat (`msteams:/l/chat/0/0?users=…`), with the message pre-filled when you give one |
| "call alex", "video call alex", "meet with alex" | A Teams call, video call, or new meeting with them invited |
| "google swift regex", "look up lisbon weather", "youtube lofi" | A Google or YouTube search in the default browser |
| "github.com/apple/swift", "open notion.so" | That address |
| "gmail", "open github", "the quarterly plan doc" | The site, or matching pages from Chrome bookmarks and history |
| "tabs", "nimble tab", "switch to jira", "tabs about pricing" | That open Chrome tab, brought to the front |

Names resolve in this order: the People list in Settings (`Name <email>, nicknames`, stored at `~/Library/Application Support/Seek/people.txt`), then document authors Spotlight knows ("alex" → Alex Kim). Set a work domain in Settings and Seek will guess first.last@ that domain from a name alone, marking the row "guessed address"; with no domain set it asks you to add the person instead. "chat", "message", "ping" and "dm" always mean a person; softer verbs ("call", "tell", "meet") count only when the name is a real person, so "call notes" stays a file search.

**Open tabs** come from Chrome and [Handle](https://github.com/abhitsian/handle) together. Chrome's own list is complete and in order, read in three bulk AppleScript requests (about 0.2 s for 40 tabs; asking tab by tab took 2.7 s). Handle (`http://127.0.0.1:4910/api/state`) adds each page's text snippet and its t-label, matched by address, so "tabs about pricing" matches page text as well as titles. Handle alone keeps one record per address, so two tabs on the same page show once; Seek uses it alone only until macOS lets Seek control Chrome, which it asks on the first tab switch. "tabs" on its own lists every tab in Chrome's order; "tab", "tabs", "switch" or "chrome" with other words lists every match and skips the file search; without those words, a tab shows only when every word matches its title. ↩ brings the tab to the front by Chrome's tab id (the same number Handle's extension records), falling back to its address, then to opening the address. The first switch asks whether Seek may control Chrome.

Browser history comes from Chrome's `History` database, copied to `~/Library/Caches/io.github.abhitsian.seek` at most every ten minutes because Chrome keeps the original locked. Pages match when every word of the search is in the title. Nothing leaves the Mac.

Drag a result into Mail, Slack or a Finder window to use the file there. The chips under the search field show how Seek read the search (PDFs, March 2026, "lease"). Click a chip to drop that filter.

When Finder is in front, the panel offers "Only in <folder>" for the folder its front window shows. A search that says "here" or "in this folder" turns it on. The first time, macOS asks whether Seek may control Finder; Seek only reads the front window's folder.

## How a search runs

1. **Instant pass, no model.** Word lists read the search: file kind, dates ("last month", "2 weeks ago", "March 2026"), place, sort order, size ("over 500 MB") and intent ("open", "show in Finder", "delete"). Spotlight matches file names. Results show while you type.
2. **A model reads the search**, after a 0.45 s pause:
   - **Apple Intelligence** (default, 1.5–3 s, on-device). It returns subject words, related words for the same subject ("invoice" → bill, receipt), file kind, size and "N days ago". On 13 test searches it also invented dates, places and sort orders the search never gave, so Seek keeps a model answer only when a word in the search supports it, and the model can drop keywords but never add them. Dates, places and order always come from the word lists.
   - **Jev** (with a TypeSafe key, ~0.1 s per request). One request with Choice questions for kind, time, month, year, place, size and order, plus a Noul per word.
3. **Spotlight fetches candidates.** Names first, related words as whole words in names, then words inside files (capped at 500), loosening when little matches. A search with only a date matches files opened in that range first, then changed files in Desktop, Documents, Downloads and cloud folders, because thousands of app and cache files change every day.
4. **Ranking.** Whole-word name matches beat prefixes, which beat substrings ("tax" ranks Income Tax above taxonomy), plus recency. With Jev, a second request re-ranks up to 100 candidates: one Noul per file, one Choice across them, one Noul for whether anything fits.

Seek never changes files. A search that asks to delete, move or send something shows the files with a note to do that in Finder; "show … in Finder" or "where is" makes ↩ reveal the file instead of opening it.

## What leaves the Mac

With Apple Intelligence, nothing: the model runs on the Mac. With a TypeSafe key, each search sends the search text, today's date, and for each candidate file its name, kind, folder path, changed and opened dates, size, download site and document title. File contents are never sent.

## Testing from the terminal

```
~/Applications/Seek.app/Contents/MacOS/Seek --search "resume pdf from march"             # full pipeline with the active reader
~/Applications/Seek.app/Contents/MacOS/Seek --search "resume pdf" --keywords             # word lists only
~/Applications/Seek.app/Contents/MacOS/Seek --show "screenshots from yesterday" --snapshot out.png   # renders the panel to PNG
```

`Tools/mock_jev.py` stands in for the TypeSafe API. It rejects requests that break the documented schema, so the pipeline can be tested without a key:

```
python3 Tools/mock_jev.py 8765 &
TYPESAFE_ENDPOINT=http://127.0.0.1:8765 TYPESAFE_API_KEY=test ~/Applications/Seek.app/Contents/MacOS/Seek --search "the lease agreement pdf"
```

## Files

| File | Contents |
|---|---|
| `Sources/Jev.swift` | Typed client for `POST /v1/systemone`. Swift enums that conform to `JevOption` become Choice questions whose answers decode back into the enum |
| `Sources/Plan.swift` | What a search asks for: kind, time, month, place, size and order enums, with their Spotlight predicates |
| `Sources/Planner.swift` | `JevPlanner` (one request) and `QuickPlanner` (word lists, sizes, "N ago") |
| `Sources/AppleReader.swift` | Apple Intelligence reader: `@Generable` schema, prewarming, and the merge that keeps only answers the search's words support |
| `Sources/Spotlight.swift` | MDQuery wrapper, candidate retrieval with loosening, noise filter (Library, node_modules, hidden folders, app bundles) |
| `Sources/ChromeTabs.swift` | Open tabs from Handle or Chrome, matching, and switching to a tab |
| `Sources/Commands.swift` | Teams person requests, People list and author lookup, web searches, URLs, sites, Chrome history and bookmarks |
| `Sources/Launcher.swift` | Apps, Settings pages and sections, and Finder folders: the catalog, matching and opening |
| `Sources/Rank.swift` | `QuickRank` (name matches plus recency) and `JevRank` (the re-ranking request) |
| `Sources/SearchEngine.swift` | Runs the two passes as you type, chips, selection |
| `Sources/SearchView.swift`, `Panel.swift` | Floating panel, keyboard handling, Quick Look |
| `Sources/Settings.swift`, `SettingsView.swift` | Keychain key, model, shortcut, open at login, Finder bridge |

Constraints: `kMDItemPath` cannot be read from MDQuery value lists, so it is read per item. Spotlight types TypeScript `.ts` files as MPEG-2 video, so the video filter excludes `public.mpeg-2-transport-stream`.
