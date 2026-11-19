import Darwin
import Foundation

// MARK: - Giving a finished file of the caller's own its name, in one step that fails when the name is taken
//
// What it does: the one place where a complete private file (hidden, unique name, next to its target on the same drive)
// becomes the visible file, without ever replacing what is at that name. The steps, in order:
//   1. `renamex_np(…, RENAME_EXCL)`: one rename that the file system refuses with EEXIST when the name is taken
//      (APFS, HFS+; FAT through the system's own check);
//   2. `link`, then removing the private name: `link` refuses a taken name the same way (a drive without the exclusive
//      rename but with hard links, such as some network shares);
//   3. on a drive with neither (exFAT, measured on macOS 26.5): the name is made with `open(O_CREAT | O_EXCL)` and the bytes
//      are copied into it through that descriptor — still made atomically and only by this process, but the copy takes
//      time and a half-copied file is visible under the name until it is done.
// A taken name answers nil and leaves the private file to the caller. Taking a name back (a set of files that could not
// keep its number) and every removal touch only what is still the caller's own file: same device and inode.
// What it doesn't: naming, numbering, staging and sets (ExclusivePlacement); replacing a file someone agreed to replace.
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-empty-name-reservation-replaced-or-removed.md): a name used to be reserved by
// creating it empty and the finished file was then renamed over that path. Whatever had replaced the empty reservation in
// between (Finder, a sync client, another app) was overwritten, and the cleanup removed any empty file at the name.
// Rules: docs/architecture/export-settings.md §5 item 9.

public enum ExclusiveInstall {
    /// The ways a file can take its name, in the order they are tried.
    public enum Step: CaseIterable, Sendable {
        case exclusiveRename
        case hardLink
        case exclusiveCopy
    }

    /// The checks only: the steps to try (to run steps 2 and 3 on a drive that supports step 1). nil = all of them.
    public nonisolated(unsafe) static var stepsForChecks: [Step]?

    /// A file that took its name: where it went, how, and which file is there now (device and inode).
    struct Installed {
        let own: ExclusivePlacement.Claim
        let url: URL
        let step: Step
        let device: dev_t
        let inode: ino_t
    }

    private static var steps: [Step] { stepsForChecks ?? Step.allCases }

    /// Gives the complete file `own` the name `url`, never replacing: nil = the name is taken (nothing replaced, `own` is
    /// still the caller's). Throws on any other failure; `own` is then still there too.
    static func install(_ own: ExclusivePlacement.Claim, at url: URL) throws -> Installed? {
        for step in steps {
            switch step {
            case .exclusiveRename:
                if renamex_np(own.url.path, url.path, UInt32(RENAME_EXCL)) == 0 { return installed(own, url, step) }
            case .hardLink:
                if link(own.url.path, url.path) == 0 { return installed(own, url, step) }
            case .exclusiveCopy:
                return try copyExclusively(from: own.url, to: url).map {
                    Installed(own: own, url: url, step: step, device: $0.device, inode: $0.inode)
                }
            }
            let code = errno
            if code == EEXIST { return nil }
            guard unsupported(code) else { throw ExclusivePlacement.failure(code, url) }
        }
        throw ExclusivePlacement.failure(ENOTSUP, url)
    }

    /// The exclusive rename alone, for a caller whose file may only ever be renamed (a screen recording's journal decides
    /// after a crash by which of the two names is there): true = renamed, false = the name is taken, nil = this drive has no
    /// exclusive rename (exFAT) and the caller decides what to do instead.
    public static func renameIfFree(_ file: URL, to url: URL) throws -> Bool? {
        if renamex_np(file.path, url.path, UInt32(RENAME_EXCL)) == 0 { return true }
        let code = errno
        if code == EEXIST { return false }
        if unsupported(code) { return nil }
        throw ExclusivePlacement.failure(code, url)
    }

    /// The install is final: the private name left by a link or a copy is removed (only while it is still the caller's).
    static func finish(_ installed: Installed) {
        guard installed.step != .exclusiveRename else { return }
        ExclusivePlacement.discard(installed.own)
    }

