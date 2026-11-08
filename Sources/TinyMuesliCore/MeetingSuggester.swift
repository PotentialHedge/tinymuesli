import Foundation
import FoundationModels
import NaturalLanguage

/// What Apple's on-device model suggests for a meeting, saved next to the transcript as
/// `suggestions.json`. Only suggestions: nothing is renamed until the user (or their agent) says so.
public struct MeetingSuggestions: Codable, Sendable, Equatable {
    /// A speaker someone spoke to by name ("thanks, Ann" followed by Speaker 2 answering).
    public struct SpeakerName: Codable, Sendable, Equatable {
        /// The label in the transcript when this was suggested, e.g. "Speaker 2".
        public var speaker: String
        public var name: String
        /// Where the name was said, e.g. "Okay, Ann, do you want to present?".
        public var quote: String
    }

    public var title: String?
    public var tags: [String]
    public var speakers: [SpeakerName]
    public var created: Date

    public static func load(folder: URL) -> MeetingSuggestions? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(MeetingFiles.suggestions)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingSuggestions.self, from: data)
    }

    public func save(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: folder.appendingPathComponent(MeetingFiles.suggestions), options: .atomic)
    }
}

/// Asks Apple's on-device model (Apple Intelligence) for a meeting's title, tags and speaker names.
///
/// The model sees about 4,000 tokens at a time, so a long meeting is summarised in parts and the
/// title made from the summaries. Speaker names come from names said in the meeting: a tagger finds
/// them, the model only decides whether each is said *to* someone (a narrow yes/no it gets right far
/// more often than "who is Ann?"), and the reply's speaker is taken to be them.
public struct MeetingSuggester: Sendable {
    /// Titles of other meetings, to suggest in the same style.
    public var knownTitles: [String]
    /// Tags in use, so a suggested tag that matches one is spelled the same.
    public var knownTags: [String]
    /// The user's name: names like it are the user being spoken to, and the user is always "Me".
    public var myName: String

    public init(knownTitles: [String] = [], knownTags: [String] = [], myName: String = NSFullUserName()) {
        self.knownTitles = knownTitles
        self.knownTags = knownTags
        self.myName = myName
    }

    /// Titles and tags used in the store's other meetings.
    public init(store: MeetingStore, excluding folder: URL? = nil) {
        var titles: [String] = [], tags: [String: Int] = [:]
        for other in store.recentMeetings(limit: 200) where other.standardizedFileURL != folder?.standardizedFileURL {
            let md = other.appendingPathComponent(MeetingFiles.transcript)
            guard let text = try? String(contentsOf: md, encoding: .utf8), let metadata = MeetingMetadata(parsing: text) else { continue }
            if let title = metadata.title, !titles.contains(title) { titles.append(title) }
            for tag in metadata.tags { tags[tag, default: 0] += 1 }
        }
        self.init(knownTitles: Array(titles.prefix(12)),
                  knownTags: tags.sorted { $0.value > $1.value }.map(\.key))
    }

    public static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    public enum Failure: Error, LocalizedError {
        case unavailable
        case notTranscribed
        public var errorDescription: String? {
            switch self {
            case .unavailable: "Apple Intelligence isn't available on this Mac (or its model hasn't downloaded yet)."
            case .notTranscribed: "The meeting hasn't been transcribed yet."
            }
        }
    }

    /// Works out the suggestions and writes them to `suggestions.json`.
    @discardableResult
    public func suggest(folder: URL, log: @Sendable (String) -> Void = { _ in }) async throws -> MeetingSuggestions {
        guard Self.isAvailable else { throw Failure.unavailable }
        let transcript = ChatTranscript.load(folder: folder)
        guard transcript.metadata?.status == .done else { throw Failure.notTranscribed }
        let turns = Self.turns(transcript.messages)
        let labels = turns.isEmpty ? nil : await self.labels(for: turns, log: log)
        let names = await speakerNames(in: turns, log: log)
        let suggestions = MeetingSuggestions(title: labels?.title, tags: labels?.tags ?? [], speakers: names, created: .now)
        try suggestions.save(to: folder)
        return suggestions
    }

    // MARK: - Turns

    struct Turn {
        var speaker: String
        var text: String
    }

