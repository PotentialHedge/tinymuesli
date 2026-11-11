import AppKit
import SwiftUI
import TinyMuesliCore

/// Settings › Plugins: installed plugins with the settings each declares, installing from GitHub (or a
/// local folder), and finding plugins by their GitHub topic. Nothing goes online until you search,
/// install or check for an update.
struct PluginSettingsView: View {
    let model: AppModel
    @State private var source = ""
    @State private var query = ""
    @State private var listings: [PluginStore.Listing]?
    @State private var searching = false
    @State private var busy: String?
    @State private var problem: String?
    @State private var candidate: PluginStore.Candidate?

    var body: some View {
        Form {
            if model.plugins.isEmpty {
                Section {
                    Text("No plugins yet. Plugins add transcription providers, title suggestions, agents that run after each meeting, and items in a meeting's menu.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.plugins) { plugin in
                InstalledPlugin(model: model, plugin: plugin, check: { await review(.updating(plugin)) })
            }
            Section {
                HStack {
                    TextField("Install", text: $source, prompt: Text("owner/repo, a GitHub link or a folder"))
                        .onSubmit { Task { await review(.source(source)) } }
                    Button("Install…") { Task { await review(.source(source)) } }
                        .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty || busy != nil)
                }
                if let busy {
                    HStack { ProgressView().controlSize(.small); Text(busy).foregroundStyle(.secondary) }
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } header: {
                Text("Install a Plugin")
            } footer: {
                Text("You'll see what it does before anything is downloaded. A folder is linked, not copied, for developing a plugin.")
                    .settingsFooter()
            }
            discover
            Section {
                LabeledContent("Plugin settings are also kept in settings.json, which you can edit.") {
                    Button("Open settings.json") { openSettingsFile() }
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .sheet(item: $candidate) { candidate in
            ConsentSheet(candidate: candidate) { agreed in
                self.candidate = nil
                guard agreed else { return }
                Task { await install(candidate) }
            }
        }
    }

    @ViewBuilder private var discover: some View {
        Section {
            HStack {
                TextField("Search", text: $query, prompt: Text("Search plugins"))
                    .onSubmit { Task { await search() } }
                Button(listings == nil ? "Browse" : "Search") { Task { await search() } }
                    .disabled(searching)
            }
            if searching { ProgressView().controlSize(.small) }
            if let listings {
                if listings.isEmpty {
                    Text(query.isEmpty ? "No plugins have been published yet." : "Nothing found.").foregroundStyle(.secondary)
                }
                ForEach(listings) { listing in
                    LabeledContent {
                        let installed = model.plugins.contains { $0.install?.githubRepository?.lowercased() == listing.id.lowercased() }
                        if installed {
                            Text("Installed").foregroundStyle(.secondary)
                        } else {
                            Button("Install…") { Task { await review(.source(listing.id)) } }.disabled(busy != nil)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Link(listing.id, destination: listing.url)
                            Text("★ \(listing.stars)").foregroundStyle(.secondary).font(.caption)
                        }
                        if let description = listing.description { Text(description) }
                    }
                }
            }
        } header: {
            Text("Find Plugins")
        } footer: {
            Text("Lists GitHub repositories with the topic “\(PluginStore.topic)”. Anyone can publish one: install only plugins from people you trust.")
                .settingsFooter()
        }
    }

    private enum Review {
        case source(String)
        case updating(Plugin)
    }

    /// Reads what would be installed and shows it for consent.
    private func review(_ review: Review) async {
        problem = nil
        let parsed: PluginStore.Source?
        switch review {
        case .source(let text): parsed = PluginStore.Source(text)
        case .updating(let plugin): parsed = plugin.install?.githubRepository.flatMap(PluginStore.Source.init)
        }
        guard let parsed else {
            problem = "That isn't a GitHub repository (owner/repo) or a folder."
            return
        }
        busy = "Reading \(parsed.description)…"
        defer { busy = nil }
        do {
            let found = try await model.pluginStore.candidate(parsed)
            if case .updating(let plugin) = review, found.commit == plugin.install?.commit {
                problem = "\(plugin.name) is up to date."
                return
            }
            candidate = found
        } catch {
            problem = error.localizedDescription
        }
    }

    private func install(_ candidate: PluginStore.Candidate) async {
        busy = "Installing \(candidate.manifest.name)…"
        defer { busy = nil }
        do {
            try await model.install(candidate)
            source = ""
        } catch {
            problem = error.localizedDescription
        }
    }

    private func search() async {
        searching = true
        defer { searching = false }
        do {
            listings = try await model.pluginStore.search(query)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func openSettingsFile() {
        let file = PluginSettings.defaultFile
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("{\n}\n".utf8).write(to: file)
        }
        NSWorkspace.shared.open(file)
    }
}

extension PluginStore.Candidate: Identifiable {
    public var id: String { manifest.id + (commit ?? "") }
}

/// One installed plugin: what it is, where it's from, what it adds, and its settings.
private struct InstalledPlugin: View {
    let model: AppModel
    let plugin: Plugin
    let check: () async -> Void
    @State private var confirmRemove = false

    var body: some View {
        let manifest = plugin.manifest
        Section {
            if let description = manifest.description {
                Text(description)
            }
            LabeledContent {
                HStack {
                    if plugin.install?.githubRepository != nil {
                        Button("Check for Update") { Task { await check() } }
                    }
                    Button("Remove…") { confirmRemove = true }
                }
            } label: {
                Text(source)
                Text(contributions)
            }
            if manifest.contributes.agent != nil {
                Toggle(isOn: Binding(
                    get: { model.enabledAgents.contains(plugin.id) },
                    set: { on in if on { model.enabledAgents.insert(plugin.id) } else { model.enabledAgents.remove(plugin.id) } }
                )) {
                    Text("Run After Each Meeting")
                    Text("Gets the meeting's folder once it has been transcribed.")
                }
            }
            ForEach(manifest.settings, id: \.key) { setting in
                SettingRow(key: setting.key, property: setting.property)
            }
            if FileManager.default.fileExists(atPath: plugin.log.path) {
                LabeledContent("What it printed while running.") {
                    Button("Show Log") { NSWorkspace.shared.open(plugin.log) }
                }
                .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(manifest.name)
                if let version = manifest.version { Text(version).foregroundStyle(.secondary) }
                if manifest.network == true {
                    Image(systemName: "network").foregroundStyle(.secondary).help("Says it uses the internet")
                }
            }
        }
        .confirmationDialog("Remove \(manifest.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.remove(plugin) }
        } message: {
            Text("Its secrets are removed from your keychain. Its other settings stay in settings.json.")
        }
    }

    private var source: String {
        guard let install = plugin.install else { return "Installed by hand" }
        if let repository = install.githubRepository {
            return "\(repository)" + (install.commit.map { " · \($0.prefix(7))" } ?? "")
        }
        return "Linked from \(plugin.directory.path)"
    }

    private var contributions: String {
        let c = plugin.manifest.contributes
        var parts: [String] = []
        if c.transcription != nil { parts.append("Transcription (choose it in Recording)") }
        if c.suggestions != nil { parts.append("Suggestions (choose them in Recording)") }
        if c.agent != nil { parts.append("Runs after meetings") }
        if let actions = c.actions, !actions.isEmpty { parts.append("Meeting menu: " + actions.map(\.title).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// A setting as VS Code shows one: a switch, a menu of its values, or a text field. Secrets go to
/// the keychain and are never shown again.
private struct SettingRow: View {
    let key: String
    let property: PluginManifest.Property
    @State private var text = ""
    @State private var hasSecret = false
    @State private var invalid = false
    private let settings = PluginSettings()

    var body: some View {
        Group {
            if property.secret == true {
                LabeledContent {
                    if hasSecret {
                        Button("Remove") { settings.setSecret(key, nil); refresh() }
                    } else {
                        HStack {
                            SecureField(key, text: $text).labelsHidden().frame(width: 170)
                            Button("Save") { settings.setSecret(key, text); text = ""; refresh() }
                                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                } label: { label(hasSecret ? "Saved in your keychain." : nil) }
            } else if property.type == .boolean {
                Toggle(isOn: Binding(
                    get: { settings.value(key, property) == .bool(true) },
                    set: { try? settings.set(key, .bool($0), property: property) }
                )) { label(nil) }
            } else if let options = property.enum {
                Picker(selection: Binding(
                    get: { settings.value(key, property) ?? .null },
                    set: { try? settings.set(key, $0, property: property) }
                )) {
                    if settings.value(key, property) == nil { Text("Not set").tag(JSONValue.null) }
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        Text(property.enumDescriptions?[safe: index] ?? option.display).tag(option)
                    }
                } label: { label(nil) }
            } else {
                LabeledContent {
                    TextField(key, text: $text, prompt: property.default.map { Text($0.display) })
                        .labelsHidden()
                        .frame(width: 200)
                        .foregroundStyle(invalid ? .red : .primary)
                        .onChange(of: text) { save() }
                } label: { label(invalid ? "Must be \(property.type == .string ? "one of its values" : "a \(property.type.rawValue)")" : nil) }
            }
        }
        .onAppear(perform: refresh)
    }

    /// The key as VS Code shows it ("Elevenlabs › Model" style is overkill: the key itself is clearer).
    private func label(_ note: String?) -> some View {
        VStack(alignment: .leading) {
            Text(key.split(separator: ".", maxSplits: 1).last.map(String.init) ?? key)
            if let help = property.help { Text(help).font(.caption).foregroundStyle(.secondary) }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func refresh() {
        if property.secret == true {
            hasSecret = settings.secret(key) != nil
        } else if property.enum == nil, property.type != .boolean {
            // Only what was set: the default shows as the placeholder.
            text = settings.all()[key]?.display ?? ""
        }
    }

    private func save() {
        if text.isEmpty {
            invalid = false
            try? settings.set(key, nil, property: property)
        } else if let value = PluginSettings.parse(text, for: property) {
            invalid = false
            try? settings.set(key, value, property: property)
        } else {
            invalid = true
        }
    }
}

/// What a plugin will be able to do, shown before it's installed (or updated).
struct ConsentSheet: View {
    let candidate: PluginStore.Candidate
    let done: (Bool) -> Void

    var body: some View {
        let manifest = candidate.manifest
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(candidate.replaces == nil ? "Install \(manifest.name)?" : "Update \(manifest.name)?")
                    .font(.title2.bold())
                if let version = manifest.version { Text(version).foregroundStyle(.secondary) }
            }
            if let description = manifest.description { Text(description) }
            HStack(spacing: 4) {
                Text("From")
                if let url = candidate.commitURL {
                    Link("\(candidate.source.description) at \(candidate.commit?.prefix(7) ?? "")", destination: url)
                } else {
                    Text(candidate.source.description)
                }
                if let publisher = manifest.publisher { Text("by \(publisher)") }
            }
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("It will be able to:").bold()
                ForEach(abilities, id: \.self) { Label($0, systemImage: "checkmark.circle").labelStyle(.titleAndIcon) }
                if manifest.network == true {
                    Label("Send what it gets over the internet (it says it uses the network)", systemImage: "network")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("It runs:").bold()
                ForEach(manifest.commands, id: \.what) { item in
                    Text("\(item.what): ").foregroundStyle(.secondary)
                        + Text(item.command.joined(separator: " ")).font(.system(.body, design: .monospaced))
                }
            }
            if !candidate.missingPrograms.isEmpty {
                Label("Needs \(candidate.missingPrograms.joined(separator: ", ")), which isn't installed. Install it first, or the plugin won't run.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("A plugin is a program that runs as you, so it can do anything your account can (but not record from your microphone or system audio with tinyMuesli's permission). Only install plugins from people you trust; you can read its code at the link above.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { done(false) }.keyboardShortcut(.cancelAction)
                Button(candidate.replaces == nil ? "Install" : "Update") { done(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var abilities: [String] {
        let c = candidate.manifest.contributes
        var list: [String] = []
        if c.transcription != nil {
            list.append(c.transcription?.live == true
                        ? "Hear your meetings while they're recorded, when you choose it for transcription"
                        : "Get each meeting's audio after it ends, when you choose it for transcription")
        }
        if c.suggestions != nil { list.append("Read each transcript, when you choose it for suggestions") }
        if c.agent != nil { list.append("Read and change each meeting's folder after it's transcribed (you can turn this off)") }
        for action in c.actions ?? [] { list.append("Read and change a meeting when you choose “\(action.title)” in its menu") }
        return list
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
