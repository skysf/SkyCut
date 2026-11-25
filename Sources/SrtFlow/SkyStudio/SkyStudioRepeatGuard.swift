import Foundation

// MARK: - Identical paid requests in a row: counted per project + tool, the 5th asks the user once (user, 2026-11-25)
//
// What it covers: an AI tool that submits a paid Sky Studio job (generate_media and its image operations, upscale_clip,
// change_voice, add_voiceover with a Sky Studio voice, manage_voices design, manage_characters create / headshot) reports here each
// request it really started, with the identity of the resolved request (SkyStudioRequestDigest: what SkyCut sends to Sky Studio,
// local files by their bytes; never the tool's raw arguments, never the idempotency_key). A run is the identical requests to one
// tool in one project (this opening of it, `documentGeneration`) one after another: a call to another tool does not break it, a
// different request to that tool starts a new run. An identical request sent again is a deliberate new version, a new paid job
// (user, 2026-11-25); SkyCut only guards against a runaway loop:
// - from the 2nd request of a run on, the tool's result says which one it is and its credits (SkyStudioRepeatWords.fields);
// - the 5th stops before anything is submitted and asks once through the gate's confirm flow, in every permission mode, as one
//   question with the draft question when SkyCut asks that anyway (SkyStudioJobGate); a yes covers the rest of the run, a no
//   starts nothing and charges nothing.
// Only what was started counts: a quote, a question, a refusal or a call with an earlier job's idempotency_key (that job, #554)
// neither counts nor breaks a run. In memory for this run of the App. Panels are never counted (a person's click is deliberate).
// No money threshold: the daily credit limit already caps expensive loops.
// What it does not cover: asking (SkyStudioJobGate), the words (SkyStudioRepeatWords), identities (SkyStudioRequestDigest).
// Rules: docs/architecture/sky-studio-jobs.md, "Identical paid requests in a row".

@MainActor
final class SkyStudioRepeatGuard {
    static let shared = SkyStudioRepeatGuard()

    /// The request of a run that asks the user first (user, 2026-11-25: 「如果连续5次是一样的，就停下，询问用户」).
    nonisolated static let asksAt = 5

    /// The AI tools whose identical paid requests are counted.
    enum Tool: String, CaseIterable, Sendable {
        case generateMedia = "generate_media"
        case upscaleClip = "upscale_clip"
        case changeVoice = "change_voice"
        case addVoiceover = "add_voiceover"
        case manageVoices = "manage_voices"
        case manageCharacters = "manage_characters"
    }

    /// Where a request would stand in its run if it starts now.
    struct Check: Equatable, Sendable {
        let tool: Tool
        /// The project's opening (`documentGeneration`, never reused in the App's run).
        let project: Int
        let identity: String
        /// 1 for a new request (or a different one); 5 asks first.
        let number: Int
        /// The user said yes for this run: the rest of it goes through without asking.
        let approved: Bool
        /// Which run (a new one for each different request): a yes answers only the run it was asked for.
        let run: Int
        /// The quote for this request (one request costs the same each time).
        let credits: Double

        /// Stops before anything is submitted and asks the user.
        var asks: Bool { number >= SkyStudioRepeatGuard.asksAt && !approved }
        /// The tool's result says which identical request this is.
        var isRepeat: Bool { number >= 2 }
        /// The same request with the user's yes (a check that asked and then went through was answered yes).
        var agreed: Check { Check(tool: tool, project: project, identity: identity, number: number, approved: true, run: run, credits: credits) }
    }

    private struct Run: Equatable {
        var identity: String
        var started: Int
        var approved: Bool
        var serial: Int
    }

    private var runs: [String: Run] = [:]
    private var serials = 0

    /// The checks make their own; the App uses `shared`.
    init() {}

    func check(_ tool: Tool, project: Int, identity: String, credits: Double) -> Check {
        guard let run = runs[Self.key(tool, project)], run.identity == identity else {
            return Check(tool: tool, project: project, identity: identity, number: 1, approved: false, run: 0, credits: credits)
        }
        return Check(tool: tool, project: project, identity: identity, number: run.started + 1, approved: run.approved,
                     run: run.serial, credits: credits)
    }

    /// The user said yes to this request at its question: the rest of its run goes through without asking.
    func approve(_ check: Check) {
        let key = Self.key(check.tool, check.project)
        guard var run = runs[key], run.identity == check.identity, run.serial == check.run else { return }
        run.approved = true
        runs[key] = run
    }

    /// A paid job was started for this request: it is the next of its run, or the first of a new run (a different request).
    func started(_ check: Check) {
        let key = Self.key(check.tool, check.project)
        if var run = runs[key], run.identity == check.identity {
            run.started += 1
            runs[key] = run
        } else {
            serials += 1
            runs[key] = Run(identity: check.identity, started: 1, approved: false, serial: serials)
        }
    }

    private static func key(_ tool: Tool, _ project: Int) -> String { "\(project):\(tool.rawValue)" }
}
