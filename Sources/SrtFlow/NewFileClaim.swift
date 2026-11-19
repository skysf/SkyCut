import Darwin
import Foundation

// MARK: - Writing a file at a chosen place without replacing one nobody agreed to replace
//
// What it does: the write behind a Save As / Export As to a place the person chose. When replacing a file already there
// was not confirmed (a typed or dropped answer in the file-window helper, a name the caller completed), the name is claimed
// first — an empty file made only if nothing is there (`O_EXCL`) — and then written atomically over that claim: a file
// already there is never touched, and the caller hears `.occupied` (it may ask "Replace?" and write again). When replacing
// was confirmed for exactly that URL: the plain atomic write.
// What it doesn't: asking the person (FileReplaceQuestion); deciding whether replacing was confirmed (SaveLocation); which
// thread the write runs on (the callers: ProjectFileWriter's queue, the subtitle editor).
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-save-window-fallback-replaces-a-file.md): `Data.write(.atomic)` replaces
// whatever is at the path, and the helper's typed and dropped answers skip the "Replace?" that macOS's own window asks.

enum NewFileClaim {
    enum Outcome: Equatable {
        case written
        /// A file is already there and replacing it was not confirmed: nothing written, that file untouched.
        case occupied
    }

    /// `data` at `url`, written atomically. `replacing`: replacing a file already there was confirmed for exactly `url`.
    static func write(_ data: Data, to url: URL, replacing: Bool) throws -> Outcome {
        if replacing {
            try data.write(to: url, options: .atomic)
            return .written
        }
        guard try claim(url) else { return .occupied }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            release(url)
            throw error
        }
        return .written
    }

    /// Makes an empty file at `url` only if nothing is there yet (`O_EXCL`, which also refuses a symbolic link left there):
    /// true = claimed, false = something is already there. Other failures (no such folder, a read-only drive) throw.
    static func claim(_ url: URL) throws -> Bool {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if descriptor >= 0 {
            close(descriptor)
            return true
        }
        let code = errno
        if code == EEXIST { return false }
        throw writeError(code, url)
    }

    /// Gives back a claim whose write failed: removes the empty file it made, never a file with content.
    static func release(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.int64Value == 0 else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// What the person is told when a file is already there and nobody asked: the system's own words, like the other
    /// write failures.
    static func occupiedReason(_ url: URL) -> String {
        CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path]).localizedDescription
    }

    /// The system's wording for a failed claim (what `Data.write` would have said).
    private static func writeError(_ code: Int32, _ url: URL) -> CocoaError {
        let kind: CocoaError.Code
        switch code {
        case ENOENT, ENOTDIR: kind = .fileNoSuchFile
        case EACCES, EPERM: kind = .fileWriteNoPermission
        case EROFS: kind = .fileWriteVolumeReadOnly
        case ENOSPC, EDQUOT: kind = .fileWriteOutOfSpace
        default: kind = .fileWriteUnknown
        }
        let underlying = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        return CocoaError(kind, userInfo: [NSFilePathErrorKey: url.path, NSUnderlyingErrorKey: underlying])
    }
}
