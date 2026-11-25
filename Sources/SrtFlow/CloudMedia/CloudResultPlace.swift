import Foundation
import SrtFlowCore

// MARK: - Where a paid result goes on this Mac, and the file it became
//
// What it covers (2026-11-26, CXD4 on PR #554: a voice change in SkyCut and one in SkyCut Beta overwrote each other's file on the
// timeline and a cancel deleted it; generate_media removed a folder that had taken its name; a voice called "Background" and the
// background landed on one file on a case-insensitive drive): a result is written into a private file hidden next to where it goes
// (`partial`), and takes its name in one step that never replaces anything: `stem.ext`, or the next free number of that series at
// that moment (ExclusivePlacement, the same placement as exports). A name taken by anything (a file, a folder, a name that differs
// only in case) is never touched. The placed file is the caller's own by device and inode (`CloudResultFile.file`): a flow that gives
// it up removes it with ExclusivePlacement.discard, only while it is still that file.
// What it does not cover: the GETs (CloudResultDownload), picking folders and stems (each flow).

struct CloudResultPlace: Sendable {
    var folder: URL
    var stem: String
    var pathExtension: String
    /// The number of the series to start from (1: `stem.ext`; 2: `stem 2.ext`).
    var number = 1

    /// The private file the GETs write into: hidden next to where the result goes (the same drive, so placing it is a rename), under
    /// a name nobody else uses.
    func partial() -> URL {
        var piece = ""
        for character in stem {
            guard piece.utf8.count + String(character).utf8.count <= 100 else { break }
            piece.append(character)
        }
        return folder.appendingPathComponent(".\(piece).\(pathExtension).part-\(UUID().uuidString.prefix(8))")
    }

    /// The whole result takes its name (`pathExtension` when a flow's check corrected it). Off Swift's pool: on a drive without an
    /// exclusive rename the placement is a copy (docs/architecture/blocking-media-reads.md).
    func place(_ partial: URL, pathExtension corrected: String? = nil) async throws -> ExclusivePlacement.Claim {
        let (folder, stem, pathExtension, number) = (folder, stem, corrected ?? pathExtension, number)
        return try await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result { try ExclusivePlacement.placeOwned(partial, in: folder, stem: stem, pathExtension: pathExtension, from: number) }
        }.get()
    }
}

/// A paid result on this Mac: the file it became (the caller's own while it is still that file) and the GETs sent for it.
struct CloudResultFile: Sendable {
    let file: ExclusivePlacement.Claim
    let gets: Int
    var url: URL { file.url }
}

/// What came down is not a usable result by a flow's own check (CloudResultDownload's `check`): thrown away and started again like a
/// short answer; `reason` is what the failure reports.
struct CloudResultUnusable: Error {
    let reason: String
}
