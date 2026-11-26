import Foundation

// InstallerDisk on real scratch disk images (scripts/check-move-to-applications.sh): a compressed read-only image with the
// app at its top is found, with its mount point and whole disk; a writable image and a plain folder are not; the eject
// waits for the process it was given to exit, then detaches the image. Images are attached with -nobrowse at a scratch
// mount point, so Finder never shows them; the script detaches anything left on exit.

enum DiskChecks {
    static func run(in root: URL, check: (Bool, String) -> Void) throws {
        let folder = root.appendingPathComponent("disk-images")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let content = folder.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        let app = try Fixture.app(in: content, marker: "disk")

        check(InstallerDisk.containing(app) == nil, "a plain folder is not a disk image")

        let readOnly = folder.appendingPathComponent("installer.dmg")
        let mount = folder.appendingPathComponent("mount")
        try image(["create", "-quiet", "-srcfolder", content.path, "-volname", "SkyCutMoveCheck", "-format", "UDZO", readOnly.path])
        try image(["attach", "-quiet", "-nobrowse", "-noautoopen", "-noverify", "-readonly", "-mountpoint", mount.path, readOnly.path])
        let mounted = mount.appendingPathComponent("SkyCut.app")
        let disk = InstallerDisk.containing(mounted)
        check(disk != nil, "a read-only disk image is found")
        if let disk {
            check(disk.mountPoint.standardizedFileURL.path == mount.standardizedFileURL.path, "the image's mount point (got \(disk.mountPoint.path))")
            check(disk.wholeDisk.range(of: #"\A/dev/disk[0-9]+\z"#, options: .regularExpression) != nil, "the image's whole disk (got \(disk.wholeDisk))")
            check(disk.holdsAtTop(mounted), "the app at the image's top counts as at its top")
            check(!disk.holdsAtTop(mount.appendingPathComponent("Folder/SkyCut.app")), "an app in a subfolder of the image does not")
            // Never opened, so normally never registered; unregistered anyway before its image goes.
            Tool.run(lsregister, ["-u", mounted.path])
            try ejectWaitsForExit(disk, mount: mount, check: check)
        }

        let writable = folder.appendingPathComponent("writable.dmg")
        let writableMount = folder.appendingPathComponent("writable-mount")
        try image(["create", "-quiet", "-size", "8m", "-fs", "HFS+", "-volname", "SkyCutMoveWritable", writable.path])
        try image(["attach", "-quiet", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", writableMount.path, writable.path])
        defer { _ = Tool.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", writableMount.path]) }
        check(InstallerDisk.containing(writableMount) == nil, "a writable disk image is not the installer disk")
    }

    /// The eject waits while the given process runs, then detaches the image within seconds of its exit.
    private static func ejectWaitsForExit(_ disk: InstallerDisk, mount: URL, check: (Bool, String) -> Void) throws {
        let waitedOn = Process()
        waitedOn.executableURL = URL(fileURLWithPath: "/bin/sleep")
        waitedOn.arguments = ["2"]
        try waitedOn.run()
        disk.ejectAfterExit(of: waitedOn.processIdentifier)
        Thread.sleep(forTimeInterval: 1)
        check(isMounted(mount), "the eject waits while the process runs")
        waitedOn.waitUntilExit()
        let deadline = Date().addingTimeInterval(20)
        while isMounted(mount), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        check(!isMounted(mount), "the image is detached after the process exits")
    }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Something is mounted at this point: its device differs from its parent folder's.
    static func isMounted(_ point: URL) -> Bool {
        var here = stat(), parent = stat()
        guard stat(point.path, &here) == 0, stat(point.deletingLastPathComponent().path, &parent) == 0 else { return false }
        return here.st_dev != parent.st_dev
    }

    private static func image(_ arguments: [String]) throws {
        let result = Tool.run("/usr/bin/hdiutil", arguments)
        guard result.status == 0 else { throw FixtureError("hdiutil \(arguments.first ?? ""): \(result.output)") }
    }
}
