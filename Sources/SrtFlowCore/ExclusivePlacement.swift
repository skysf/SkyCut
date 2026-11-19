import Darwin
import Foundation

// MARK: - Putting a new file into a folder without ever replacing what is already there
//
// What it does: the last step of every file SkyCut writes without a confirmed Replace (docs/architecture/export-settings.md
// §5 items 6, 8 and 9) — the AI's export_video and export_subtitles, Compress / Burn In, a Save As or Export As nobody
// confirmed. The complete file is first written under a private hidden name next to its target (same drive), and only
// then takes its name in one step that fails when the name is taken (ExclusiveInstall). The final name is never reserved
// empty beforehand. A taken name is never touched: a numbered series moves on (`name 2.ext`, `name 3.ext`…, counting on
// from the number given; a set of subtitle files moves on together), an exact name answers nil and the caller decides
// (ask, or say so). Onto another drive the file is first copied next to its target under a hidden name, except on a drive
// that can't give a name without copying (exFAT): there it is copied straight into a file made with O_EXCL, once.
// A long write that must not go into the finished name itself (a Compress / Burn In encode) goes into a scratch file of the
// caller's own, hidden next to the target (`scratch`); it is placed when it is finished, and when it fails or is cancelled
// only that file is removed (`discard`: only while it is still the file the caller created).
// What it doesn't: picking the first name from the folder's listing and other exports' reservations (the callers, with
// ExportFileName.unoccupiedNumber); replacing a file the user said to replace (ExportDelivery's `.replacing`,
// SubtitleExportPlanner.writeValidated(_:format:to:)).
// Why (2026-11-19): docs/bugfixes/2026-11-19-parallel-ai-exports-pick-the-same-name.md; the scratch file:
// docs/bugfixes/2026-11-19-compress-burn-overwrite-and-delete.md; no empty reservation:
// docs/bugfixes/2026-11-19-empty-name-reservation-replaced-or-removed.md.

public enum ExclusivePlacement {
    /// A file of the caller's own: made by it under a private name, known by its device and inode.
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

