import Foundation

// MARK: - The sound effect files one add_clips call made (a failed call leaves none behind)
//
// What it does: remembers which files the call wrote (not the ones that were already there) and, when the call fails, removes
// them: a failed call changes nothing (the P5 walkthrough found four click and two tick files left by calls that failed,
// docs/bugfixes/2026-11-17-tick-and-click-cannot-be-placed.md). A file stays when another running call uses it (same parameters,
// same file: two projects can share a folder) or a clip in an open project points at it.
// What it does not: rendering and writing (AISoundEffectTool, AIAudioFileWriter), deciding that the call failed (AITimelineTools).

@MainActor
final class AISoundEffectFiles {
    /// Files the running calls use, and how many calls use each.
    private static var inUse: [URL: Int] = [:]
    private var held: [URL] = []
    private var written: Set<URL> = []
    private var finished = false

    /// Before the file is made: this call uses `url` (a call that fails meanwhile leaves it alone).
    func hold(_ url: URL) {
        Self.inUse[url, default: 0] += 1
        held.append(url)
    }

    /// This call wrote `url`: it was not there before.
    func wrote(_ url: URL) { written.insert(url) }

    /// The call is over. `failed`: remove what it wrote, unless another call or an open project uses it.
    func finish(failed: Bool) {
        guard !finished else { return }
        finished = true
        for url in held {
            let left = (Self.inUse[url] ?? 1) - 1
            Self.inUse[url] = left > 0 ? left : nil
        }
        guard failed, !written.isEmpty else { return }
        let used = Set(OpenProjects.shared.all.flatMap { $0.state.allClips.map(\.sourceURL.standardizedFileURL) })
        for url in written where Self.inUse[url] == nil && !used.contains(url.standardizedFileURL) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
