import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - listen describe=true: what is in a clip's own sound? (MCP-42 SkyCut half + MCP-44; the job)
//
// What: for a clip whose sound has no known source — a camera's recording, a generated video's own sound — read its sound once
// (AIListenAudioWindow, keeping one channel of samples; at most `maxSeconds`) and describe it per 3 s window:
// - SkyCut's measures and words (SourceSoundDescription: low drone, broadband noise, pitched, rhythmic, speech-like, and the
//   nine numbers behind them);
// - macOS's sound classifier, each label's own score (SoundLabelScores; the strongest few, not just the top one);
// - whether the on-device speech recogniser finds words (an installed model only, never a download; macOS 26).
// Our own voice-overs, library music and effects are not described: where they came from says what they are
// (`AIListenVoicePlan.Provenance`, docs/architecture/listening-engine.md section 3), and the reply says that instead.
// Words, never "music / not music": the classifier calls a low drone "music" (MCP-44), and the traits can't classify either.
// A listen job (AIJobs: App Nap stays off; the mix lane: one at a time); waits up to `inlineSeconds`, else returns the job id.
// Not here: the measures (their files), the result's shape (AIListenSourceReport).

@MainActor
enum AIListenSourceSound {
    /// The longest stretch described in one call (20 windows).
    static let maxSeconds = 60.0
    static let inlineSeconds = 20.0
    /// How long the job's own read may take (the caller's 40 s are for the inline answer, not the job).
    static let readSeconds = 300.0

    private struct Target: Sendable {
        let url: URL
        let from: Double
        let to: Double
        let edges: AIListenAudioWindow.Edges
        let place: AIListenSourceReport.Place
        let head: [String: JSONValue]
    }

    static func listen(_ args: AIToolArguments, _ project: VideoEditProject, from: Double?, to: Double?) async throws -> AIToolResult {
        guard try !(args.bool("mix") ?? false), try !(args.bool("beats") ?? false), try !(args.bool("cuts") ?? false),
              try args.string("voice") == nil else {
            throw AIToolError("describe is its own question: call listen again for mix, voice, beats or cuts.")
        }
        guard try args.stringArray("layers") == nil, try !(args.bool("frames") ?? false) else {
            throw AIToolError("layers and frames go with mix=true; describe examines one clip or file's own sound.")
        }
        let provenance = AIListenVoiceCheck.provenance()
        let target: Target
        if let clipText = try args.string("clip_id") {
            guard try args.string("file") == nil else { throw AIToolError("describe takes clip_id or file, not both.") }
            switch try clipTarget(clipText, project.state, from: from, to: to, provenance: provenance) {
            case .known(let reply): return .ok(.object(reply))
            case .target(let found): target = found
            }
        } else if let path = try args.string("file") {
            guard from == nil, to == nil else { throw AIToolError("from/to are timeline seconds; for part of a file use source_in/source_out.") }
            let url = AIWorkspace.shared.resolve(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("\(path) does not exist.") }
            if let ask = try AIWorkspace.shared.confirmReading([url], verb: "listen to", args: args, project: project) { return ask }
            let sourceIn = try args.double("source_in"), sourceOut = try args.double("source_out")
            let start = max(0, sourceIn ?? 0)
            let duration = try await AIListenAudioWindow.duration(of: url)
            let end = min(duration, sourceOut ?? duration)
            target = try capped(Target(url: url, from: start, to: end, edges: sourceIn == nil && sourceOut == nil ? .sound : .exact,
                                       place: AIListenSourceReport.Place(),
                                       head: ["listened_to": .string(AIWorkspace.shared.display(url))]), field: "source_out")
        } else {
            throw AIToolError("describe needs clip_id (a clip's own sound) or file.")
        }
        return try await run(target)
    }

    private enum ClipOutcome {
        case known([String: JSONValue])
        case target(Target)
    }

    private static func clipTarget(
        _ text: String, _ state: TimelineState, from: Double?, to: Double?, provenance: AIListenVoicePlan.Provenance
    ) throws -> ClipOutcome {
        let ids = AIShortIDs(state: state)
        let id = try ids.resolve(text)
        guard let clip = state.clip(with: id), let slot = state.location(of: id)?.track else { throw AIToolError("\(text) is not a clip.") }
        var head: [String: JSONValue] = ["clip": .string(ids.short(id)), "name": .string(clip.name), "track": .string(AITrackName.name(of: slot))]
        guard clip.hasAudio else { throw AIToolError("\(ids.short(id)) has no sound.") }
        let kind = provenance.kind(of: clip)
        if [.voice, .music, .effects].contains(kind) {
            head["source"] = .string(kind.rawValue)
            head["note"] = .string("SkyCut knows what this is from where it came (\(kind.rawValue): one of its voice-overs, a "
                + "library track or effect, a made sound effect or generated audio), so it is not described. describe is for "
                + "sound with no known source: a camera's or a generated video's own sound.")
            return .known(head)
        }
        guard let window = AIAudioLevels.sourceWindow(of: clip, from: from, to: to) else {
            throw AIToolError("\(ids.short(id)) plays from \(clip.timelineStart) to \(clip.timelineEnd) s, outside from/to.")
        }
        head["source"] = .string(kind.rawValue)
        let place = AIListenSourceReport.Place(start: clip.timelineStart, sourceStart: clip.sourceStart, speed: clip.speed)
        return .target(try capped(Target(url: clip.sourceURL, from: window.from, to: window.to, edges: .sound,
                                        place: place, head: head), field: "to"))
    }

