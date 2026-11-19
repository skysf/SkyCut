import Darwin
import Foundation

// MARK: - Putting a new file into a folder without ever replacing what is already there
//
// What it does: the last step of the files SkyCut writes without asking first, so it must never replace anything
// (docs/architecture/export-settings.md §5 item 6) — the AI's export_video and export_subtitles. A name is claimed by
// creating it empty with `open(O_CREAT | O_EXCL)`, which the file system answers atomically, and the finished file is
// then renamed over that empty claim. A file that appeared after the folder was listed (Finder, another app, another
// export in SkyCut) is never replaced: the next name of the series is claimed instead (`name 2.ext`, `name 3.ext`…; a
// set of subtitle files moves on together). Onto another drive the file is first copied next to its target under a
// hidden temporary name, so the empty claim exists only for the instant of the rename.
// What it doesn't: picking the first name from the folder's listing and other exports' reservations (the callers, with
// ExportFileName.unoccupiedNumber); replacing a file the user said to replace (ExportDelivery's `.replacing`,
// SubtitleExportPlanner.writeValidated(_:format:to:)).
// Why (2026-11-19): docs/bugfixes/2026-11-19-parallel-ai-exports-pick-the-same-name.md.

public enum ExclusivePlacement {
    /// A name this process holds: the empty file it created there, known by its inode.
    public struct Claim: Sendable, Equatable {
        public let url: URL
        let device: dev_t
        let inode: ino_t
    }

    public struct Failure: LocalizedError, Sendable {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// How many names of a series are tried before giving up (a folder holding that many is not a real case).
    static let attempts = 1000

    /// Claims `url` for a new file: creates it empty, atomically, only when nothing is there. nil = something already is.
    public static func claim(_ url: URL) throws -> Claim? {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            let code = errno
            if code == EEXIST { return nil }
            throw failure(code, url)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            unlink(url.path)
            throw failure(code, url)
        }
        return Claim(url: url, device: info.st_dev, inode: info.st_ino)
    }

    /// Gives a claim back: removes the empty file, and only while it is still the one this process created.
    public static func release(_ claim: Claim) {
        var info = stat()
        guard lstat(claim.url.path, &info) == 0, info.st_dev == claim.device, info.st_ino == claim.inode,
              info.st_size == 0 else { return }
        unlink(claim.url.path)
    }

    /// Renames `file` (on the claim's drive) over the claim. On failure the claim is still there; give it back.
    public static func fill(_ claim: Claim, with file: URL) throws {
        guard rename(file.path, claim.url.path) == 0 else { throw failure(errno, claim.url) }
    }

    /// Puts `file` into `folder` under name `number` of the series (`ExportFileName.numbered`), or the next one that is
    /// free at the moment of the move. Returns where it went. `file` is moved; onto another drive it is copied and left
    /// for its owner to clean up. `copying`: for the checks (one drive on a CI machine); nil = whether the drives differ.
    public static func place(
        _ file: URL, in folder: URL, stem: String, pathExtension: String, from number: Int, copying: Bool? = nil
    ) throws -> URL {
        let copies = try copying ?? (device(of: file) != device(of: folder))
        var source = file
        if copies {
            // Hidden, next to the target: the long copy happens before any name is claimed.
            source = folder.appendingPathComponent(".\(stem).\(pathExtension).partial-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: file, to: source)
        }
        // After a successful rename the temporary copy is already gone.
        defer { if copies { try? FileManager.default.removeItem(at: source) } }
        let (_, claims) = try claimSet(from: number) {
            [ExportFileName.numbered($0, in: folder, stem: stem, pathExtension: pathExtension)]
        }
        do {
            try fill(claims[0], with: source)
        } catch {
            release(claims[0])
            throw error
        }
        return claims[0].url
    }

    /// Claims every name of one set of files that belong together (`Talk.en.srt` + `Talk.zh-Hans.srt`), starting with
    /// set `number` of `names`: when any name of a set is taken, that set's claims are given back and the next set is
    /// tried. Returns the set's number and its claims, in the order `names` gave the files.
    public static func claimSet(from number: Int, _ names: (Int) -> [URL]) throws -> (number: Int, claims: [Claim]) {
        var candidate = max(1, number)
        for _ in 0..<attempts {
            let set = names(candidate)
            var claims: [Claim] = []
            do {
                for url in set {
                    guard let claim = try claim(url) else { break }
                    claims.append(claim)
                }
            } catch {
                claims.forEach(release)
                throw error
            }
            if claims.count == set.count { return (candidate, claims) }
            claims.forEach(release)
            candidate += 1
        }
        let first = names(max(1, number)).first?.lastPathComponent ?? ""
        throw Failure(message: "Every name from “\(first)” on is already taken in its folder; nothing was replaced.")
    }

    private static func device(of url: URL) throws -> dev_t {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw failure(errno, url) }
        return info.st_dev
    }

    private static func failure(_ code: Int32, _ url: URL) -> Failure {
        Failure(message: "SkyCut could not write “\(url.lastPathComponent)”: \(String(cString: strerror(code))).")
    }
}
