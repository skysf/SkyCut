import Darwin
import Foundation
import SrtFlowCore

// A new file never replaces anything, and nothing but SkyCut's own private files is ever removed
// (docs/bugfixes/2026-11-19-empty-name-reservation-replaced-or-removed.md; rules: docs/architecture/export-settings.md §5
// item 9). On real folders: a name taken before or while the file is written keeps its bytes; an empty file that appears at
// the name survives a failed write; a set that meets a taken name gives back the names it took and moves on together; a
// numbered series counts on from its number; nothing private is left behind. Every step of ExclusiveInstall runs: the
// exclusive rename here, a hard link and an O_EXCL copy forced through `stepsForChecks`, and all of it again on a real exFAT
// volume (a disk image), whose driver has no exclusive rename and no hard links.

func runExclusivePlacementChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-placement-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let forced: [(String, [ExclusiveInstall.Step]?)] = [
        ("exclusive rename", nil), ("hard link", [.hardLink]), ("O_EXCL copy", [.exclusiveCopy])
    ]
    for (label, steps) in forced {
        ExclusiveInstall.stepsForChecks = steps
        placementScenarios(in: root.appendingPathComponent(label), label: label)
    }
    ExclusiveInstall.stepsForChecks = nil
    withExFATVolume { volume in
        placementScenarios(in: volume.appendingPathComponent("checks", isDirectory: true), label: "exFAT")
    }
}

private enum Made: Equatable {
    case written
    case taken
    case failed
}

private func placementScenarios(in folder: URL, label: String) {
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
        return check(false, "\(label): a folder for the placement checks: \(error)")
    }
    exactNames(in: folder, label: label)
    sets(in: folder, label: label)
    series(in: folder, label: label)
    scratchFiles(in: folder, label: label)
    let left = privateNames(in: folder)
    check(left.isEmpty, "\(label): nothing private is left in the folder: \(left)")
}

/// `create`: one exact name.
private func exactNames(in folder: URL, label: String) {
    let fresh = folder.appendingPathComponent("Fresh.srt")
    check(make(fresh) { try write("new", $0) } == .written && read(fresh) == "new", "\(label): a free name gets the file")

    let kept = folder.appendingPathComponent("Kept.srt")
    try? write("keep", kept)
    check(make(kept) { try write("new", $0) } == .taken && read(kept) == "keep",
          "\(label): a file already at the name keeps its bytes and the answer is 'taken'")

    // The review's case: the name is taken while the bytes are being written (another app saves a file there).
    let late = folder.appendingPathComponent("Late.srt")
    let lateAnswer = make(late) { path in
        try write("new", path)
        try Data("saved by another app meanwhile".utf8).write(to: late, options: .atomic)
    }
    check(lateAnswer == .taken && read(late) == "saved by another app meanwhile",
          "\(label): a file that appears at the name while SkyCut writes is never replaced (\(lateAnswer), \(read(late) ?? "nil"))")

    // A failed write never removes what is at the name — not even an empty file someone else made there.
    let empty = folder.appendingPathComponent("Empty.srt")
    let failed = make(empty) { path in
        try write("half", path)
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        throw CocoaError(.fileWriteOutOfSpace)
    }
    check(failed == .failed && FileManager.default.fileExists(atPath: empty.path),
          "\(label): an empty file that appeared at the name survives a failed write (\(failed))")

    let never = folder.appendingPathComponent("Never.srt")
    let refused = make(never) { _ in throw CocoaError(.fileWriteOutOfSpace) }
    check(refused == .failed && !FileManager.default.fileExists(atPath: never.path),
          "\(label): a write that fails before making anything leaves nothing at the name")
}

/// `createSet`: files that belong together end up under one number.
private func sets(in folder: URL, label: String) {
    // Taken from the start: the whole set moves on, and set 1's free name is not used.
    try? write("keep", folder.appendingPathComponent("Talk.zh.srt"))
    let talk = makeSet("Talk", in: folder)
    check(talk?.number == 2 && !exists(folder, "Talk.en.srt") && read(folder, "Talk.zh.srt") == "keep"
          && read(folder, "Talk 2.en.srt") == "en" && read(folder, "Talk 2.zh.srt") == "zh",
          "\(label): one taken name moves the whole set on (\(talk?.number ?? 0))")

    // Taken while the set is written: the second name appears meanwhile, so the first name, already given, is taken back.
    for (stem, index) in [("Pair", 1), ("Duo", 0)] {
        let names = setNames(stem, in: folder)
        let set = makeSet(stem, in: folder) { written in
            if written == 1 { try Data("saved meanwhile".utf8).write(to: names(1)[index], options: .atomic) }
        }
        let other = names(1)[1 - index].lastPathComponent
        check(set?.number == 2 && read(names(1)[index]) == "saved meanwhile" && !exists(folder, other)
              && read(names(2)[0]) == "en" && read(names(2)[1]) == "zh",
              "\(label): a name of the set taken while it was written keeps its bytes; the set moves on whole (\(stem))")
    }
}

