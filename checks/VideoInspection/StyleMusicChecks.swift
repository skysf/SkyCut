import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// No music where the film's editing style expects it (2026-11-20, the user: 「按风格定」). On values: which recorded styles
// expect music (AIDeliveryStyleMusic: a preset's header, Sky Studio's manifest field, else SkyCut's list by id; the user's own
// styles and no style never) and the rule turning the grey hint into the suspect (AIDeliveryMusic.noMusic). Then the App's own
// answer from its presets (read from the App's resources as the packaged App has them; scripts/check-video-inspection.sh copies
// them) and one real inspect_video job on 16 s of sound that is not music, audio only: cut in cinematic-opening it is the suspect
// `audio_music_missing` in findings, attached to no clip, and no grey hint; marked intentional through the tool, the report's
// partition moves that suspect to the intentional list.
@MainActor
enum StyleMusicChecks {
    static func run(_ project: VideoEditProject, root: URL, require: (Bool, String) -> Void) async throws {
        expectations(require: require)
        rule(require: require)
        let context = AICallContext(session: "style-music-check", client: "Check", project: project.shortID, stopsWith: project.shortID)
        try await AICallContext.$current.withValue(context) {
            AIWorkspace.shared.register(root)
            try await realJob(project, root: root, require: require)
        }
    }

    static func record(_ id: String, _ source: AIRecipe.Source) -> EditingStyleRecord {
        EditingStyleRecord(id: id, source: source.rawValue, version: source == .skyStudio ? "1.0" : nil,
                           sha256: String(repeating: "a", count: 64), skycutVersion: source == .skyStudio ? nil : "0.0.0")
    }

    // MARK: Which styles expect music

    private static func expectations(require: (Bool, String) -> Void) {
        let presets = [
            AIRecipe(id: "cinematic-opening", title: "Cinematic opening", useFor: "", body: "x", source: .builtIn, expectsMusic: true),
            AIRecipe(id: "documentary", title: "Documentary", useFor: "", body: "x", source: .builtIn, expectsMusic: false),
            AIRecipe(id: "daily-vlog", title: "Daily vlog", useFor: "", body: "x", source: .builtIn)
        ]
        func listed(_ id: String, _ expects: Bool?) -> SkyStudioContentManifest.Style {
            .init(id: id, title: "Film trailer", useFor: "", version: "1.0", sha256: String(repeating: "b", count: 64), expectsMusic: expects)
        }
        func expecting(_ record: EditingStyleRecord?, _ listing: [SkyStudioContentManifest.Style] = []) -> AIDeliveryStyleMusic.Style? {
            AIDeliveryStyleMusic.expecting(record, presets: presets, listed: listing)
        }
        require(expecting(record("cinematic-opening", .builtIn)) == .init(id: "cinematic-opening", title: "Cinematic opening"),
                "a preset whose header says music: expected expects music")
        require(expecting(record("documentary", .builtIn)) == nil && expecting(record("daily-vlog", .builtIn)) == nil
                    && expecting(record("gone", .builtIn)) == nil,
                "a preset saying optional or nothing, or one the App no longer has, does not")
        require(expecting(record("film-trailer", .skyStudio)) == .init(id: "film-trailer", title: "film-trailer")
                    && expecting(record("film-trailer", .skyStudio), [listed("film-trailer", nil)])?.title == "Film trailer",
                "film-trailer expects music by SkyCut's list while Sky Studio's manifest does not say, listed or not")
        require(expecting(record("film-trailer", .skyStudio), [listed("film-trailer", false)]) == nil
                    && expecting(record("talk-show", .skyStudio), [listed("talk-show", true)])?.id == "talk-show",
                "Sky Studio's expects_music wins over SkyCut's list, either way")
        require(expecting(record("talk-show", .skyStudio)) == nil, "a Sky Studio style neither the manifest nor the list names does not")
        require(expecting(record("cinematic-opening", .customized)) == nil && expecting(record("my-trailer", .user)) == nil
                    && expecting(nil) == nil,
                "the user's own styles (a preset the user replaced too) and a film with no recorded style keep the grey hint")
    }

    // MARK: The rule