    /// Consecutive messages of one speaker joined.
    static func turns(_ messages: [ChatTranscript.Message]) -> [Turn] {
        var turns: [Turn] = []
        for message in messages {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if turns.last?.speaker == message.speaker { turns[turns.count - 1].text += " " + text }
            else { turns.append(Turn(speaker: message.speaker, text: text)) }
        }
        return turns
    }

    // MARK: - Title and tags

    @Generable
    struct Labels {
        @Guide(description: "A short title, 2 to 4 words, like a calendar entry: the team, project or recurring meeting if one is named, else the main topic. No date, no app name.")
        var title: String
        @Guide(description: "1 to 3 short lowercase tags for the meeting's subjects, single words or hyphenated", .count(1...3))
        var tags: [String]
    }

    private static let partTokens = 2_600
    /// More parts than this are sampled evenly: a few minutes a part is plenty for a title.
    private static let maxParts = 10

    private func labels(for turns: [Turn], log: @Sendable (String) -> Void) async -> (title: String, tags: [String])? {
        let parts = await Self.parts(of: turns)
        var material: String
        if parts.count == 1 {
            material = "Transcript:\n" + parts[0]
        } else {
            // Summaries are plain text, so the guardrails can be relaxed for them (transcripts quote
            // all sorts); one part refusing anyway is skipped.
            let summariser = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            var summaries: [String] = []
            for (index, part) in Self.sample(parts, count: Self.maxParts).enumerated() {
                let session = LanguageModelSession(model: summariser, instructions: """
                    Summarise part of a meeting transcript in two sentences: what was discussed, and any \
                    team, project or product names. The transcript comes from speech recognition and has errors.
                    """)
                do {
                    summaries.append(try await session.respond(to: part, options: .init(maximumResponseTokens: 150)).content)
                } catch {
                    log("part \(index + 1): \(error)")
                }
            }
            guard !summaries.isEmpty else { return nil }
            material = "Summary of the meeting, part by part:\n" + summaries.joined(separator: "\n")
        }
        var instructions = "You name meetings, given a transcript (from speech recognition, with errors) or a summary of one. \"Me\" is the user."
        if !knownTitles.isEmpty {
            instructions += " Titles the user gave other meetings, for the style: \(knownTitles.joined(separator: "; "))."
        }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let labels = try await session.respond(to: material, generating: Labels.self, options: .init(sampling: .greedy)).content
            let title = MeetingEditor.clean(labels.title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”.")))
            return title.isEmpty ? nil : (title, normalized(labels.tags))
        } catch {
            log("title: \(error)")
            return nil
        }
    }

