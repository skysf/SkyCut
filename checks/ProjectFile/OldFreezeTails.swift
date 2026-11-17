import Foundation

// Group 49: a freeze tail saved before 2026-11-17 still shares its clip's link group; opening the project takes it out
// (`LinkGroupRepair`, run by `VideoEditProjectIO.load`). Before, deleting the 0.04 s tail with linkage on deleted the clip and
// its sound too. The fixture is the P5 walkthrough's project as SkyCut 0.18.66 saved it after freeze_frame time=8.958.
// Case: docs/bugfixes/2026-11-17-old-freeze-tails-stay-linked.md. Compiled by scripts/check-project-file.sh.

private func uuid(_ tail: Int) -> UUID { UUID(uuidString: String(format: "11111111-0000-4000-8000-%012d", tail))! }
private let faceID = uuid(1), faceSoundID = uuid(2), shipID = uuid(3), holdID = uuid(4), tailID = uuid(5), shipSoundID = uuid(6)
private let faceGroup = uuid(21), shipGroup = uuid(22)

/// face 0–4 (its sound on A1), ship 4–8.958, the 2 s hold, ship's 0.042 s tail with ship's link group (the old bug), and ship's
/// sound on A2 at 3–9 (a J cut, in step with ship).
private let walkthroughBeforeFix = """
{
  "formatVersion": 34,
  "savedAt": "2026-11-16T21:00:00Z",
  "media": [],
  "timeline": {
    "mainClips": [
      {"id": "\(faceID)", "sourceURL": "file:///tmp/srtflow-old-freeze/face.mp4", "isAudioOnly": false,
       "sourceStart": 0, "sourceDuration": 4, "speed": 1, "timelineStart": 0, "isMuted": true, "linkGroup": "\(faceGroup)"},
      {"id": "\(shipID)", "sourceURL": "file:///tmp/srtflow-old-freeze/ship.mp4", "isAudioOnly": false,
       "sourceStart": 1, "sourceDuration": 4.958, "speed": 1, "timelineStart": 4, "isMuted": true, "linkGroup": "\(shipGroup)"},
      {"id": "\(holdID)", "sourceURL": "file:///tmp/srtflow-old-freeze/ship-still.mp4", "isAudioOnly": false,
       "stillImageURL": "file:///tmp/srtflow-old-freeze/ship-freeze-00-00-08-23.png",
       "sourceStart": 0, "sourceDuration": 2, "speed": 1, "timelineStart": 8.958, "isMuted": true},
      {"id": "\(tailID)", "sourceURL": "file:///tmp/srtflow-old-freeze/ship.mp4", "isAudioOnly": false,
       "sourceStart": 5.958, "sourceDuration": 0.042, "speed": 1, "timelineStart": 10.958, "isMuted": true, "linkGroup": "\(shipGroup)"}
    ],
    "audioTracks": [
      {"id": "\(uuid(31))", "clips": [
        {"id": "\(faceSoundID)", "sourceURL": "file:///tmp/srtflow-old-freeze/face.mp4", "isAudioOnly": true,
         "sourceStart": 0, "sourceDuration": 4, "speed": 1, "timelineStart": 0, "linkGroup": "\(faceGroup)", "audioAssetDuration": 4}
      ]},
      {"id": "\(uuid(32))", "clips": [
        {"id": "\(shipSoundID)", "sourceURL": "file:///tmp/srtflow-old-freeze/ship.mp4", "isAudioOnly": true,
         "sourceStart": 0, "sourceDuration": 6, "speed": 1, "timelineStart": 3, "linkGroup": "\(shipGroup)", "audioAssetDuration": 10}
      ]}
    ]
  }
}
"""

