import AppKit
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// add_clips on real App objects: sound effects made on this Mac and audio track names (docs/architecture/ai-control-mcp.md
// section 4 items 2 and 43, docs/architecture/sound-effect-synth.md). Calls go through the tool entry point, so the files, the probe,
// the one undo step and the reply are the production ones. What each scenario pins:
// - a clip that does not fit on the track it asked for opens another new track and says so; it never lands on a track that already
//   had content (MCP-2: two of 13 new_audio effects landed on the music and voice tracks);
// - one call can name A1–A7 and creates the missing tracks, one undo step (MCP-4: "There is no track A2");
// - a made sound's reply carries audible_duration next to the clip's start / end (MCP-8: impact duration 1 is a 2.7 s clip);
// - an in-range volume_db is not an adjustment; +20 is gain_limits (MCP-15: every effect reported a fake gain_limits);
// - every preset can be placed (tick, click), duration is honoured, a failed call leaves no files behind (P5 walkthrough, item 2);
// - short sparkle / shutter render without trapping (found while measuring: they took the whole App down).
// The crash scenario runs last: before its fix it ends this process, and the script reports the non-zero exit.
@MainActor enum AddClipsChecks {
    static func run(_ f: ParameterFixture, root: URL, require: @escaping (Bool, String) -> Void) async {
        let checks = AddClipsChecks.Context(f: f, tone: root.appendingPathComponent("tone.m4a").path, require: require)
        await checks.scenario("MCP-2 crowded new_audio") { try await checks.crowdedNewAudio() }
        await checks.scenario("named track taken") { try await checks.namedTrackTaken() }
        await checks.scenario("MCP-4 A1–A7") { try await checks.sevenTracks() }
        await checks.scenario("MCP-8 audible_duration") { try await checks.audibleDuration() }
        await checks.scenario("MCP-15 volume_db") { try await checks.cleanGain() }
        await checks.scenario("tick and click") { try await checks.shortPresets() }
        await checks.scenario("failed call files") { try await checks.failedCallFiles() }
        await checks.scenario("short sparkle / shutter") { try await checks.noTrap() }
        f.reset()
        print("PASS: add_clips sound effects and audio tracks (MCP-2, MCP-4, MCP-8, MCP-15, tick/click, failed-call files)")
    }

    @MainActor struct Context {
        let f: ParameterFixture
        let tone: String
        let require: (Bool, String) -> Void

        func scenario(_ name: String, _ body: () async throws -> Void) async {
            do { try await body() } catch { require(false, "\(name): threw \(error)") }
        }

        func add(_ clips: [JSONValue]) async throws -> [JSONValue] {
            try await AITimelineTools.addClips(AIToolArguments(["clips": .array(clips)]), f.project).payload["added"]?.arrayValue ?? []
        }

        func adjustments(_ entry: JSONValue?) -> [JSONValue] { entry?["adjustments"]?.arrayValue ?? [] }
        func length(_ entry: JSONValue?) -> Double { (entry?["end"]?.doubleValue ?? 0) - (entry?["start"]?.doubleValue ?? 0) }

        /// A1 has a voice line 0–3 s, A2 music 10–20 s: both tracks have room between 3 and 10 s.
        func voiceAndMusic() async throws -> TimelineState {
            f.reset()
            _ = try await add([["file": .string(tone), "start": 0, "source_out": 3]])
            _ = try await add([["file": .string(tone), "start": 10, "source_out": 10, "track": "A2"]])
            require(f.project.state.audioTracks.map(\.clips.count) == [1, 1], "setup: voice on A1, music on A2")
            f.project.effectiveUndoManager!.removeAllActions()
            return f.project.state
        }

