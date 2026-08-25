// macOS only: rides the same FoundationModels session identity machinery.
#if os(macOS)
import Foundation
import FoundationModels

/// The session cortex: ONE on-device read of a session's context yields its
/// whole identity - emoji, label, and the proper nouns worth grounding a
/// dictation with. The identity editor consumes emoji+label; dictation
/// consumes keywords. One schema, one model, no second brain.
///
/// Refresh is lazy + cached: `identity(ofPane:)` returns the cached read
/// when it is fresh (same context hash, or under 10 minutes old) and
/// otherwise kicks an async refresh - the NEXT consumer gets the new read.
/// Nothing polls.
@MainActor
enum VigilCortex {
    struct Read {
        let keywords: [String]
        let contextHash: Int
        let at: Date
    }

    static var trace: ((String) -> Void)?

    private static var cache: [String: Read] = [:]
    private static var inFlight: Set<String> = []

    /// The generation target shared with the identity editor. anyOf over the
    /// palette + count guides: the model physically cannot emit an invalid
    /// emoji or a wrong shape.
    @available(macOS 26.0, *)
    @Generable(description: "An identity for a terminal workspace session")
    struct SessionRead {
        @Guide(
            description: "emoji evoking the task", .count(1),
            .element(.anyOf(VigilIdentity.palette)))
        var emoji: [String]
        @Guide(
            description:
                "short evocative name: 2 to 4 lowercase words, no punctuation, the task not the tools"
        )
        var label: String
        @Guide(
            description:
                "up to 6 proper nouns or rare technical terms from the work: names of people, places, projects, commands. Only words a speech recognizer would misspell; no common words",
            .maximumCount(6))
        var keywords: [String]
    }

    @available(macOS 26.0, *)
    static func read(context: String, avoiding: [String] = []) async -> SessionRead? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let lm = LanguageModelSession(
            instructions: """
                You give terminal workspace sessions an identity: one or two \
                emoji plus a short evocative name, 2 to 4 lowercase words, no \
                punctuation. Name the task being done, not the tools. You also \
                extract the words a speech recognizer would need to be told \
                about.
                """)
        var prompt = context
        if !avoiding.isEmpty {
            prompt +=
                "\nAlready suggested, answer with something different: \(avoiding.joined(separator: ", "))"
        }
        return (try? await lm.respond(to: prompt, generating: SessionRead.self))?.content
    }

    /// The cached read for the session owning `pane`, refreshing in the
    /// background when stale. nil = no read yet (fresh session, model
    /// unavailable) - callers proceed ungrounded.
    static func identity(session name: String) -> Read? {
        guard #available(macOS 26.0, *) else { return nil }
        let context = VigilSessionManager.shared.identityContext(name: name)
        let hash = context.hashValue
        if let cached = cache[name],
            cached.contextHash == hash || Date().timeIntervalSince(cached.at) < 600 {
            return cached
        }
        refresh(session: name, context: context, hash: hash)
        return cache[name]
    }

    @available(macOS 26.0, *)
    private static func refresh(session name: String, context: String, hash: Int) {
        guard !inFlight.contains(name) else { return }
        inFlight.insert(name)
        Task {
            defer { inFlight.remove(name) }
            guard let read = await read(context: context) else {
                trace?("cortex: \(name) read failed (model unavailable?)")
                return
            }
            let entry = Read(
                keywords: read.keywords.map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty },
                contextHash: hash, at: Date())
            cache[name] = entry
            trace?("cortex: \(name) keywords=[\(entry.keywords.joined(separator: ", "))]")
        }
    }
}
#endif
