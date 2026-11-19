import AppKit
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Times no tool can mean, through the real router on a real background project (docs/bugfixes/2026-11-19-huge-times-in-timeline-tools.md).
// Every time parameter of every catalog tool (MCPTimeArguments, kept whole by TimeBoundCatalog) gets 10^20 s, the largest finite
// number, a negative time, half a second past the day, and NaN / ±infinity / 10^300 written as text. Each call must be a plain
// refusal (invalid_parameter naming that parameter, the 0–86,400 range and a suggestion) that leaves no edit, no undo step, no job
// and no file. Before the bound such calls were stored with an undo step (the next export or look then quit SkyCut), clamped
// silently, or refused inside an undo group that stayed behind as an empty undo step.
@MainActor enum TimeBoundChecks {
    static let values: [JSONValue] = [1e20, .number(.greatestFiniteMagnitude), -1, .number(MCPTimeArguments.maximumSeconds + 0.5),
                                      "nan", "inf", "-infinity", "1e300"]

    /// One assertion: whether it held and what it says.
    typealias Check = (ok: Bool, message: String)

    static func run(root: URL, require: (Bool, String) -> Void) async throws {
        var failed = 0
        func record(_ checks: [Check]) {
            for check in checks {
                if !check.ok { failed += 1 }
                require(check.ok, check.message)
            }
        }
        let numbers = MCPToolName.allCases.map { TimeBoundCatalog.numberPaths(TimeBoundCatalog.schema(for: $0)).count }.reduce(0, +)
        record([(numbers >= 200, "walked every number in the catalog (\(numbers))")]
               + MCPToolName.allCases.flatMap(TimeBoundCatalog.problems).map { (false, $0) })
        let fixture = try await TimeBoundFixture(root: root.appendingPathComponent("time-bounds"))
        defer { fixture.close() }
        var calls = 0, paths = 0
        for tool in MCPToolName.allCases {
            for path in MCPTimeArguments.paths(for: tool) {
                paths += 1
                let base = fixture.base(tool, path)
                record(([0, .number(MCPTimeArguments.maximumSeconds), "12.5"] as [JSONValue]).map { inside in
                    (MCPTimeArguments.firstOutOfBounds(tool: tool, arguments: TimeBoundCatalog.setting(inside, at: path, in: base)) == nil,
                     "\(tool.rawValue) \(path)=\(inside.encodedString()) is inside the supported timeline")
                })
                for value in values {
                    record(await refuses(tool, path: path, value: value, base: base, fixture))
                    calls += 1
                }
            }
        }
        record([(paths >= 60 && calls == paths * values.count, "walked every listed time (\(paths) paths, \(calls) calls)")])
        record(await boundaryStillWorks(fixture))
        print(failed == 0
            ? "PASS: \(calls) calls with times no tool can mean on \(paths) time parameters: plain refusals, no edit, undo step, job or file"
            : "FAIL: times no tool can mean: \(failed) of the checks above failed")
    }

    private static func refuses(_ tool: MCPToolName, path: String, value: JSONValue, base: JSONValue, _ f: TimeBoundFixture) async -> [Check] {
        let label = "\(tool.rawValue) \(TimeBoundCatalog.concrete(path))=\(value.encodedString())"
        let before = f.project.state
        let files = f.files()
        let jobs = AIJobs.shared.running.count
        let reply = await f.call(tool, TimeBoundCatalog.setting(value, at: path, in: base))
        let text = reply["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        let payload = try? JSONValue.decode(Data(text.utf8))
        let named = payload?["parameter"]?.stringValue == TimeBoundCatalog.concrete(path)
        let range = payload?["allowed"]?["minimum"]?.doubleValue == 0
            && payload?["allowed"]?["maximum"]?.doubleValue == MCPTimeArguments.maximumSeconds
        var checks: [Check] = [(reply["isError"] == true && payload?["status"] == "invalid_parameter" && named && range
                                && payload?["suggested"] != nil && payload?["retryable"] == false && payload?["changed"] == false
                                && payload?["guide"]?.stringValue == "skycut_guide topic=\(tool.rawValue)",
                                "\(label): a plain invalid_parameter refusal naming it, with 0–86400 and a suggestion: \(text.prefix(240))")]
        if let list = path.range(of: "[]").map({ String(path[..<$0.lowerBound]) }) {
            checks.append((payload?["batch"]?.stringValue == list && payload?["index"] == 0, "\(label): names its list and entry"))
        }
        let untouched = f.project.state == before && !f.undo.canUndo
        checks.append((untouched, "\(label): no edit and no undo step"))
        checks.append((AIJobs.shared.running.count == jobs, "\(label): starts no job"))
        checks.append((f.files() == files, "\(label): writes no file"))
        if !untouched { f.reset(before) }
        return checks
    }

    /// Legal times still reach the tools: a seek to the last second of the day lands on the end, a text at it is added and one
    /// undo takes it away; get_timeline reports the range.
    private static func boundaryStillWorks(_ f: TimeBoundFixture) async -> [Check] {
        let before = f.project.state
        let seek = await f.call(.seek, ["time": .number(MCPTimeArguments.maximumSeconds)])
        var checks: [Check] = [(seek["isError"] != true && abs(f.project.clock.time - before.duration) < 0.001, "seek to 86400 s lands on the end")]
        let text = await f.call(.setText, ["text": "Day", "start": .number(MCPTimeArguments.maximumSeconds), "duration": 1])
        let added = f.project.state.textOverlays.first { abs($0.timelineStart - MCPTimeArguments.maximumSeconds) < 0.001 }
        checks.append((text["isError"] != true && added != nil && f.undo.canUndo, "a text at 86400 s is added with one undo step"))
        f.undo.undo()
        checks.append((f.project.state == before && !f.undo.canUndo, "one undo takes the 86400 s text away"))
        f.reset(before)
        let timeline = await f.call(.getTimeline, [:])
        let summary = try? JSONValue.decode(Data((timeline["content"]?.arrayValue?.first?["text"]?.stringValue ?? "").utf8))
        checks.append((summary?["edit_limits"]?["time"] == ["minimum": 0, "maximum": .number(MCPTimeArguments.maximumSeconds), "policy": "reject"],
                       "get_timeline edit_limits reports time 0–86400, reject"))
        return checks
    }
}

/// A background project of its own session: two V1 clips, a tone on A1, a text, a shape, a filter and a subtitle, all made with
/// the tools themselves. Calls go through MCPArgumentCheck and AIToolRouter.routeValidated, as the router runs them after the
/// license gate (no account in this isolated bundle).
@MainActor final class TimeBoundFixture {
    let project: VideoEditProject
    let folder: URL
    let session = "time-bounds-\(UUID().uuidString)"
    private let file: JSONValue, tone: JSONValue, missing: JSONValue
    private var ids: [String: JSONValue] = [:]

