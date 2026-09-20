import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @State private var key = ""
    @State private var model = Prefs.model
    @State private var shortcut = Prefs.shortcut.label
    @State private var savedKey = KeyFile.read() != nil
    @State private var status: String?
    @State private var testing = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var people = (try? String(contentsOf: People.fileURL, encoding: .utf8)) ?? Self.peopleTemplate
    @State private var workDomain = UserDefaults.standard.string(forKey: "workDomain") ?? ""
    @State private var peopleStatus: String?

    static let peopleTemplate = """
    # One person per line: Name <email>, nicknames. Seek uses these for "chat with …", "call …" and "meet with …".
    # Alex Kim <alex.kim@example.com>, alex

    """

    var body: some View {
        Form {
            Section {
                SecureField("API key", text: $key, prompt: Text(savedKey ? "Saved on this Mac" : "Paste your key"))
                TextField("Model", text: $model, prompt: Text("jev-latest"))
                HStack {
                    Button("Save") { save() }
                        .disabled(key.isEmpty && model == Prefs.model)
                    Button(testing ? "Testing…" : "Test connection") { test() }
                        .disabled(testing || (key.isEmpty && !savedKey))
                    if savedKey {
                        Button("Remove key", role: .destructive) {
                            KeyFile.delete()
                            savedKey = false
                            status = "Key removed. Seek reads searches with Apple Intelligence again."
                            Prefs.notify()
                        }
                    }
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://console.typesafe.ai/keys")!)
                }
                if let status {
                    Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: {
                Text("TypeSafe Jev (optional)")
            } footer: {
                Text("With a key, Jev reads searches and re-ranks results instead of Apple Intelligence. Each search then sends your search text, plus the names, kinds, dates, sizes, folders, download sites and document titles of up to 100 candidate files, to TypeSafe. File contents stay on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("On-device model") {
                Text(AppleReader.status).font(.callout).foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $people)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 110)
                TextField("Work email domain", text: $workDomain, prompt: Text(People.workDomain))
                HStack {
                    Button("Save People") {
                        do {
                            try people.write(to: People.fileURL, atomically: true, encoding: .utf8)
                            UserDefaults.standard.set(workDomain.trimmingCharacters(in: .whitespaces), forKey: "workDomain")
                            peopleStatus = "Saved \(People.listed.count) \(People.listed.count == 1 ? "person" : "people")."
                        } catch {
                            peopleStatus = "Could not save: \(error.localizedDescription)"
                        }
                    }
                    if let peopleStatus { Text(peopleStatus).font(.callout).foregroundStyle(.secondary) }
                }
            } header: {
                Text("People for Teams")
            } footer: {
                Text("\"chat with alex\" opens a Teams chat. Seek looks here first, then at document authors on this Mac. Set a work domain and it will guess first.last@ that domain from a name alone, marking those rows \"guessed address\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcut") {
                Picker("Open Seek", selection: $shortcut) {
                    ForEach(Shortcut.presets, id: \.label) { Text($0.label).tag($0.label) }
                }
                .onChange(of: shortcut) { _, label in
                    if let preset = Shortcut.presets.first(where: { $0.label == label }) {
                        Prefs.shortcut = preset
                        Prefs.notify()
                    }
                }
            }

            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            status = "Could not change login item: \(error.localizedDescription)"
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        if !key.isEmpty {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            savedKey = KeyFile.save(trimmed)
            status = savedKey ? "Key saved." : "Could not save the key."
            key = ""
        }
        Prefs.model = model.trimmingCharacters(in: .whitespaces)
        Prefs.notify()
    }

    private func test() {
        if !key.isEmpty { save() }
        guard let client = Prefs.client else { return }
        testing = true
        status = nil
        Task {
            let started = Date()
            do {
                let response = try await client.ask(state: "Seek connection test: is this message a test?",
                                                    questions: ["test": .noul("Is this message a test?")])
                let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
                status = "Connected to \(response.model) in \(milliseconds) ms."
            } catch {
                status = error.localizedDescription
            }
            testing = false
        }
    }
}
