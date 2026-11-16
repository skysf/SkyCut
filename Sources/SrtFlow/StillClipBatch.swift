import Foundation

// MARK: - Converting several image placeholders at once
//
// What it does: runs `VideoEditProject.convertStillClip` for a batch of image placeholders (a dropped PNG sequence, pasted
// stills) together instead of one after another — a 96-frame title sequence waited for 96 conversions in a row (MCP-76).
// How many ffmpeg runs go at once is bounded in the factory (`StillImageClipFactory`'s conversion slots), whoever asks.
// Each placeholder still lands on its own as soon as its conversion is done (`convertStillClip`: no undo step, rebuild).
// The caller's task stays alive until the whole batch is done, so `trackImportTask` still cancels it on a project switch.
// What it does not do: place the placeholders, convert the image (StillImageClipFactory), or land the result (convertStillClip).

@MainActor
enum StillClipBatch {
    static func convert(_ images: [(clip: UUID, image: URL)], generation: Int, in project: VideoEditProject) async {
        await withTaskGroup(of: Void.self) { group in
            for item in images {
                group.addTask { await project.convertStillClip(item.clip, from: item.image, generation: generation) }
            }
        }
    }
}