    var undo: UndoManager { project.ownUndoManager }

    init(root: URL) async throws {
        let work = root.deletingLastPathComponent()
        folder = root
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = work.appendingPathComponent("source.mp4")
        file = .string(source.path)
        tone = .string(work.appendingPathComponent("tone.m4a").path)
        missing = .string(work.appendingPathComponent("missing-j1.m4a").path)
        let ffmpeg = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]!)
        let info = try await MediaProbe.probe(url: source, ffmpeg: ffmpeg).get()
        guard let made = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent("times.skycut"), placement: .background) else {
            throw AIToolError(OpenProjects.shared.failure ?? "Could not create the time-bounds project")
        }
        project = made
        var state = TimelineState()
        state.mainMagnet = false
        state.mainClips = [EditClip(sourceURL: source, sourceDuration: 2, timelineStart: 0, info: info),
                           EditClip(sourceURL: source, sourceDuration: 2, timelineStart: 2, info: info)]
        project.restoreTimeline(state)
        AIProjectSessions.shared.own(project, session: session, client: "TimeBoundCheck")
        AISession.shared.setViewMode(.background, for: project)
        AIReadGrants.shared.remember([work])
        for (tool, arguments) in [(MCPToolName.setText, ["text": "Hello", "start": 0.5, "duration": 1] as JSONValue),
                                  (.setShape, ["kind": "rectangle", "start": 0.5, "duration": 1]),
                                  (.setFilter, ["preset": "tealOrange", "start": 0, "duration": 1]),
                                  (.editSubtitles, ["add": [["start": 0.2, "end": 1.2, "text": "hello there"]]]),
                                  (.addClips, ["clips": [["file": tone, "track": "A1", "start": 0]]])] {
            let reply = await call(tool, arguments)
            guard reply["isError"] != true else { throw AIToolError("time-bounds fixture: \(tool.rawValue) failed: \(reply)") }
        }
        let short = AIShortIDs(state: project.state)
        ids["clip"] = .string(short.short(project.state.mainClips[0].id))
        ids["audio"] = .string(short.short(project.state.audioTracks[0].clips[0].id))
        ids["text"] = .string(short.short(project.state.textOverlays[0].id))
        ids["shape"] = .string(short.short(project.state.shapes[0].id))
        let subtitles = await call(.getSubtitles, [:])
        let cues = try? JSONValue.decode(Data((subtitles["content"]?.arrayValue?.first?["text"]?.stringValue ?? "").utf8))
        guard let cue = cues?["original"]?["lines"]?.arrayValue?.first?["id"] else { throw AIToolError("time-bounds fixture: no subtitle id") }
        ids["cue"] = cue
        undo.removeAllActions()
    }

    func close() { _ = OpenProjects.shared.close(project) }

    func reset(_ state: TimelineState) {
        project.restoreTimeline(state)
        undo.removeAllActions()
    }

    func files() -> [String] {
        (FileManager.default.subpaths(atPath: folder.path) ?? []).filter { !$0.hasSuffix(".skycut") }.sorted()
    }

    /// One call as the router runs it after its license gate.
    func call(_ tool: MCPToolName, _ arguments: JSONValue) async -> JSONValue {
        var fields = arguments.objectValue ?? [:]
        if tool.takesProject { fields["project"] = .string(project.shortID) }
        let request = MCPBridge.Request(tool: tool.rawValue, arguments: .object(fields), client: "TimeBoundCheck",
                                        project: AIProjectSessions.shared.stamp(project), session: session)
        if let problem = MCPArgumentCheck.problem(tool: tool, arguments: .object(fields)) {
            return MCPBridge.textResult("argument check: " + problem, isError: true)
        }
        return await AIToolRouter.shared.routeValidated(request, tool: tool, begin: { true }).result
    }

    /// A call that would reach the tool if its time were fine. Tools that would start work, read a key or a model if the bound
    /// were missing get a missing file, an unknown voice or id (no Sky Studio key here either), so a run without the bound stops
    /// early inside the tool and still fails these checks.
    func base(_ tool: MCPToolName, _ path: String) -> JSONValue {
        let clip = ids["clip"]!, audio = ids["audio"]!
        switch tool {
        case .look:
            if path == "from" { return ["clip_id": clip, "shots": true, "image": false] }
            return path.hasPrefix("source") ? ["file": file, "size": "small", "image": false] : ["size": "small", "image": false]
        case .listen: return path.hasPrefix("source") ? ["file": tone] : [:]
        case .transcribe: return ["file": missing]
        case .addVoiceover: return ["lines": [["text": "hello"]], "voice": "NoSuchVoiceJ1"]
        case .syncVoiceover: return ["paragraphs": [["from": 0, "to": 1, "voiceover_id": "unknown"]], "language": "en"]
        case .manageVoices: return ["action": "create", "name": "J1", "file": missing]
        case .recordScreen: return ["action": "start"]
        case .generateMedia: return ["kind": "video", "prompt": "a wave"]
        case .addClips:
            switch path {
            case "clips[].hit": return ["clips": [["file": tone, "track": "A2", "hit_at": 1]]]
            case "clips[].hit_at": return ["clips": [["file": tone, "track": "A2"]]]
            case "clips[].sound_effect.duration": return ["clips": [["sound_effect": ["preset": "whoosh"], "start": 1]]]
            default: return ["clips": [["file": file]]]
            }
        case .editClip: return clipBase(path, clip: clip, audio: audio)
        case .editClips: return ["clips": [clipBase(String(path.dropFirst("clips[].".count)), clip: clip, audio: audio)]]
        case .setKeyframes:
            let point: JSONValue = path.hasPrefix("position") ? ["x": 0.5, "y": 0.5] : path.hasPrefix("rotation") ? ["degrees": 10] : ["value": 0.5]
            return .object(["clip_id": clip, String(path.prefix { $0 != "[" }): [point]])
        case .freezeFrame: return path == "duration" ? ["time": 0.5] : [:]
        case .cutSpeech:
            if path == "pause_left" { return ["clip_id": clip, "remove_pauses": 0.6] }
            if path == "remove_pauses" { return ["clip_id": clip] }
            return .object(["clip_id": clip, String(path.prefix { $0 != "[" }): [["start": 0.2, "end": 1]]])
        case .duplicateItems: return ["ids": [clip]]
        case .setTransition: return ["after_clip_id": clip, "type": "crossFade"]
        case .setText: return textBase(path)
        case .setTexts: return ["texts": [textBase(String(path.dropFirst("texts[].".count)))]]
        case .setMotion: return ["template": "official:box_to_earth"]
        case .setShape: return shapeBase(path)
        case .setShapes: return ["shapes": [shapeBase(String(path.dropFirst("shapes[].".count)))]]
        case .setFilter: return ["preset": "tealOrange"]
        case .editSubtitles:
            return path.hasPrefix("add") ? ["add": [["start": 1, "end": 2, "text": "x"]]] : ["changes": [["id": ids["cue"]!]]]
        case .getJob: return ["job_id": "j-none"]
        default: return [:]
        }
    }

    private func clipBase(_ path: String, clip: JSONValue, audio: JSONValue) -> JSONValue {
        switch path {
        case "fade_in", "fade_out": return ["clip_id": audio]
        case "entrance_duration": return ["clip_id": clip, "entrance": "fade"]
        case "exit_duration": return ["clip_id": clip, "exit": "fade"]
        case "markers[].time": return ["clip_id": clip, "markers": [["note": "m"]]]
        case "volume_curve[].time": return ["clip_id": audio, "volume_curve": [["db": -6]]]
        default: return ["clip_id": clip]
        }
    }

    private func textBase(_ path: String) -> JSONValue {
        switch path {
        case "hit_at": return ["motion_preset": "focus_pull", "text": "Hi"]
        case "animation_in_duration": return ["text_id": ids["text"]!, "animation_in": "fade"]
        case "animation_out_duration": return ["text_id": ids["text"]!, "animation_out": "fade"]
        case "number.delay", "number.seconds": return ["number": ["from": 0, "to": 10]]
        default: return ["text": "Hi"]
        }
    }

    private func shapeBase(_ path: String) -> JSONValue {
        switch path {
        case "animation_in_duration": return ["shape_id": ids["shape"]!, "animation_in": "fade"]
        case "animation_out_duration": return ["shape_id": ids["shape"]!, "animation_out": "fade"]
        default: return ["kind": "rectangle"]
        }
    }
}
