import Foundation
import SrtFlowMCPKit

// MARK: - A generated music job's get_job: what listen says about the file
//
// What this owns (MCP-43, 2026-11-18): when generate_media kind=music has downloaded its file, the job's result carries `music`,
// which is exactly what `listen file=<that file> beats=true` answers (levels, silences, curve, tempo, beats, accents, strongest
// accents, stops, ends_at): the AI sees where the piece hits, stops and ends before it places it (generated music rarely
// follows the seconds in its prompt, MCP-18). One measurement, the listen one (AIListenFileAudio): nothing is measured twice.
// Never fails the job: a file that cannot be measured says so, and listen can be called later.
// What it does not own: the generation itself (SkyStudioGenerationRun, which calls `measure` before it finishes the job).

@MainActor
enum AIGeneratedMusicReport {
    static func measure(_ file: URL, project: VideoEditProject?) async -> JSONValue {
        do {
            var object = try await AIListenFileAudio.listen(
                file, args: AIToolArguments(.object([:])), display: AIWorkspace.shared.display(file),
                silenceDB: AIAudioLevels.defaultSilenceDB, minSilence: AIListenTool.defaultMinSilence, beats: true,
                frames: AIListenFrameGrid(fps: (project?.state.frameRate ?? .fallback).fps),
                until: Date().addingTimeInterval(AIListenTool.waitSeconds)
            )
            object["listened_to"] = nil
            object["placing"] = "add_clips with file, hit_at (a timeline second) and hit (a source second from accents; default the strongest) lands that hit there."
            return .object(object)
        } catch {
            return .string("not measured (\(error.localizedDescription)): call listen with this file and beats=true")
        }
    }
}