    /// A file of the caller's own for a long write, hidden in `folder` next to where the finished file will go (same drive:
    /// placing it is a rename): created empty with O_EXCL under a name nobody else uses, so whatever is there later was
    /// written by the caller. `pathExtension` stays last (ffmpeg picks the container from it). Place it when it is finished
    /// (`place`), `discard` it when the write fails or is cancelled.
    public static func scratch(in folder: URL, stem: String, pathExtension: String) throws -> Claim {
        let naming = "into “\(folder.lastPathComponent)”"
        for _ in 0..<3 {
            let name = ".\(short(stem)).partial-\(UUID().uuidString)"
            let url = folder.appendingPathComponent(name).appendingPathExtension(pathExtension)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard descriptor >= 0 else {
                let code = errno
                if code == EEXIST { continue }
                throw failure(code, naming: naming)
            }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                let code = errno
                unlink(url.path)
                throw failure(code, naming: naming)
            }
            return Claim(url: url, device: info.st_dev, inode: info.st_ino)
        }
        throw Failure(message: "SkyCut could not write \(naming): its temporary names are taken.")
    }

    /// Removes the caller's own file whatever it holds by now (a write that failed or was cancelled, a private copy that
    /// took its name by a link or a copy), and only while it is still that file (same device and inode): never a file
    /// someone else put there.
    public static func discard(_ claim: Claim) {
        guard ExclusiveInstall.isFile(claim.url, device: claim.device, inode: claim.inode) else { return }
        unlink(claim.url.path)
    }

    /// A new file at exactly `url`, never replacing: `write` makes a complete regular file at the private path it is given
    /// (hidden, next to `url`), which then takes the name. nil = the name is taken (by a file that was there or that appeared
    /// while writing): that file is untouched and the private file removed. On a failure nothing at `url` is touched either.
    public static func create<T>(_ url: URL, writing write: (URL) throws -> T) throws -> T? {
        var result: T?
        let made = try stage([url]) { _, path in result = try write(path) }
        defer { made.forEach(discard) }
        guard try install(made, names: { _ in [url] }, numbers: 1...1) != nil else { return nil }
        return result
    }

    /// Files that belong together (`Talk.en.srt` + `Talk.zh-Hans.srt`): `write(i, path)` makes file i complete at a private
    /// path next to its name (all of them before any takes a name); then they take the names of set `number` of `names`, or
    /// of the next set none of whose names is taken at that moment — a set never ends up under two numbers. Returns the set's
    /// number and where the files went, in the order `names` gives them.
    public static func createSet(
        from number: Int, _ names: (Int) -> [URL], writing write: (Int, URL) throws -> Void
    ) throws -> (number: Int, urls: [URL]) {
        let first = max(1, number)
        let made = try stage(names(first), write)
        defer { made.forEach(discard) }
        guard let placed = try install(made, names: names, numbers: first..<(first + attempts)) else {
            throw exhausted(names(first).first)
        }
        return placed
    }

    /// Puts the finished `file` into `folder` under name `number` of the series (`ExportFileName.numbered`), or the next one
    /// that is free at that moment. Returns where it went. On the same drive `file` itself takes the name (moved); onto
    /// another drive it is copied and left for its owner to clean up. `copying`: for the checks (one drive on a CI machine);
    /// nil = whether the drives differ.
    public static func place(
        _ file: URL, in folder: URL, stem: String, pathExtension: String, from number: Int, copying: Bool? = nil
    ) throws -> URL {
        let names = { [ExportFileName.numbered($0, in: folder, stem: stem, pathExtension: pathExtension)] }
        let numbers = max(1, number)..<(max(1, number) + attempts)
        let copies = try copying ?? (device(of: file) != device(of: folder))
        if !copies {
            guard let placed = try install([own(file)], names: names, numbers: numbers) else { throw exhausted(names(numbers.lowerBound).first) }
            return placed.urls[0]
        }
        guard ExclusiveInstall.takesNamesWithoutCopying(in: folder) else {
            // A drive that can only make a name by creating it (exFAT): one copy, straight into a file made with O_EXCL.
            for candidate in numbers {
                let url = names(candidate)[0]
                if try ExclusiveInstall.copyExclusively(from: file, to: url) != nil { return url }
            }
            throw exhausted(names(numbers.lowerBound).first)
        }
        // Hidden, next to the target: the long copy happens before any name is taken.
        let made = try stage(names(numbers.lowerBound)) { _, path in try FileManager.default.copyItem(at: file, to: path) }
        defer { made.forEach(discard) }
        guard let placed = try install(made, names: names, numbers: numbers) else { throw exhausted(names(numbers.lowerBound).first) }
        return placed.urls[0]
    }

    // MARK: - Steps

    /// Makes each file complete at a private path next to its name (`write(i, path)`). A failure removes what was made.
    private static func stage(_ names: [URL], _ write: (Int, URL) throws -> Void) throws -> [Claim] {
        var made: [Claim] = []
        do {
            for (index, name) in names.enumerated() {
                let path = name.deletingLastPathComponent().appendingPathComponent(".\(short(name.lastPathComponent)).partial-\(UUID().uuidString)")
                do {
                    try write(index, path)
                    made.append(try own(path))
                } catch {
                    unlink(path.path)  // the private name: nobody else's
                    throw error
                }
            }
        } catch {
            made.forEach(discard)
            throw error
        }
        return made
    }

    /// The files take the names of the first number in `numbers` whose names are all free at that moment; a set that
    /// meets a taken name gives back the names it already took. nil = every number was taken.
    private static func install(
        _ made: [Claim], names: (Int) -> [URL], numbers: some Sequence<Int>
    ) throws -> (number: Int, urls: [URL])? {
        for candidate in numbers {
            let urls = names(candidate)
            var taken: [ExclusiveInstall.Installed] = []
            var complete = true
            do {
                for (own, url) in zip(made, urls) {
                    guard let installed = try ExclusiveInstall.install(own, at: url) else { complete = false; break }
                    taken.append(installed)
                }
            } catch {
                taken.reversed().forEach(ExclusiveInstall.undo)
                throw error
            }
            guard complete else {
                taken.reversed().forEach(ExclusiveInstall.undo)
                continue
            }
            taken.forEach(ExclusiveInstall.finish)
            return (candidate, urls)
        }
        return nil
    }

    /// The finished file at `url` as the caller's own: a regular file (not a symbolic link), by device and inode.
    private static func own(_ url: URL) throws -> Claim {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw failure(errno, url) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw failure(EINVAL, url) }
        return Claim(url: url, device: info.st_dev, inode: info.st_ino)
    }

    /// A piece of a name short enough that `.<piece>.partial-<UUID>.<ext>` stays within the file system's 255 bytes.
    private static func short(_ name: String) -> String {
        var piece = ""
        for character in name {
            guard piece.utf8.count + String(character).utf8.count <= 120 else { break }
            piece.append(character)
        }
        return piece
    }

    private static func device(of url: URL) throws -> dev_t {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw failure(errno, url) }
        return info.st_dev
    }

    private static func exhausted(_ first: URL?) -> Failure {
        Failure(message: "Every name from “\(first?.lastPathComponent ?? "")” on is already taken in its folder; nothing was replaced.")
    }

    static func failure(_ code: Int32, _ url: URL) -> Failure { failure(code, naming: "“\(url.lastPathComponent)”") }

    private static func failure(_ code: Int32, naming: String) -> Failure {
        Failure(message: "SkyCut could not write \(naming): \(String(cString: strerror(code))).")
    }
}