    /// Takes the name back (a set that could not keep its number): the caller's file returns to its private name, or the
    /// copy made at the name is removed — only while what is at the name is still the caller's. Whatever else is there by
    /// then is left alone.
    static func undo(_ installed: Installed) {
        guard isFile(installed.url, device: installed.device, inode: installed.inode) else { return }
        guard installed.step == .exclusiveRename else {
            unlink(installed.url.path)
            return
        }
        guard renamex_np(installed.url.path, installed.own.url.path, UInt32(RENAME_EXCL)) == 0 else { return }
        // Moved something that was not the caller's (replaced in the instant between the look and the rename): put it back.
        if !isFile(installed.own.url, device: installed.own.device, inode: installed.own.inode) {
            renamex_np(installed.own.url.path, installed.url.path, UInt32(RENAME_EXCL))
        }
    }

    /// Whether `folder`'s drive gives a file its name without copying it (step 1 or 2), tried on two private names. A drive
    /// that refuses the test file itself answers true: the real write then says what is wrong.
    static func takesNamesWithoutCopying(in folder: URL) -> Bool {
        let allowed = steps.filter { $0 != .exclusiveCopy }
        guard !allowed.isEmpty else { return false }
        guard let probe = try? ExclusivePlacement.scratch(in: folder, stem: "install-check", pathExtension: "tmp") else { return true }
        let moved = folder.appendingPathComponent(".install-check.\(UUID().uuidString).tmp")
        // Two private names made just now, removed by name: FAT numbers an empty file anew when it is renamed, so its
        // inode can't tell them apart.
        defer {
            unlink(probe.url.path)
            unlink(moved.path)
        }
        for step in allowed {
            let done = step == .exclusiveRename
                ? renamex_np(probe.url.path, moved.path, UInt32(RENAME_EXCL)) : link(probe.url.path, moved.path)
            if done == 0 { return true }
            guard unsupported(errno) else { return true }
        }
        return false
    }

    /// Step 3, and the copy straight onto a drive without steps 1 and 2: makes `url` with O_EXCL and copies `source`'s
    /// bytes into it through that descriptor. nil = the name is taken. A copy that fails removes only the file it made.
    static func copyExclusively(from source: URL, to url: URL) throws -> (device: dev_t, inode: ino_t)? {
        let target = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard target >= 0 else {
            let code = errno
            if code == EEXIST { return nil }
            throw ExclusivePlacement.failure(code, url)
        }
        let input = open(source.path, O_RDONLY)
        var code: Int32 = 0
        if input < 0 {
            code = errno
        } else {
            if fcopyfile(input, target, nil, copyfile_flags_t(COPYFILE_DATA)) != 0 { code = errno == 0 ? EIO : errno }
            close(input)
        }
        if code == 0, fsync(target) != 0 { code = errno }
        // Which file this is, read only now: FAT and exFAT number an empty file differently from the same file once it holds
        // data (measured: −3, then 7).
        var info = stat()
        let known = fstat(target, &info) == 0
        if code == 0, !known { code = errno }
        close(target)
        guard code == 0 else {
            if known, isFile(url, device: info.st_dev, inode: info.st_ino) { unlink(url.path) }
            throw ExclusivePlacement.failure(code, url)
        }
        return (info.st_dev, info.st_ino)
    }

    /// `url` is the regular file with this device and inode (not followed through a symbolic link).
    static func isFile(_ url: URL, device: dev_t, inode: ino_t) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_dev == device && info.st_ino == inode
    }

    private static func installed(_ own: ExclusivePlacement.Claim, _ url: URL, _ step: Step) -> Installed {
        Installed(own: own, url: url, step: step, device: own.device, inode: own.inode)
    }

    /// The drive does not do this step (go on to the next one), as opposed to a real failure (no space, no permission…).
    private static func unsupported(_ code: Int32) -> Bool {
        [ENOTSUP, EOPNOTSUPP, EINVAL, EPERM, EXDEV].contains(code)
    }
}
