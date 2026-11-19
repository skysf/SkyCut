import Darwin
import Foundation
import SrtFlowCore

// MARK: - Writing a file at a chosen place without replacing one nobody agreed to replace
//
// What it does: the write behind a Save As / Export As to a place the person chose. When replacing a file already there
// was not confirmed (a typed or dropped answer in the file-window helper, a name the caller completed), the bytes are
// written under a private hidden name next to the target and then take the name in one step that fails when it is taken
// (ExclusivePlacement.create): a file already there, or one that appears during the write, is never touched, and the caller
// hears `.occupied` (it may ask "Replace?" and write again). When replacing was confirmed for exactly that URL: the plain
// atomic write.
// What it doesn't: asking the person (FileReplaceQuestion); deciding whether replacing was confirmed (SaveLocation); which
// thread the write runs on (the callers: ProjectFileWriter's queue, the subtitle editor).
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-save-window-fallback-replaces-a-file.md): `Data.write(.atomic)` replaces
// whatever is at the path, and the helper's typed and dropped answers skip the "Replace?" that macOS's own window asks.
// The name is no longer reserved empty before the write
// (docs/bugfixes/2026-11-19-empty-name-reservation-replaced-or-removed.md): whatever replaced the reservation was overwritten,
// and a failed write's cleanup removed any empty file at the name.

enum NewFileClaim {
    enum Outcome: Equatable {
        case written
        /// A file is already there and replacing it was not confirmed: nothing written, that file untouched.
        case occupied
    }

    /// `data` at `url`. `replacing`: replacing a file already there was confirmed for exactly `url`.
    static func write(_ data: Data, to url: URL, replacing: Bool) throws -> Outcome {
        if replacing {
            try data.write(to: url, options: .atomic)
            return .written
        }
        return try ExclusivePlacement.create(url, writing: { try data.write(to: $0) }) == nil ? .occupied : .written
    }

    /// Something is at `url` (a file, a folder, a symbolic link — even one that leads nowhere). Only a first look: the
    /// write itself is what refuses a taken name.
    static func isTaken(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// What the person is told when a file is already there and nobody asked: the system's own words, like the other
    /// write failures.
    static func occupiedReason(_ url: URL) -> String {
        CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path]).localizedDescription
    }
}