    /// Lowercase and hyphenated, spelled like a tag already in use when it's the same one.
    func normalized(_ tags: [String]) -> [String] {
        func key(_ tag: String) -> String {
            tag.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber }
        }
        var result: [String] = []
        for tag in tags {
            var clean = tag.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            clean = clean.split(whereSeparator: \.isWhitespace).joined(separator: "-")
            guard !clean.isEmpty, !Self.fillerTags.contains(clean) else { continue }
            let spelled = knownTags.first { key($0) == key(clean) } ?? clean
            if !result.contains(spelled) { result.append(spelled) }
        }
        return result
    }

    /// Say nothing about a meeting.
    static let fillerTags: Set<String> = ["meeting", "meetings", "call", "discussion", "update", "updates", "sync",
                                          "general", "misc", "chat", "conversation", "planning", "review"]

    /// The transcript as "Speaker: text" lines, cut into parts that fit the model's context.
    static func parts(of turns: [Turn]) async -> [String] {
        var parts: [String] = [], current = ""
        for turn in turns {
            let line = "\(turn.speaker): \(turn.text)\n"
            if !current.isEmpty, await tokens(current + line) > partTokens {
                parts.append(current)
                current = ""
            }
            current += line
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    static func tokens(_ text: String) async -> Int {
        if #available(macOS 26.4, *), let count = try? await SystemLanguageModel.default.tokenCount(for: Prompt(text)) {
            return count
        }
        return text.count / 3
    }

    static func sample<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count else { return items }
        return (0..<count).map { items[$0 * items.count / count] }
    }

    // MARK: - Speaker names

    @Generable
    struct Addressed {
        @Guide(description: "true only if the name is used to speak directly to that person (\"thanks, Anna\", \"Anna, can you…\", \"what do you think, Anna?\"); false if they're only talked about, or it isn't a person's name")
        var addressed: Bool
    }

    /// At most this many model calls for names; a meeting full of names would otherwise take minutes.
    private static let maxNameChecks = 40

    private func speakerNames(in turns: [Turn], log: @Sendable (String) -> Void) async -> [MeetingSuggestions.SpeakerName] {
        let unnamed = Set(turns.map(\.speaker).filter(VoiceMatcher.isPlaceholder))
        guard !unnamed.isEmpty else { return [] }
        let mine = myName.split(separator: " ").map { Self.nameKey(String($0)) }.filter { $0.count > 1 }
        // "Ben" for Benedict too.
        func isMine(_ name: String) -> Bool {
            let key = Self.nameKey(name)
            return mine.contains { $0 == key || (key.count >= 3 && $0.hasPrefix(key)) }
        }
        // name → speaker → the quotes it was said in
        var votes: [String: [String: [String]]] = [:]
        var checks = 0
        for (index, turn) in turns.enumerated() {
            for name in Self.personalNames(in: turn.text) where !isMine(name) && Self.mayBeAddressed(name, in: turn.text) {
                // Spoken to: the next speaker answers, or (at the end of a turn, "thanks, Ann") the previous one spoke.
                let next = turns.indices.contains(index + 1) ? turns[index + 1].speaker : nil
                let previous = index > 0 ? turns[index - 1].speaker : nil
                guard let who = [next, previous].compactMap({ $0 }).first(where: { $0 != turn.speaker }),
                      unnamed.contains(who), checks < Self.maxNameChecks else { continue }
                checks += 1
                let session = LanguageModelSession(instructions: "You read one line of a meeting transcript (from speech recognition, with errors) and say whether a name in it is used to speak directly to someone.")
                do {
                    let line = Self.excerpt(turn.text, around: name)
                    let answer = try await session.respond(to: "Line: \"\(line)\"\nName: \(name)", generating: Addressed.self,
                                                           options: .init(sampling: .greedy))
                    if answer.content.addressed { votes[name, default: [:]][who, default: []].append(line) }
                } catch {
                    log("name \(name): \(error)")
                }
            }
        }
        // Each name to the speaker it was said to most; each speaker the name said to them most.
        // A name split evenly between two speakers is left out.
        var candidates: [(speaker: String, name: String, count: Int, quote: String)] = []
        for (name, bySpeaker) in votes {
            let ranked = bySpeaker.sorted { $0.value.count > $1.value.count }
            guard let best = ranked.first, ranked.count == 1 || ranked[1].value.count < best.value.count else { continue }
            candidates.append((best.key, name, best.value.count, best.value[0]))
        }
        var result: [MeetingSuggestions.SpeakerName] = []
        for candidate in candidates.sorted(by: { $0.count > $1.count }) where !result.contains(where: { $0.speaker == candidate.speaker }) {
            result.append(.init(speaker: candidate.speaker, name: candidate.name, quote: candidate.quote))
        }
        return result.sorted { $0.speaker.localizedStandardCompare($1.speaker) == .orderedAscending }
    }

    /// First names the tagger finds ("Ann Lee" → "Ann"), capitalised as written.
    static func personalNames(in text: String) -> Set<String> {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var names: Set<String> = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName, let first = text[range].split(separator: " ").first,
               first.count > 1, first.first?.isUppercase == true {
                names.insert(String(first))
            }
            return true
        }
        return names
    }

    /// Whether the name stands where you'd say it to someone: on its own between punctuation
    /// ("Okay, Ann, can you…", "…right, Ann?"), at the start or end of the turn, or after a greeting
    /// or thanks. Rules out most names that are only talked about ("Ann said…", "Max Planck").
    static func mayBeAddressed(_ name: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let before = #"(?:^|[,.?!;:]\s*|(?i:\b(?:hi|hey|hello|thanks|thank you|okay|ok|so|yes|yeah|right|and|ciao|bye|danke|merci)\b),?\s+)"#
        let after = #"\s*(?:[,?!.;:]|$)"#
        return text.range(of: before + escaped + after, options: .regularExpression) != nil
    }

    static func nameKey(_ name: String) -> String {
        name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
    }

    /// The sentence-ish stretch around the name, at most ~300 characters.
    static func excerpt(_ text: String, around name: String) -> String {
        guard text.count > 300, let range = text.range(of: name) else { return String(text.prefix(300)) }
        let start = text.index(range.lowerBound, offsetBy: -150, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 150, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + text[start..<end] + (end == text.endIndex ? "" : "…")
    }
}