/// `place`: a finished file into a numbered series.
private func series(in folder: URL, label: String) {
    try? write("keep", folder.appendingPathComponent("Cut.mp4"))
    try? write("keep 2", folder.appendingPathComponent("Cut 2.mp4"))
    let moved = folder.appendingPathComponent("finished.tmp")
    try? write("new", moved)
    let placed = try? ExclusivePlacement.place(moved, in: folder, stem: "Cut", pathExtension: "mp4", from: 2)
    check(placed?.lastPathComponent == "Cut 3.mp4" && placed.flatMap(read) == "new" && read(folder, "Cut 2.mp4") == "keep 2"
          && read(folder, "Cut.mp4") == "keep" && !FileManager.default.fileExists(atPath: moved.path),
          "\(label): a taken name moves the file on from its number (Cut 3, not Cut 2 2): \(placed?.lastPathComponent ?? "nil")")

    let copied = folder.appendingPathComponent("copied.tmp")
    try? write("copy", copied)
    let copy = try? ExclusivePlacement.place(copied, in: folder, stem: "Cut", pathExtension: "mp4", from: 1, copying: true)
    check(copy?.lastPathComponent == "Cut 4.mp4" && copy.flatMap(read) == "copy" && read(copied) == "copy",
          "\(label): onto another drive the file is copied in and the original is left to its owner: \(copy?.lastPathComponent ?? "nil")")
}

/// `scratch` / `discard`: only the caller's own file is ever removed.
private func scratchFiles(in folder: URL, label: String) {
    guard let mine = try? ExclusivePlacement.scratch(in: folder, stem: "Encode", pathExtension: "mp4") else {
        return check(false, "\(label): a scratch file can be made")
    }
    ExclusivePlacement.discard(mine)
    check(!FileManager.default.fileExists(atPath: mine.url.path), "\(label): discard removes the caller's own file")
    guard let replaced = try? ExclusivePlacement.scratch(in: folder, stem: "Encode", pathExtension: "mp4") else { return }
    try? Data("someone else's".utf8).write(to: replaced.url, options: .atomic)
    ExclusivePlacement.discard(replaced)
    check(read(replaced.url) == "someone else's", "\(label): discard never removes a file that is no longer the caller's")
    try? FileManager.default.removeItem(at: replaced.url)
}

// MARK: - Helpers

private func make(_ url: URL, _ body: (URL) throws -> Void) -> Made {
    do {
        return try ExclusivePlacement.create(url, writing: body) == nil ? .taken : .written
    } catch {
        return .failed
    }
}

private func setNames(_ stem: String, in folder: URL) -> (Int) -> [URL] {
    { number in ["en", "zh"].map { folder.appendingPathComponent((number > 1 ? "\(stem) \(number)" : stem) + ".\($0).srt") } }
}

/// Writes "en" and "zh" as set `stem`; `meanwhile(i)` runs after file i is written.
private func makeSet(
    _ stem: String, in folder: URL, meanwhile: (Int) throws -> Void = { _ in }
) -> (number: Int, urls: [URL])? {
    try? ExclusivePlacement.createSet(from: 1, setNames(stem, in: folder)) { index, path in
        try write(index == 0 ? "en" : "zh", path)
        try meanwhile(index)
    }
}

private func write(_ text: String, _ url: URL) throws {
    try Data(text.utf8).write(to: url)
}

private func read(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

private func read(_ folder: URL, _ name: String) -> String? {
    read(folder.appendingPathComponent(name))
}

private func exists(_ folder: URL, _ name: String) -> Bool {
    FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
}

/// SkyCut's private names (staged files, scratch files, the drive test): none may be left behind.
private func privateNames(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        .filter { $0.contains(".partial-") || $0.contains("install-check") }
}

// MARK: - A real exFAT volume

/// A small exFAT disk image (its label at most 11 characters, or newfs fails), attached without showing it in Finder,
/// detached afterwards. A machine that can't make or attach one fails the check (it is not skipped).
private func withExFATVolume(_ body: (URL) -> Void) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-exfat-\(UUID().uuidString)")
    let image = base.appendingPathComponent("volume.dmg"), mount = base.appendingPathComponent("mount", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    guard hdiutil(["create", "-quiet", "-size", "16m", "-fs", "ExFAT", "-volname", "SkyCutTest", image.path]),
          hdiutil(["attach", "-quiet", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mount.path, image.path])
    else {
        return check(false, "exFAT: a disk image for the drive without an exclusive rename (hdiutil create / attach)")
    }
    defer { _ = hdiutil(["detach", "-quiet", "-force", mount.path]) }
    print("exFAT volume: an exclusive rename onto a free name is \(exclusiveRenameWorks(in: mount) ? "supported" : "not supported (the copy step runs)")")
    body(mount)
}

private func exclusiveRenameWorks(in folder: URL) -> Bool {
    let from = folder.appendingPathComponent(".rename-probe-\(UUID().uuidString)")
    let to = folder.appendingPathComponent(".rename-probe-\(UUID().uuidString)")
    defer { unlink(from.path); unlink(to.path) }
    guard FileManager.default.createFile(atPath: from.path, contents: Data()) else { return false }
    return renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0
}

/// Runs hdiutil, at most 60 s. true = it exited 0.
private func hdiutil(_ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    let deadline = Date().addingTimeInterval(60)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning {
        process.terminate()
        return false
    }
    return process.terminationStatus == 0
}
