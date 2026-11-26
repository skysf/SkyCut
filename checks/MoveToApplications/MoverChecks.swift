import Foundation

// AppBundleMover against scratch folders (scripts/check-move-to-applications.sh): an empty destination; an app of that name
// that isn't running (to the scratch Trash, the new one in place and verified); one that is running, or starts running
// while the copy is made (untouched either way); a folder this user can't write (untouched); failures halfway (a copy that
// breaks off, a copy whose signature fails, a copy of another build, a Trash that refuses, an install that fails after the
// old app went to the Trash, with and without putting it back). After each one
// the staging folder is gone and the old app is where it was, or, only when it couldn't be put back, in the Trash.

enum MoverChecks {
    /// The outcome with every URL as a standardized path: Foundation adds a trailing slash to a URL whose directory exists.
    static func plain(_ outcome: AppBundleMover.Outcome) -> String {
        func path(_ url: URL?) -> String {
            guard var path = url?.standardizedFileURL.path else { return "nil" }
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        switch outcome {
        case .moved(let url): return "moved(\(path(url)))"
        case .runningAtDestination(let url): return "runningAtDestination(\(path(url)))"
        case .destinationNotWritable(let url): return "destinationNotWritable(\(path(url)))"
        case .failed(let step, let detail, let trashed): return "failed(\(step), \(detail ?? "nil"), \(path(trashed)))"
        }
    }

    static func run(in root: URL, check: (Bool, String) -> Void) throws {
        try emptyDestination(root, check)
        try replacesStoppedApp(root, check)
        try leavesRunningApp(root, check)
        try runningStartsDuringCopy(root, check)
        try unwritableDestination(root, check)
        try copyBreaksOff(root, check)
        try signatureFails(root, check)
        try swappedCopyFails(root, check)
        try trashRefuses(root, check)
        try installFailsAndRestores(root, check)
        try installAndRestoreFail(root, check)
    }

    private static func emptyDestination(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try MoveScene(root, name: "empty")
        let original = try Fixture.app(in: scene.source, marker: "new")
        Fixture.setQuarantine(on: original)
        let installed = scene.applications.appendingPathComponent("SkyCut.app")
        let outcome = scene.mover().move(original)
        check(plain(outcome) == plain(.moved(installed)), "empty destination: moved to Applications/SkyCut.app (got \(outcome))")
        check(Fixture.marker(of: installed) == "new", "empty destination: the copy is in place")
        check((try? AppBundleSignature.verify(installed, matches: original)) != nil, "empty destination: the copy satisfies the original's requirement")
        check(Fixture.codesignVerifies(installed), "empty destination: codesign --verify --deep --strict accepts the copy")
        check(Fixture.quarantined(in: installed).isEmpty, "empty destination: no quarantine left on the copy (\(Fixture.quarantined(in: installed)))")
        check(Fixture.marker(of: original) == "new" && !Fixture.quarantined(in: original).isEmpty, "empty destination: the original is untouched")
        check(Fixture.contents(of: scene.staging).isEmpty, "empty destination: the staging folder is removed")
        check(Fixture.contents(of: scene.trash).isEmpty, "empty destination: nothing went to the Trash")
    }

    private static func replacesStoppedApp(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try MoveScene(root, name: "replace")
        let original = try Fixture.app(in: scene.source, marker: "new")
        try Fixture.app(in: scene.applications, marker: "old")
        let installed = scene.applications.appendingPathComponent("SkyCut.app")
        let mover = scene.mover()
        check(mover.hasItem(at: mover.destination(for: original)), "replace: the question knows an app of that name is there")
        let outcome = mover.move(original)
        check(plain(outcome) == plain(.moved(installed)), "replace: moved (got \(outcome))")
        check(Fixture.marker(of: installed) == "new", "replace: the new app is in place")
        check(Fixture.codesignVerifies(installed), "replace: codesign accepts the new app")
        check((try? AppBundleSignature.verify(installed, matches: original)) != nil, "replace: the new app satisfies the original's requirement")
        let old = scene.trash.appendingPathComponent("SkyCut.app")
        check(Fixture.marker(of: old) == "old", "replace: the old app is in the scratch Trash, whole")
        // Signed too, but another build: it doesn't satisfy the original's requirement (its code hash, for ad-hoc).
        check((try? AppBundleSignature.verify(old, matches: original)) == nil, "replace: another build does not pass as the original")
        check(Fixture.contents(of: scene.staging).isEmpty, "replace: the staging folder is removed")
    }

    private static func leavesRunningApp(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try MoveScene(root, name: "running")
        let original = try Fixture.app(in: scene.source, marker: "new")
        let existing = try Fixture.app(in: scene.applications, marker: "old")
        let outcome = scene.mover(running: [existing.standardizedFileURL.path]).move(original)
        check(plain(outcome) == plain(.runningAtDestination(existing)), "running: refused with the running app's place (got \(outcome))")
        check(Fixture.marker(of: existing) == "old" && Fixture.codesignVerifies(existing), "running: the running app is untouched")
        check(Fixture.contents(of: scene.trash).isEmpty && Fixture.contents(of: scene.staging).isEmpty, "running: nothing copied, nothing trashed")
    }

    /// Not running when asked, started (by an AI client, say) while the copy was made: asked again right before the Trash,
    /// so the app is left where it is.
    private static func runningStartsDuringCopy(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try MoveScene(root, name: "running-later")
        let original = try Fixture.app(in: scene.source, marker: "new")
        let existing = try Fixture.app(in: scene.applications, marker: "old")
        var asked = 0
        var mover = scene.mover()
        mover.isRunning = { _ in asked += 1; return asked > 1 }
        let outcome = mover.move(original)
        check(plain(outcome) == plain(.runningAtDestination(existing)), "running later: refused right before the Trash (got \(outcome))")
        check(asked == 2, "running later: asked before the copy and again before the Trash (asked \(asked) times)")
        check(Fixture.marker(of: existing) == "old" && Fixture.codesignVerifies(existing), "running later: the app there is untouched")
        check(Fixture.contents(of: scene.trash).isEmpty && Fixture.contents(of: scene.staging).isEmpty, "running later: nothing trashed, nothing left")
    }

    private static func unwritableDestination(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try MoveScene(root, name: "unwritable")
        let original = try Fixture.app(in: scene.source, marker: "new")
        let existing = try Fixture.app(in: scene.applications, marker: "old")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scene.applications.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scene.applications.path) }
        let outcome = scene.mover().move(original)
        check(plain(outcome) == plain(.destinationNotWritable(scene.applications)), "unwritable: reported, no elevation (got \(outcome))")
        check(Fixture.marker(of: existing) == "old", "unwritable: the app there is untouched")
        check(Fixture.contents(of: scene.trash).isEmpty && Fixture.contents(of: scene.staging).isEmpty, "unwritable: nothing copied, nothing trashed")
    }

    /// A file of the original that can't be read: the copy breaks off after part of the bundle is written.
    private static func copyBreaksOff(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try MoveScene(root, name: "copy-breaks-off")
        let original = try Fixture.app(in: scene.source, marker: "new")
        let existing = try Fixture.app(in: scene.applications, marker: "old")
        let locked = original.appendingPathComponent("Contents/Resources/payload.bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let outcome = scene.mover().move(original)
        if case .failed(.copy, let detail, nil) = outcome {
            check(detail?.isEmpty == false, "copy breaks off: the system's reason is passed on")
        } else {
            check(false, "copy breaks off: failed at the copy (got \(outcome))")
        }
        check(Fixture.marker(of: existing) == "old" && Fixture.codesignVerifies(existing), "copy breaks off: the old app is still there, whole")
        check(Fixture.contents(of: scene.staging).isEmpty, "copy breaks off: the partial copy is removed")
        check(Fixture.contents(of: scene.trash).isEmpty, "copy breaks off: nothing went to the Trash")
    }

    /// The original changed after it was signed: its copy fails the check and never goes in.
    private static func signatureFails(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try MoveScene(root, name: "signature")
        let original = try Fixture.app(in: scene.source, marker: "new")
        let existing = try Fixture.app(in: scene.applications, marker: "old")
        try Data("tampered".utf8).write(to: original.appendingPathComponent("Contents/Resources/marker.txt"))
        let outcome = scene.mover().move(original)
        if case .failed(.signature, _, nil) = outcome {} else { check(false, "signature: failed at the signature (got \(outcome))") }
        check(Fixture.marker(of: existing) == "old", "signature: the old app is untouched")
        check(Fixture.contents(of: scene.staging).isEmpty && Fixture.contents(of: scene.trash).isEmpty, "signature: nothing left, nothing trashed")
    }

    /// The copy that lands is validly signed but another build (the original swapped mid-copy, say): it must fail the
    /// original's requirement, not merely its own.
    private static func swappedCopyFails(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try MoveScene(root, name: "swapped")
        let original = try Fixture.app(in: scene.source, marker: "new")
        let existing = try Fixture.app(in: scene.applications, marker: "old")
        let impostorFolder = scene.root.appendingPathComponent("impostor")
        try FileManager.default.createDirectory(at: impostorFolder, withIntermediateDirectories: true)
        let impostor = try Fixture.app(in: impostorFolder, marker: "other build")
        var mover = scene.mover()
        mover.copy = { _, staged in try FileManager.default.copyItem(at: impostor, to: staged) }
        let outcome = mover.move(original)
        if case .failed(.signature, _, nil) = outcome {} else { check(false, "swapped: failed at the signature (got \(outcome))") }
        check(Fixture.marker(of: existing) == "old", "swapped: the app there is untouched")
        check(Fixture.contents(of: scene.trash).isEmpty && Fixture.contents(of: scene.staging).isEmpty, "swapped: nothing trashed, nothing left")
    }

    private static func trashRefuses(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try MoveScene(root, name: "trash-refuses")
        let original = try Fixture.app(in: scene.source, marker: "new")
        let existing = try Fixture.app(in: scene.applications, marker: "old")
        var mover = scene.mover()
        mover.trash = { _ in throw FixtureError("the Trash refused") }
        let outcome = mover.move(original)
        check(plain(outcome) == plain(.failed(.trash, detail: "the Trash refused", oldAppInTrash: nil)), "trash refuses: failed at the Trash (got \(outcome))")
        check(Fixture.marker(of: existing) == "old", "trash refuses: the old app is untouched")
        check(Fixture.contents(of: scene.staging).isEmpty, "trash refuses: the staging folder is removed")
    }

    /// The old app went to the Trash, then the new one couldn't go in: the old one is put back.
    private static func installFailsAndRestores(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try MoveScene(root, name: "install-fails")
        let original = try Fixture.app(in: scene.source, marker: "new")
        let existing = try Fixture.app(in: scene.applications, marker: "old")
        var mover = scene.mover()
        mover.install = { _, _ in throw FixtureError("the rename failed") }
        let outcome = mover.move(original)
        check(plain(outcome) == plain(.failed(.install, detail: "the rename failed", oldAppInTrash: nil)), "install fails: failed at the install (got \(outcome))")
        check(Fixture.marker(of: existing) == "old" && Fixture.codesignVerifies(existing), "install fails: the old app is back in place, whole")
        check(Fixture.contents(of: scene.trash).isEmpty, "install fails: nothing stays in the Trash")
        check(Fixture.contents(of: scene.staging).isEmpty, "install fails: the staging folder is removed")
    }

    /// Neither the install nor putting the old app back works: the old app stays in the Trash and the outcome says where.
    private static func installAndRestoreFail(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try MoveScene(root, name: "restore-fails")
        let original = try Fixture.app(in: scene.source, marker: "new")
        try Fixture.app(in: scene.applications, marker: "old")
        var mover = scene.mover()
        mover.install = { _, _ in throw FixtureError("the rename failed") }
        mover.restore = { _, _ in throw FixtureError("the way back failed") }
        let trashed = scene.trash.appendingPathComponent("SkyCut.app")
        let outcome = mover.move(original)
        check(plain(outcome) == plain(.failed(.install, detail: "the rename failed", oldAppInTrash: trashed)), "restore fails: says where the old app is (got \(outcome))")
        check(Fixture.marker(of: trashed) == "old", "restore fails: the old app is whole in the Trash, not lost")
        check(Fixture.contents(of: scene.staging).isEmpty, "restore fails: the staging folder is removed")
    }
}