    private static func rule(require: (Bool, String) -> Void) {
        let scope = AIInspection.Scope(ranges: [0 ... 24], duration: 24)
        let room = AIDeliveryCutJumps.Sound(id: UUID(), role: .other, start: 0, end: 24, fadeOutStart: 24)
        let trailer = AIDeliveryStyleMusic.Style(id: "film-trailer", title: "Film trailer")
        let suspect = AIDeliveryMusic.noMusic(sounds: [room], duration: 24, scope: scope, style: trailer)
        require(suspect.count == 1 && suspect[0].kind == "audio_music_missing" && suspect[0].details["style"] == "film-trailer"
                    && suspect[0].reason.contains("Film trailer (film-trailer)") && suspect[0].items.isEmpty
                    && suspect[0].from == 0 && suspect[0].to == 24,
                "no music under a style that expects it is one suspect over what was checked, naming the style")
        require(!AIDeliveryChecks.hintKinds.contains("audio_music_missing") && AIDeliveryChecks.wholeFilmKinds.contains("audio_music_missing"),
                "it is listed with the suspects and attached to no clip, like the hint")
        let music = AIDeliveryCutJumps.Sound(id: UUID(), role: .music, start: 20, end: 24, fadeOutStart: 24)
        require(AIDeliveryMusic.noMusic(sounds: [room, music], duration: 24, scope: scope, style: trailer).isEmpty
                    && AIDeliveryMusic.noMusic(sounds: [room], duration: 10, scope: .init(ranges: [0 ... 10], duration: 10), style: trailer).isEmpty
                    && AIDeliveryMusic.noMusic(sounds: [], duration: 24, scope: scope, style: trailer).isEmpty,
                "music somewhere, a video under 15 s or one with no sound at all: nothing (the hint's lines)")
        require(AIDeliveryMusic.noMusic(sounds: [room], duration: 24, scope: scope).map(\.kind) == ["audio_no_music"],
                "with no style expecting music it stays the grey hint")
    }

    // MARK: The App's presets and the real job

    private static func realJob(_ project: VideoEditProject, root: URL, require: (Bool, String) -> Void) async throws {
        require(AIDeliveryStyleMusic.expecting(record("cinematic-opening", .builtIn))?.title == "Cinematic opening"
                    && AIDeliveryStyleMusic.expecting(record("sci-fi", .builtIn)) != nil
                    && AIDeliveryStyleMusic.expecting(record("documentary", .builtIn)) == nil
                    && AIDeliveryStyleMusic.expecting(nil) == nil,
                "the App reads its presets' headers: cinematic-opening and sci-fi expect music, documentary does not, no style nothing")
        var noise = SoundTierChecks.Noise(seed: 41)
        let room = try SoundTierChecks.wave(root, "style-room.wav", 16) { _ in noise.next(0.2) }
        var state = TimelineState()
        state.frameRate = .fps24
        state.audioTracks = [EditLane(clips: [SoundTierChecks.audio(room, at: 0, 16, asset: 16)])]
        state.editingStyle = record("cinematic-opening", .builtIn)
        project.restoreTimeline(state)
        project.effectiveUndoManager!.removeAllActions()
        let before = project.state
        // One job (the binary links the debug build and has a 480 s deadline): the suspect through the real tool, then the
        // mark through the real tool. That the saved mark takes the suspect out of findings is the report's own partition on
        // the same finding; the documentary film's grey hint is the rule without a style (above) with the App's answer here.
        let first = try await SoundTierChecks.inspect(project)
        let suspect = (first["findings"]?.arrayValue ?? []).first { $0["kind"] == "audio_music_missing" }
        require(suspect?["style"] == "cinematic-opening" && suspect?["items"]?.arrayValue?.isEmpty == true
                    && !(first["hints"]?.arrayValue ?? []).contains { $0["kind"] == "audio_no_music" },
                "16 s without music, cut in a preset that expects music: a suspect about the whole film and no grey hint "
                    + "(\(suspect?.encodedString() ?? "none"); hints \(first["hints"]?.encodedString() ?? "none"))")
        require(project.state == before && !project.effectiveUndoManager!.canUndo, "the report changes nothing")
        print("Style-music job: \(first["elapsed_seconds"]?.encodedString() ?? "?") s for 16 s of sound")
        guard let key = suspect?["key"]?.stringValue, let job = first["job_id"] else {
            require(false, "the suspect needs a key and its report to be marked")
            return
        }
        let reason = "A cut without music, on purpose"
        let marked = try await AIInspectionTool.start(AIToolArguments(["intentional": ["job_id": job, "key": .string(key),
                                                                                       "reason": .string(reason)]]), project)
        require(marked.changedProject && project.state.deliveryIntentions.map(\.key) == [key],
                "marking it intentional through the tool saves that one decision")
        let found = AIDeliveryMusic.noMusic(sounds: [.init(id: UUID(), role: .other, start: 0, end: 16, fadeOutStart: 16)], duration: 16,
                                            scope: try AIInspection.scope(state: project.state, from: nil, to: nil),
                                            style: AIDeliveryStyleMusic.expecting(project.state.editingStyle))
        let again = AIInspectionReview.partition(found, state: project.state, job: "style-music-again", generation: 0, session: nil)
        require(again.findings.isEmpty && again.intentional.count == 1 && again.intentional[0]["key"] == .string(key)
                    && again.intentional[0]["intentional_reason"] == .string(reason) && again.intentional[0]["reproduced"] == true,
                "marked, the same suspect leaves findings and is listed under intentional with its reason")
    }
}