        func crowdedNewAudio() async throws {
            let before = try await voiceAndMusic()
            let old = Set(before.audioTracks.flatMap(\.clips).map(\.id))
            let hits: [(String, Double)] = [("whoosh", 4.2), ("swoosh", 4.4), ("suction", 4.6), ("riser", 5.0), ("downlifter", 5.2),
                                            ("impact", 5.4), ("boom", 5.6), ("hit", 5.8), ("pop", 6.0), ("ding", 6.2), ("sparkle", 6.4),
                                            ("beep", 6.6), ("glitch", 6.8)]
            let entries = try await add(hits.map { ["sound_effect": ["preset": .string($0.0)], "hit_at": .number($0.1), "track": "new_audio"] })
            let onOld = f.project.state.audioTracks.prefix(2).flatMap(\.clips).filter { !old.contains($0.id) }
            require(onOld.isEmpty, "MCP-2: no new_audio effect lands on A1 (voice) or A2 (music); \(onOld.count) did")
            require(entries.count == 13 && entries.allSatisfy { ($0["track"]?.stringValue ?? "") >= "A3" }, "MCP-2: all 13 effects are on new tracks")
            let home = entries.first?["track"]?.stringValue
            let spilled = entries.filter { $0["track"]?.stringValue != home }
            require(!spilled.isEmpty && spilled.allSatisfy { entry in
                adjustments(entry).contains { $0["parameter"] == "track" && $0["requested"] == "new_audio" && $0["reason"] == "track_busy" }
            }, "MCP-2: every effect that did not fit on the call's new track says so in adjustments")
            f.project.effectiveUndoManager!.undo()
            require(f.project.state == before, "MCP-2: the whole call undoes in one step")
        }

        /// A named track that is taken at that time: a new track, not the first free one (A1 is free at 12 s).
        func namedTrackTaken() async throws {
            _ = try await voiceAndMusic()
            let entries = try await add([["sound_effect": ["preset": "pop"], "hit_at": 12, "track": "A2"],
                                         ["sound_effect": ["preset": "pop"], "hit_at": 5, "track": "A2"]])
            require(entries.first?["track"] == "A3" && entries.last?["track"] == "A2",
                    "a named track taken there lands on a new track, one with room where asked (\(entries.map { $0["track"] ?? "?" }))")
            require(adjustments(entries.first).contains { $0["parameter"] == "track" && $0["requested"] == "A2" && $0["applied"] == "A3"
                && $0["reason"] == "track_busy" && $0["overlaps"] != nil }, "the taken track is reported with the clip in the way")
        }

        /// MCP-4: an empty project, one call naming A1 to A7; a name past the next free number is renumbered and says so.
        func sevenTracks() async throws {
            f.reset()
            let names = (1...7).map { "A\($0)" }
            let entries = try await add(names.enumerated().map { index, name in
                ["file": .string(tone), "start": .number(Double(index)), "source_out": 1, "track": .string(name)]
            })
            require(f.project.state.audioTracks.count == 7, "MCP-4: A1–A7 are created in one call (\(f.project.state.audioTracks.count))")
            require(entries.map { $0["track"]?.stringValue ?? "" } == names, "MCP-4: every clip is on the track it named")
            f.project.effectiveUndoManager!.undo()
            require(f.project.state == f.before && !f.project.effectiveUndoManager!.canUndo, "MCP-4: one undo step removes all seven tracks")
            let gap = try await add([["file": .string(tone), "start": 0, "source_out": 1, "track": "A5"]]).first
            require(gap?["track"] == "A1" && adjustments(gap).contains { $0["parameter"] == "track" && $0["requested"] == "A5"
                && $0["applied"] == "A1" && $0["reason"] == "tracks_numbered_without_gaps" }, "A5 with no audio tracks becomes A1 and says why")
        }

        /// MCP-8: the clip includes the preset's tail; the reply says how long it is heard.
        func audibleDuration() async throws {
            f.reset()
            let impact = try await add([["sound_effect": ["preset": "impact", "duration": 1], "hit_at": 2]]).first
            let audible = impact?["audible_duration"]?.doubleValue ?? -1
            require(audible > 0.5 && audible < length(impact) - 0.3,
                    "MCP-8: audible_duration (\(audible)) is reported apart from the clip (\(length(impact)) s)")
        }

