import SwiftUI
import TinyMuesliCore

/// Onboarding: the languages spoken in your meetings (any the transcribers offer, in the variant you
/// speak), and which transcriber suits them. One language: Apple's, on this Mac. Several: a
/// multilingual one (a plugin, installed or found on GitHub) handles meetings and sentences that mix
/// them; Apple's transcribes one at a time and offers to switch when it hears another of yours.
///
/// Saved as you go: `Settings.spokenLanguages`, and the transcription language (the first chosen, or
/// none for a multilingual transcriber, which detects it). Also opened from Settings › Recording.
struct LanguagesPage: View {
    let model: AppModel

    /// Every language some installed transcriber offers.
    @State private var choices: [LanguageChoice] = []
    /// Chosen tags, in the order chosen; the first is the one Apple starts in.
    @State private var selected: [String] = []
    /// Installed transcribers that handle all of `selected` together.
    @State private var multilingual: [any TranscriptionProvider] = []
    /// Multilingual transcribers found on GitHub, not yet installed.
    @State private var available: [PluginStore.Candidate]?
    @State private var finding = false
    @State private var problem: String?
    @State private var reviewing: PluginStore.Candidate?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Your languages",
                       subtitle: "Which languages are spoken in your meetings? Choose all that apply.")
            VStack(spacing: 12) {
                list
                advice
            }
            .padding(.horizontal, 40)
        }
        .task { await load() }
        .task(id: selected + model.plugins.map(\.id)) {
            multilingual = await TranscriptionProviders.multilingual(for: selected, among: model.transcriptionProviders)
        }
        .sheet(item: $reviewing) { candidate in
            ConsentSheet(candidate: candidate) { agreed in
                reviewing = nil
                guard agreed else { return }
                Task { await install(candidate) }
            }
        }
    }

    // MARK: - Languages

    private var list: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(choices.enumerated()), id: \.element.name) { index, choice in
                    if index > 0 { Divider() }
                    row(choice)
                }
            }
            .padding(14)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: 176)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ choice: LanguageChoice) -> some View {
        let tags = Set(choice.variants.map(\.tag))
        let chosen = selected.first { tags.contains($0) }
        return HStack(spacing: 10) {
            Text(choice.name)
            Spacer()
            if let chosen, choice.variants.count > 1 {
                Picker(choice.name, selection: Binding(
                    get: { chosen },
                    set: { tag in
                        if let index = selected.firstIndex(of: chosen) { selected[index] = tag }
                        apply()
                    }
                )) {
                    ForEach(choice.variants, id: \.tag) { Text($0.name).tag($0.tag) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Toggle(choice.name, isOn: Binding(
                get: { chosen != nil },
                set: { on in
                    if on { selected.append(choice.tag) } else { selected.removeAll { tags.contains($0) } }
                    apply()
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
    }

    // MARK: - Which transcriber

    @ViewBuilder
    private var advice: some View {
        let current = model.transcriptionProvider
        if selected.isEmpty {
            Card {
                Text("Choose at least one: tinyMuesli transcribes in the languages you choose.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if selected.count == 1 {
            Card {
                option(symbol: "lock.fill", title: "Apple transcribes \(Self.name(selected[0])) on your Mac",
                       detail: "Nothing leaves your Mac.", provider: TranscriptionProviders.apple, current: current)
            }
        } else {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(multilingual, id: \.id) { provider in
                        option(symbol: "globe", title: provider.name, detail: detail(provider), provider: provider, current: current)
                        Divider()
                    }
                    if multilingual.isEmpty { find }
                    option(symbol: "lock.fill", title: TranscriptionProviders.apple.name,
                           detail: "One language at a time: starts in \(Self.name(selected[0])) and offers to switch when it hears another of yours.",
                           provider: TranscriptionProviders.apple, current: current)
                }
            }
        }
    }

    /// No multilingual transcriber installed: what one is for, and finding one on GitHub (only when asked).
    @ViewBuilder
    private var find: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                icon("globe")
                VStack(alignment: .leading, spacing: 2) {
                    Text("A multilingual transcriber").font(.headline)
                    Text("Best for meetings, and sentences, that mix languages. These are plugins.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if finding {
                    ProgressView().controlSize(.small)
                } else if available == nil {
                    Button("Find…") { Task { await findPlugins() } }
                }
            }
            if let available {
                if available.isEmpty {
                    Text("None found for these languages yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(available, id: \.manifest.id) { candidate in
                    HStack(spacing: 14) {
                        Color.clear.frame(width: 28, height: 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.manifest.name)
                            Text(candidate.manifest.network == true ? "\(candidate.source.description) · uses the internet" : candidate.source.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Install…") { reviewing = candidate }
                    }
                }
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
        }
        Divider()
    }

    private func option(symbol: String, title: String, detail: String, provider: any TranscriptionProvider,
                        current: any TranscriptionProvider) -> some View {
        HStack(spacing: 14) {
            icon(symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if provider.id == current.id {
                Label("In Use", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fontWeight(.medium)
            } else {
                Button("Use") { use(provider) }
            }
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(.tint)
            .frame(width: 28)
    }

    private func detail(_ provider: any TranscriptionProvider) -> String {
        var parts = [provider.isOnDevice ? "On your Mac" : "Sends meeting audio over the internet"]
        if !provider.transcribesLive { parts.append("transcribes after the meeting") }
        if let problem = provider.setupProblem { parts.append(problem) }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - Doing

    private func load() async {
        var locales: [Locale] = []
        for provider in model.transcriptionProviders {
            locales += await provider.offeredLanguages()
        }
        let offered = Array(Set(locales.map { $0.identifier(.bcp47) })).map(Locale.init(identifier:))
        let all = LanguageChoice.choices(from: offered)
        let initial = model.spokenLanguages.isEmpty ? Self.guess(from: Locale.preferredLanguages, among: all) : model.spokenLanguages
        // Chosen first (as you'd read them), then the rest alphabetically.
        let first = initial.compactMap { tag in all.first { $0.variants.contains { $0.tag == tag } } }
        choices = first + all.filter { !first.contains($0) }
        selected = initial
        apply()
    }

    /// Your macOS languages as transcriber variants: the exact one if offered ("de-CH"), else the
    /// language's usual one.
    static func guess(from preferred: [String], among choices: [LanguageChoice]) -> [String] {
        var tags: [String] = []
        for tag in preferred {
            let code = Locale.Language(identifier: tag).languageCode?.identifier
            guard let choice = choices.first(where: { Locale.Language(identifier: $0.tag).languageCode?.identifier == code }),
                  !tags.contains(where: { t in choice.variants.contains { $0.tag == t } }) else { continue }
            let plain = tag.components(separatedBy: "-u-")[0]
            tags.append(choice.variants.contains { $0.tag == plain } ? plain : choice.tag)
        }
        return tags
    }

    /// Saves the languages, and the transcription language that goes with the transcriber in use.
    private func apply() {
        model.spokenLanguages = selected
        guard let first = selected.first else { return }
        // A multilingual transcriber detects the language itself (`detectLanguage`), with these as hints.
        model.language = selected.count > 1 && model.transcriptionProvider.isMultilingual ? nil : first
    }

    private func use(_ provider: any TranscriptionProvider) {
        model.transcriptionProviderID = provider.id
        apply()
    }

    private func findPlugins() async {
        finding = true
        problem = nil
        defer { finding = false }
        do {
            var found: [PluginStore.Candidate] = []
            let installed = Set(model.plugins.compactMap { $0.install?.githubRepository?.lowercased() })
            let wanted = Set(selected.map { Locale.Language(identifier: $0).languageCode?.identifier ?? $0 })
            for listing in try await model.pluginStore.search() where !installed.contains(listing.id.lowercased()) {
                guard let candidate = try? await model.pluginStore.candidate(.github(owner: listing.owner, repo: listing.repo, ref: nil)),
                      let transcription = candidate.manifest.contributes.transcription, transcription.multilingual == true
                else { continue }
                let offered = Set((transcription.languages ?? PluginTranscriptionProvider.defaultLanguages)
                    .map { Locale.Language(identifier: $0).languageCode?.identifier ?? $0 })
                if wanted.isSubset(of: offered) { found.append(candidate) }
            }
            available = found
        } catch {
            problem = "Couldn't search GitHub: \(error.localizedDescription)"
        }
    }

    private func install(_ candidate: PluginStore.Candidate) async {
        do {
            try await model.install(candidate)
            available?.removeAll { $0.manifest.id == candidate.manifest.id }
            if let provider = model.transcriptionProviders.first(where: { $0.id == candidate.manifest.id }) { use(provider) }
        } catch {
            problem = "Couldn't install \(candidate.manifest.name): \(error.localizedDescription)"
        }
    }

    /// "German (Switzerland)".
    static func name(_ tag: String) -> String {
        Locale.current.localizedString(forIdentifier: tag) ?? tag
    }
}
