import Foundation

// MARK: - Opening a project: a piece of a clip that plays out of step leaves the clip's link group
//
// What: a link group pairs a picture with what was recorded with it (its separated sound, a recording's mic). Before
// 2026-11-17 a freeze gave the piece after the hold the clip's link group, although that piece plays the hold's length later
// than the clip and its sound (docs/bugfixes/2026-11-17-freeze-tail-ripple-drags-its-clip.md): deleting the 0.04 s tail also
// deleted the clip and its sound, and dragging it dragged them. Projects saved before the fix still carry such tails, so
// opening a project takes them out of the group (docs/bugfixes/2026-11-17-old-freeze-tails-stay-linked.md).
// Rule: in one group, the pictures of one file at one speed are pieces of one clip and keep one timing (the same timeline time
// for the file's 0 s). The timing is the one the group's sound from that file plays at, else the earliest picture's; a picture
// off it leaves the group (`linkGroup` nil), which is what a freeze has done to its tail since the fix.
// Nothing else changes: every clip keeps its place and media, the clip and its sound stay a pair, every other group is as
// saved. A group with one picture is never touched (a separated sound nudged against its picture stays linked); pieces at
// different speeds are not compared. No new field, so no format version (docs/architecture/video-edit-project-file.md).
// Not: how a freeze cuts (`insertFreeze`), how a split regroups (`LinkRegrouping`), ripples (`RippleLinkPartners`).
// Runs in `VideoEditProjectIO.load`. Pure value: scripts/check-project-file.sh compiles it (checks/ProjectFile/OldFreezeTails.swift).

enum LinkGroupRepair {
    /// Takes every picture that plays out of step with its group's other pieces of the same file out of the group.
    /// Returns the pictures it unlinked.
    @discardableResult
    static func unlinkStrayPieces(in state: inout TimelineState) -> [UUID] {
        var groups: [UUID: [EditClip]] = [:]
        for clip in state.allClips { if let group = clip.linkGroup { groups[group, default: []].append(clip) } }
        var strays: [UUID] = []
        for members in groups.values {
            let pictures = members.filter { !$0.isAudioOnly }
            guard pictures.count > 1 else { continue }
            for pieces in Dictionary(grouping: pictures, by: { File(url: $0.sourceURL, speed: $0.speed) }).values where pieces.count > 1 {
                strays += stray(pieces, sounds: members.filter(\.isAudioOnly))
            }
        }
        for id in strays { state.update(id) { $0.linkGroup = nil } }
        return strays
    }

    /// Pieces of one file at one speed whose timing differs from the group's: the timing of a sound from that file that some
    /// piece plays in step with, else the earliest piece's.
    private static func stray(_ pieces: [EditClip], sounds: [EditClip]) -> [UUID] {
        guard let file = pieces.first.map({ File(url: $0.sourceURL, speed: $0.speed) }),
              let earliest = pieces.min(by: { $0.timelineStart < $1.timelineStart }) else { return [] }
        let timings = pieces.map(timing)
        let paired = sounds.first { sound in
            File(url: sound.sourceURL, speed: sound.speed) == file && timings.contains { abs($0 - timing(sound)) <= epsilon }
        }
        let anchor = timing(paired ?? earliest)
        return pieces.filter { abs(timing($0) - anchor) > epsilon }.map(\.id)
    }

    private struct File: Hashable {
        var url: URL
        var speed: Double
    }

    /// The timeline time at which the clip's file is at 0 s: the pieces of one clip in place share it.
    private static func timing(_ clip: EditClip) -> Double { clip.timelineTime(atSource: 0) }

    private static let epsilon = 0.000_5
}