    /// At most `maxSeconds` of sound read: longer is refused with a `to` / `source_out` that fits
    /// (docs/architecture/mcp-edit-parameters.md: refuse, suggest a value that works).
    private static func capped(_ target: Target, field: String) throws -> Target {
        guard target.to > target.from else { throw AIToolError("The end must be after the start, within the file's duration.") }
        guard target.to - target.from > maxSeconds + 1e-6 else { return target }
        let suggested = field == "to" ? target.place.seconds(atSource: target.from + maxSeconds) : target.from + maxSeconds
        let rounded = JSONValue.number((suggested * 1000).rounded(.down) / 1000)
        throw AIToolError(String(format: "describe reads at most %.0f s at a time; use %@=%.3f (or narrow it).", maxSeconds, field, suggested),
                          details: ["status": "invalid_parameter", "parameter": .string(field), "suggested": rounded, "retryable": false])
    }

    // MARK: The job

    private static func run(_ target: Target) async throws -> AIToolResult {
        let work = AIQueuedWork()
        let stop = AIListenSourceStop()
        let job = AIJobs.shared.start(.listen, progress: { nil }, cancel: { work.cancel(stop: { stop.stop() }) })
        work.job = job
        AIWorkQueue.shared.submit(.mix, jobID: job.id) {
            work.started = true
            Task { @MainActor in
                do {
                    let detail = try await describe(target, stop: stop)
                    AIJobs.shared.finish(job, .done, detail: .object(detail))
                } catch {
                    if stop.stopped || error is CancellationError {
                        AIJobs.shared.finish(job, .cancelled, message: "Cancelled; nothing was changed.")
                    } else {
                        AIJobs.shared.finish(job, .failed, message: "Could not describe the sound: \(error.localizedDescription)")
                    }
                }
            }
        }
        await AIJobs.shared.wait(for: job, seconds: inlineSeconds)
        switch job.status {
        case .done: return .ok(job.detail ?? .object([:]))
        case .failed: throw AIToolError(job.message ?? "Could not describe the sound.")
        case .cancelled: throw AIToolError("Cancelled before the description was done.")
        case .running:
            var result: [String: JSONValue] = [
                "job_id": .string(job.id), "status": "running",
                "next_step": "Still describing (the sound classifier warms up on its first use). Wait with get_job; the result is the same."
            ]
            if let position = AIWorkQueue.shared.position(of: job.id) {
                result["status"] = "queued"
                result["queue_position"] = .number(Double(position))
            }
            return .ok(.object(result))
        }
    }

    private static func describe(_ target: Target, stop: AIListenSourceStop) async throws -> [String: JSONValue] {
        let reading = try await AIListenAudioWindow.read(target.url, from: target.from, to: target.to,
                                                         until: Date().addingTimeInterval(readSeconds), edges: target.edges, keepsSamples: true)
        guard let samples = reading.samples else { throw AIToolError("SkyCut could not read this sound.") }
        if stop.stopped { throw CancellationError() }
        let rate = reading.peaks.sampleRate
        let measured = await MediaReadQueue.run(on: MediaReadQueue.analysis) { () -> Result<([SourceSoundDescription.Window], [SoundLabelScores.Window]), Error> in
            Result { (SourceSoundDescription.describe(samples, sampleRate: rate), try SoundLabelScores.classify(samples, sampleRate: rate)) }
        }
        let (traits, labels) = try measured.get()
        if stop.stopped { throw CancellationError() }
        let words = await AIListenSourceWords.words(target.url, from: reading.sourceStart, to: reading.to)
        if stop.stopped { throw CancellationError() }
        var object = target.head
        let report = AIListenSourceReport.json(traits: traits, labels: labels, words: words,
                                               readStart: reading.sourceStart, readEnd: reading.to, place: target.place)
        object.merge(report) { _, new in new }
        return object
    }
}

/// The job's stop flag (set on the main actor, read between steps).
final class AIListenSourceStop: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var stopped: Bool { lock.withLock { flag } }
    func stop() { lock.withLock { flag = true } }
}