        /// MCP-15: an in-range volume_db is not an adjustment and reads back clean; +20 is a real gain limit.
        func cleanGain() async throws {
            for db in [-8.0, -4, -3, -2, 0] {
                f.reset()
                let entry = try await add([["sound_effect": ["preset": "pop", "volume_db": .number(db)], "start": 1]]).first
                require(adjustments(entry).isEmpty, "MCP-15: volume_db \(db) is not an adjustment (\(adjustments(entry)))")
                require(entry?["applied"]?["sound_effect"]?["volume_db"]?.doubleValue == db, "MCP-15: applied volume_db \(db) reads back clean")
            }
            f.reset()
            let loud = adjustments(try await add([["sound_effect": ["preset": "pop", "volume_db": 20], "start": 1]]).first)
            require(loud.count == 1 && loud.first?["reason"] == "gain_limits"
                    && loud.first?["applied"]?["volume_db"]?.doubleValue == AudioGain.maximumDB,
                    "MCP-15: +20 dB is clamped to the exact limit and reported as gain_limits (\(loud))")
        }

        /// Walkthrough item 2: tick and click can be placed, duration is honoured, hit_at at 0 still fits. The walkthrough's folder
        /// still holds the short files version 1 made (four click-*.m4a): one is planted here, and it must not be reused.
        func shortPresets() async throws {
            f.reset()
            let folder = AIWorkspace.shared.outputFolder(.soundEffects, project: f.project)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let click = SoundEffectParameters(preset: .click)
            let hash = SFXRandom.seed(click.canonical + "|synth=1")
            let stale = folder.appendingPathComponent("click-" + String(format: "%08x", UInt32(truncatingIfNeeded: hash ^ (hash >> 32))))
            try AIAudioFileWriter.writeSoundEffect(Array(repeating: Array(repeating: 0.1, count: 1_795), count: 2), sampleRate: SFX.sampleRate,
                                                   to: stale.appendingPathExtension("m4a"))
            let entries = try await add([["sound_effect": ["preset": "tick"], "start": 1], ["sound_effect": ["preset": "click"], "start": 2],
                                         ["sound_effect": ["preset": "click", "duration": 0.15], "start": 3],
                                         ["sound_effect": ["preset": "tick", "duration": 0.1], "start": 4],
                                         ["sound_effect": ["preset": "tick"], "hit_at": 0]])
            require(entries.count == 5, "tick and click can be added")
            require(abs(length(entries.count > 2 ? entries[2] : nil) - 0.15) < 0.002, "click honours duration 0.15")
            require(entries.allSatisfy { length($0) >= TimelineTrim.clipMinimumDuration - 1e-9 }, "no made sound is shorter than the shortest clip")
        }

        /// A failed call leaves no files behind; a file that was there before stays.
        func failedCallFiles() async throws {
            f.reset()
            let folder = AIWorkspace.shared.outputFolder(.soundEffects, project: f.project)
            func file(_ preset: SoundEffectPreset, _ variation: Int) -> String {
                folder.appendingPathComponent(SoundEffectParameters(preset: preset, variation: variation).fileStem).appendingPathExtension("m4a").path
            }
            _ = try await add([["sound_effect": ["preset": "pop", "variation": 10], "start": 1]])
            f.reset()
            do {
                _ = try await add([["sound_effect": ["preset": "pop", "variation": 9], "start": 1],
                                   ["sound_effect": ["preset": "pop", "variation": 10], "start": 3],
                                   ["sound_effect": ["preset": "whoosh", "variation": 9], "source_out": 99]])
                require(false, "a window past the end of the sound fails the call")
            } catch is AIToolError {}
            let files = FileManager.default
            require(!files.fileExists(atPath: file(.pop, 9)) && !files.fileExists(atPath: file(.whoosh, 9)), "a failed call removes the sound files it made")
            require(files.fileExists(atPath: file(.pop, 10)), "a failed call keeps a sound file that was already there")
            require(f.project.state == f.before && !f.project.effectiveUndoManager!.canUndo, "a failed call changes nothing")
        }

        /// Short sparkle and shutter used to trap (a twinkle / the second click starting after the end of the sound).
        func noTrap() async throws {
            f.reset()
            let entries = try await add([["sound_effect": ["preset": "sparkle", "duration": 0.3], "start": 1],
                                         ["sound_effect": ["preset": "shutter", "duration": 0.06], "start": 2]])
            require(entries.count == 2, "short sparkle and shutter can be added")
        }
    }
}
