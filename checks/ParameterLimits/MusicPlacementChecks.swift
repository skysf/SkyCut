import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Music accents through the real tools (production feedback MCP-43; docs/architecture/listening-engine.md section 9,
// docs/architecture/ai-control-mcp.md section 4 item 43). A synthetic AAC piece written here: a pad and a kick every 0.5 s,
// a 2 s stop at 6.0, a big hit at 8.0 that brings the music back, the end at 14.0, silence to 16.0. What each scenario pins:
// - listen file beats=true lists the big hit first in strongest_accents (within a frame), the stop from 6.0 to that hit,
//   ends_at at 14.0;
// - add_clips hit_at without hit lands the strongest accent: start and source_in are set from it, the reply's hit_at is where
//   it landed, and listening to the placed clip finds the strongest accent on hit_at within one frame (the acceptance of
//   MCP-43: "9.66 on 7.30, the accent lands on 7.30 ± 1 frame", here on synthetic music; the real file is on the research Mac);
// - hit + hit_at lands that source second; a source_in that would start before 0:00 moves later and says why;
// - a hit outside the window, hit without hit_at and an image with hit_at change nothing;
// - a generated music job's get_job carries the same measurement (AIGeneratedMusicReport).
@MainActor enum MusicPlacementChecks {
    static let hit = 8.0
    static let frame = 1.0 / 24

    static func run(_ f: ParameterFixture, root: URL, require: @escaping (Bool, String) -> Void) async {
        do {
            let file = root.appendingPathComponent("music-accents.m4a")
            try writePiece(to: file)
            let checks = Context(f: f, file: file.path, image: root.appendingPathComponent("image.png").path, require: require)
            try await checks.listenToFile()
            try await checks.strongestOnHitAt()
            try await checks.namedHit()
            try await checks.sourceInMovesLater()
            try await checks.refusals()
            try await checks.generatedMusicJob(file)
            f.reset()
            print("PASS: music accents, stops and hit_at placement through listen and add_clips (MCP-43)")
        } catch {
            require(false, "music placement checks threw \(error)")
        }
    }

    /// 16 s at 48 kHz stereo, AAC (the sound effects' writer: a compressed file like the generated music).
    static func writePiece(to url: URL) throws {
        let rate = 48_000.0
        var random = SeededRandom(seed: 11)
        func noise() -> Float { Float(Double(random.next() >> 11) / Double(1 << 53)) * 2 - 1 }
        var samples = [Float](repeating: 0, count: Int(16 * rate))
        func add(_ time: Double, _ seconds: Double, _ wave: (Double) -> Float) {
            let first = Int((time * rate).rounded())
            for offset in 0..<Int(seconds * rate) where first + offset < samples.count { samples[first + offset] += wave(Double(offset) / rate) }
        }
        func kick(_ time: Double, _ amplitude: Float) {
            add(time, 0.25) { x in amplitude * Float(sin(2 * .pi * (55 + 65 * exp(-x * 30)) * x) * exp(-x * 14)) }
            add(time, 0.03) { x in amplitude * 0.3 * noise() * Float(exp(-x * 90)) }
        }
        for (from, to) in [(0.0, 6.0), (hit, 14.0)] {
            add(from, to - from) { x in Float(0.03 * sin(2 * .pi * 220 * x) + 0.03 * sin(2 * .pi * 277.2 * x)) }
        }
        for beat in stride(from: 0.5, to: 5.6, by: 0.5) { kick(beat, 0.5) }
        kick(hit, 0.95)
        add(hit, 0.6) { x in 0.25 * noise() * Float(exp(-x * 6)) }
        for beat in stride(from: hit + 0.5, to: 13.6, by: 0.5) { kick(beat, 0.5) }
        let scaled = samples.map { $0 * 0.7 }  // the big hit stays under full scale
        try AIAudioFileWriter.writeSoundEffect([scaled, scaled], sampleRate: rate, to: url)
    }

    @MainActor struct Context {
        let f: ParameterFixture
        let file: String
        let image: String
        let require: (Bool, String) -> Void

        func near(_ value: JSONValue?, _ expected: Double, _ tolerance: Double) -> Bool {
            guard let number = value?.doubleValue else { return false }
            return abs(number - expected) <= tolerance
        }

        func add(_ clip: [String: JSONValue]) async throws -> JSONValue {
            let result = try await AITimelineTools.addClips(AIToolArguments(["clips": [.object(clip)]]), f.project)
            return result.payload["added"]?.arrayValue?.first ?? .null
        }

        func listenToFile() async throws {
            f.reset()
            let result = try await AIListenTool.listen(AIToolArguments(["file": .string(file), "beats": true]), f.project)
            let payload = result.payload
            require(near(payload["strongest_accents"]?.arrayValue?.first, MusicPlacementChecks.hit, frame),
                    "listen beats=true: the hit after the stop is the strongest accent (\(payload["strongest_accents"] ?? .null))")
            require((payload["accents"]?.arrayValue?.count ?? 0) >= 20, "listen beats=true lists the kicks as accents")
            let stop = payload["stops"]?.arrayValue?.first?.arrayValue
            require(near(stop?.first, 6.0, 0.15) && near(stop?.last, MusicPlacementChecks.hit, frame),
                    "listen beats=true: the stop runs from 6.0 to the hit that brings the music back (\(payload["stops"] ?? .null))")
            require(near(payload["ends_at"], 14.0, 0.2), "listen beats=true: ends_at is where the music ends (\(payload["ends_at"] ?? .null))")
            require(payload["tempo_bpm"] != nil, "the beat is still there")
            require(f.project.state == f.before && !f.project.effectiveUndoManager!.canUndo, "listen changes nothing")
        }

        /// The acceptance: the strongest accent lands on hit_at, measured back on the timeline within one frame.
        func strongestOnHitAt() async throws {
            f.reset()
            let entry = try await add(["file": .string(file), "hit_at": 3])
            require(near(entry["start"], 0, 0.0005) && near(entry["hit_at"], 3, 0.0005), "hit_at 3 without hit: the clip starts at 0, hit_at 3 (\(entry))")
            require(near(entry["hit"], MusicPlacementChecks.hit, frame), "the hit is the strongest accent (\(entry["hit"] ?? .null))")
            guard let id = entry["id"]?.stringValue,
                  let clip = f.project.state.clip(with: try AIShortIDs(state: f.project.state).resolve(id)) else {
                return require(false, "the placed clip is on the timeline")
            }
            require(abs(clip.sourceStart - ((entry["hit"]?.doubleValue ?? 0) - 3)) < 0.001, "source_in = hit − hit_at (\(clip.sourceStart); the reply rounds to ms)")
            let heard = try await AIListenTool.listen(AIToolArguments(["clip_id": .string(id), "beats": true]), f.project)
            require(near(heard.payload["strongest_accents"]?.arrayValue?.first, 3, frame),
                    "listening to the placed clip finds its strongest accent on hit_at within a frame (\(heard.payload["strongest_accents"] ?? .null))")
            f.project.effectiveUndoManager!.undo()
            require(f.project.state == f.before, "one undo step removes it")
        }

        func namedHit() async throws {
            f.reset()
            let entry = try await add(["file": .string(file), "hit": .number(MusicPlacementChecks.hit), "hit_at": 12, "track": "A1"])
            require(near(entry["start"], 4, 0.0005) && near(entry["hit_at"], 12, 0.0005) && near(entry["hit"], MusicPlacementChecks.hit, 0.0005),
                    "hit 8 on hit_at 12: start 4 (\(entry))")
        }

        /// source_in 1 with hit 8 on 2 would start at -5: source_in moves to 6 and the adjustment says why.
        func sourceInMovesLater() async throws {
            f.reset()
            let entry = try await add(["file": .string(file), "source_in": 1, "hit": .number(MusicPlacementChecks.hit), "hit_at": 2])
            require(near(entry["start"], 0, 0.0005) && near(entry["applied"]?["source_in"], 6, 0.0005) && near(entry["hit_at"], 2, 0.0005),
                    "a source_in that would start before 0:00 moves later, the hit still on hit_at (\(entry))")
            require(entry["adjustments"]?.arrayValue?.contains { $0["parameter"] == "source_in" && $0["reason"] == .string(AIClipHit.reason) } == true,
                    "the moved source_in is an adjustment for the hit (\(entry["adjustments"] ?? .null))")
        }

        func refusals() async throws {
            let refused: [([String: JSONValue], String)] = [(["file": .string(file), "hit": 99, "hit_at": 1], "a hit past the source"),
                                                            (["file": .string(file), "hit": 2], "hit without hit_at"),
                                                            (["file": .string(image), "hit_at": 1], "an image with hit_at")]
            for (clip, what) in refused {
                f.reset()
                do {
                    _ = try await add(clip)
                    require(false, "\(what) is refused")
                } catch let error as AIToolError {
                    if what == "a hit past the source" {
                        require(error.details["status"] == "invalid_parameter" && error.details["parameter"] == "hit", "\(what): invalid hit (\(error.details))")
                    }
                }
                require(f.project.state == f.before && !f.project.effectiveUndoManager!.canUndo, "\(what) changes nothing")
            }
        }

        /// get_job of a generated music job: the listen measurement of its file, with the way to place it.
        func generatedMusicJob(_ url: URL) async throws {
            f.reset()
            guard case .object(let music) = await AIGeneratedMusicReport.measure(url, project: f.project) else {
                return require(false, "a generated music job's measurement is an object")
            }
            let listened = try await AIListenTool.listen(AIToolArguments(["file": .string(file), "beats": true]), f.project).payload
            for key in ["accents", "strongest_accents", "stops", "ends_at", "tempo_bpm", "curve", "peak_db"] {
                require(music[key] != nil && music[key] == listened[key], "get_job's music.\(key) is what listen beats=true says")
            }
            require(music["listened_to"] == nil && music["placing"] != nil, "no path twice; says how to place it")
        }
    }
}
