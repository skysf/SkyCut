import DiskArbitration
import Foundation

// MARK: - The disk image SkyCut runs from, and ejecting it after SkyCut has quit
//
// What it does: tells whether a file is on a read-only volume backed by a disk image (DiskArbitration's device model
// "Disk Image"), with the volume's mount point and the image's whole disk ("/dev/disk6"); and, once SkyCut has moved
// itself to Applications and reopened from there, ejects that image after this process has exited, from a small shell
// that outlives it.
// What it doesn't: decide whether to offer the move (MoveToApplicationsOffer) or move (AppBundleMover).
// Rules: docs/build/build-and-packaging.md "Installing from the DMG".

struct InstallerDisk: Equatable, Sendable {
    /// The volume's mount point (`/Volumes/SkyCut`).
    let mountPoint: URL
    /// The image's whole disk, `/dev/diskN`: what `hdiutil detach` takes (every volume of the image goes with it).
    let wholeDisk: String

    /// The read-only disk image `url` is on; nil for anything else: the startup disk, a writable image, an external drive,
    /// a network volume, a translocated view (its volume is not a disk).
    static func containing(_ url: URL) -> InstallerDisk? {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsReadOnlyKey]),
              values.volumeIsReadOnly == true, let volume = values.volume,
              let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              description[kDADiskDescriptionDeviceModelKey as String] as? String == "Disk Image",
              let whole = DADiskCopyWholeDisk(disk), let name = DADiskGetBSDName(whole) else { return nil }
        let device = "/dev/" + String(cString: name)
        guard device.range(of: #"\A/dev/disk[0-9]+\z"#, options: .regularExpression) != nil else { return nil }
        return InstallerDisk(mountPoint: volume.standardizedFileURL, wholeDisk: device)
    }

    /// The bundle sits at the top of the volume, as on SkyCut's installer disk. Only then is the disk ejected after a move:
    /// an image that holds SkyCut in a subfolder is somebody's own and stays mounted.
    func holdsAtTop(_ bundle: URL) -> Bool {
        Self.trimmed(bundle.standardizedFileURL.deletingLastPathComponent().path) == Self.trimmed(mountPoint.path)
    }

    /// Detaches the image once process `pid` has exited: polled every 0.1 s, given up after 60 s. `hdiutil detach` without
    /// -force, so an image something still uses (a file open on it, a translocated copy over it) simply stays mounted.
    /// Fire and forget: the shell runs in its own process group and outlives SkyCut (measured 2026-11-26, macOS 26.5.2).
    func ejectAfterExit(of pid: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The pid and the device go in as arguments ($1, $2), never into the script's text.
        process.arguments = ["-c", Self.ejectScript, "sh", String(pid), wholeDisk]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Waits for $1 to exit (at most 600 polls), then detaches $2.
    static let ejectScript = """
        i=0; while kill -0 "$1" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 600 ] && exit 0; sleep 0.1; done; \
        exec /usr/bin/hdiutil detach "$2" -quiet
        """

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