func checkOldFreezeTails(_ root: URL) throws {
    let folder = root.appendingPathComponent("old-freeze-tails")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("walkthrough.skycut")
    try Data(walkthroughBeforeFix.utf8).write(to: file)

    let timeline = try VideoEditProjectIO.load(from: file).timeline
    checkEqual(timeline.clip(with: tailID)?.linkGroup, nil, "49 old project: the freeze tail leaves ship's link group on open")
    checkEqual(timeline.linkedClipIDs(of: tailID), [tailID], "49 old project: deleting / dragging the tail takes nothing else along")
    checkEqual(timeline.linkedClipIDs(of: shipID), [shipID, shipSoundID], "49 old project: ship and its sound are still a pair")
    checkEqual(timeline.linkedClipIDs(of: faceID), [faceID, faceSoundID], "49 old project: face's pair is untouched")
    checkEqual(timeline.clip(with: holdID)?.linkGroup, nil, "49 old project: the hold stays unlinked")
    let placed = timeline.allClips.map { [$0.timelineStart, $0.sourceStart, $0.sourceDuration] }
    checkEqual(placed.count, 6, "49 old project: every clip is still there")
    checkEqual(timeline.clip(with: tailID).map { [$0.timelineStart, $0.sourceStart, $0.sourceDuration] }, [10.958, 5.958, 0.042],
               "49 old project: the tail keeps its place and media")
    checkEqual(timeline.clip(with: shipSoundID).map { [$0.timelineStart, $0.sourceStart, $0.sourceDuration] }, [3, 0, 6],
               "49 old project: ship's sound keeps its place and media")

    // Saved again and reopened: nothing left to repair.
    try VideoEditProjectIO.save(timeline, to: file)
    var again = try VideoEditProjectIO.load(from: file).timeline
    checkEqual(again.clip(with: tailID)?.linkGroup, nil, "49 saved after the repair: the tail stays unlinked")
    checkEqual(LinkGroupRepair.unlinkStrayPieces(in: &again), [], "49 saved after the repair: a second pass changes nothing")

    groupsThatStayChecks()
}

/// The rule only takes out a piece that plays out of step with the other pieces of its file in the group.
private func groupsThatStayChecks() {
    let media = URL(fileURLWithPath: "/tmp/srtflow-old-freeze/take.mp4")
    let mic = URL(fileURLWithPath: "/tmp/srtflow-old-freeze/mic.m4a")
    func clip(_ url: URL, _ start: Double, _ duration: Double, from source: Double, audio: Bool = false, group: UUID) -> EditClip {
        EditClip(sourceURL: url, isAudioOnly: audio, sourceStart: source, sourceDuration: duration, timelineStart: start,
                 linkGroup: group, audioAssetDuration: audio ? 60 : nil)
    }
    let group = UUID()

    // A split made with linkage off and left in place: picture–sound–picture stay one group.
    var split = TimelineState()
    let left = clip(media, 0, 3, from: 0, group: group)
    let right = clip(media, 3, 6, from: 3, group: group)
    let sound = clip(media, 0, 9, from: 0, audio: true, group: group)
    split.mainClips = [left, right]
    split.audioTracks = [EditLane(clips: [sound])]
    checkEqual(LinkGroupRepair.unlinkStrayPieces(in: &split), [], "49 a split left in place keeps its group")

    // The right piece moved alone by half a second: it no longer plays with the sound, so it leaves.
    var movedRight = split
    movedRight.update(right.id) { $0.timelineStart = 3.5 }
    checkEqual(LinkGroupRepair.unlinkStrayPieces(in: &movedRight), [right.id], "49 a piece moved alone leaves the group")
    checkEqual(movedRight.linkedClipIDs(of: left.id), [left.id, sound.id], "49 …the piece still in step keeps its sound")

    // The earlier piece moved instead: the sound decides which piece is in step, not which comes first.
    var movedLeft = split
    movedLeft.update(left.id) { $0.timelineStart = 0.5 }
    checkEqual(LinkGroupRepair.unlinkStrayPieces(in: &movedLeft), [left.id], "49 the piece out of step with the sound leaves, even the earliest")

    // One picture: a separated sound nudged two frames for sync stays linked.
    var nudged = TimelineState()
    let picture = clip(media, 0, 5, from: 0, group: group)
    nudged.mainClips = [picture]
    nudged.audioTracks = [EditLane(clips: [clip(media, 0.083, 5, from: 0, audio: true, group: group)])]
    checkEqual(LinkGroupRepair.unlinkStrayPieces(in: &nudged), [], "49 a nudged sound with one picture stays linked")

    // A recording with its mic (another file) and an old freeze tail: no sound of the picture's file, the earliest piece decides.
    var recording = TimelineState()
    let screen = clip(media, 0, 4, from: 0, group: group)
    let tail = clip(media, 6, 2, from: 4, group: group)
    let voice = clip(mic, 0, 8, from: 0, audio: true, group: group)
    recording.mainClips = [screen, tail]
    recording.audioTracks = [EditLane(clips: [voice])]
    checkEqual(LinkGroupRepair.unlinkStrayPieces(in: &recording), [tail.id], "49 a recording's old freeze tail leaves its group")
    checkEqual(recording.linkedClipIDs(of: screen.id), [screen.id, voice.id], "49 …the screen and its mic stay a pair")

    // Pieces at different speeds are not compared.
    var faster = split
    faster.update(right.id) { $0.speed = 2; $0.sourceDuration = 12 }
    checkEqual(LinkGroupRepair.unlinkStrayPieces(in: &faster), [], "49 a piece at another speed is left as it is")
}
