import Foundation
@testable import SrtFlow

// Names, ids, the per-project folder, pruning and the age sweep (ProjectVersionFiles + ProjectVersionStore.sweep on a real folder).

@MainActor
func runFileChecks(_ checks: Checks, work: URL) {
    // A version's file name is the project's name in the `<name> - <version>` form, and reads back.
    let name = ProjectVersionFiles.fileName(projectStem: "南极", number: 3, kind: .beforeRound)
    checks.require(name == "南极 - v3 before AI round.skycut", "file name: \(name)")
    checks.require(ProjectVersionFiles.parse(fileName: name).map { "\($0.number) \($0.kind?.rawValue ?? "-")" } == "3 before_ai_round",
                   "a version file name reads back")
    // A project whose own name ends like a version ("南极 - v2", from new_project version=v2): the last " - v" wins.
    let variant = ProjectVersionFiles.fileName(projectStem: "南极 - v2", number: 12, kind: .afterRound)
    checks.require(ProjectVersionFiles.parse(fileName: variant).map { "\($0.number) \($0.kind?.rawValue ?? "-")" } == "12 after_ai_round",
                   "a variant project's version reads back: \(variant)")
    let unknown = ProjectVersionFiles.parse(fileName: "南极 - v4 kept by hand.skycut")
    checks.require(unknown?.number == 4 && unknown?.kind == nil, "unknown words after the number: still a version, kind unknown")
    for other in ["南极.skycut", "notes.txt", "x - v0 before AI round.skycut", "x - v3x.skycut", "x - v.skycut", "x - v3 before AI round.txt"] {
        checks.require(ProjectVersionFiles.parse(fileName: other) == nil, "not a version: \(other)")
    }
    for (id, number) in [("v3", 3), ("V3", 3), ("3", 3), (" v12 ", 12)] {
        checks.require(ProjectVersionFiles.number(fromID: id) == number, "id \(id) is version \(number)")
    }
    for id in ["v", "v-1", "abc", "v0", "v٣", "3.5", ""] {
        checks.require(ProjectVersionFiles.number(fromID: id) == nil, "not an id: \(id)")
    }
    // Long names are cut so the file name stays inside 255 bytes (CJK is 3 bytes a character).
    let long = String(repeating: "很长的工程名字", count: 30)
    let longName = ProjectVersionFiles.fileName(projectStem: long, number: 1234, kind: .beforeGoingBack)
    checks.require(longName.utf8.count <= 255 && ProjectVersionFiles.parse(fileName: longName)?.number == 1234,
                   "a long name is cut, fits 255 bytes and reads back (\(longName.utf8.count) bytes)")
    checks.require(ProjectVersionFiles.folderName(forProject: work.appendingPathComponent(long + ".skycut")).utf8.count <= 255,
                   "a long name's folder fits 255 bytes")

    // One folder per project file: the same name in two folders never shares a list; the same file reached another way does.
    let x = work.appendingPathComponent("x/Same.skycut")
    let y = work.appendingPathComponent("y/Same.skycut")
    checks.require(ProjectVersionFiles.folderName(forProject: x) != ProjectVersionFiles.folderName(forProject: y),
                   "two projects with the same name keep separate folders")
    checks.require(ProjectVersionFiles.folderName(forProject: x)
                   == ProjectVersionFiles.folderName(forProject: work.appendingPathComponent("y/../x/Same.skycut")),
                   "the same project file reached through .. is the same folder")
    checks.require(ProjectVersionFiles.folderName(forProject: x).hasPrefix("Same "), "the folder starts with the project's name")

    // Pruning keeps the newest 30 by number.
    let many = (1...35).map { ProjectVersion(number: $0, kind: .afterRound, savedAt: Date(), url: work.appendingPathComponent("\($0)")) }
    checks.require(ProjectVersionFiles.pruned(many.shuffled()).map(\.number).sorted() == [1, 2, 3, 4, 5], "pruning deletes the oldest five of 35")
    checks.require(ProjectVersionFiles.pruned(Array(many.prefix(30))).isEmpty, "30 versions: nothing pruned")
    let now = Date()
    checks.require(!ProjectVersionFiles.isStale(newest: now.addingTimeInterval(-59 * 86_400), now: now)
                   && ProjectVersionFiles.isStale(newest: now.addingTimeInterval(-61 * 86_400), now: now)
                   && ProjectVersionFiles.isStale(newest: nil, now: now), "stale after 60 days, or with no version at all")
    runSweepChecks(checks, work: work)
}

/// The age sweep on a real folder: only version files of stale project folders go, the folder only when that left it empty;
/// notes the user put there and fresh projects stay.
@MainActor
private func runSweepChecks(_ checks: Checks, work: URL) {
    let manager = FileManager.default
    let root = work.appendingPathComponent("sweep-root", isDirectory: true)
    func file(_ folder: String, _ name: String, daysOld: Double) -> URL {
        let url = root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name)
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: url)
        try? manager.setAttributes([.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path)
        return url
    }
    let staleWithNotes = file("Old 0000aaaa", "Old - v1 after AI round.skycut", daysOld: 61)
    let notes = file("Old 0000aaaa", "notes.txt", daysOld: 400)
    let staleOnly = file("Gone 0000bbbb", "Gone - v7 before AI round.skycut", daysOld: 90)
    let fresh = file("Fresh 0000cccc", "Fresh - v2 after AI round.skycut", daysOld: 1)
    let freshOld = file("Fresh 0000cccc", "Fresh - v1 before AI round.skycut", daysOld: 200)
    let kept = file("Kept 0000dddd", "Kept - v1 after AI round.skycut", daysOld: 300)
    let outside = work.appendingPathComponent("Outside - v1 after AI round.skycut")
    try? Data("{}".utf8).write(to: outside)
    try? manager.setAttributes([.modificationDate: Date().addingTimeInterval(-500 * 86_400)], ofItemAtPath: outside.path)
    ProjectVersionStore.sweep(root: root, keeping: kept.deletingLastPathComponent(), now: Date())
    checks.require(!manager.fileExists(atPath: staleWithNotes.path) && manager.fileExists(atPath: notes.path),
                   "a stale folder loses its versions but keeps the user's other files (and the folder)")
    checks.require(!manager.fileExists(atPath: staleOnly.deletingLastPathComponent().path), "a stale folder left empty is removed")
    checks.require(manager.fileExists(atPath: fresh.path) && manager.fileExists(atPath: freshOld.path),
                   "a project with a recent version keeps all of them (the count cap prunes, not age)")
    checks.require(manager.fileExists(atPath: kept.path), "the folder being written is never swept")
    checks.require(manager.fileExists(atPath: outside.path), "nothing outside the versions root is touched")
}
