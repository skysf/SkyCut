import Foundation
import SrtFlowCore

// MARK: - What Compress / Burn In ask an output folder, never on the main thread
//
// Owns: the name rule for an item's finished file (`target`: `<input name><suffix>.mp4`, numbered past the names in the folder,
// the names other items still to be written have planned, and the input itself), the look at a folder's names that rule
// needs (`names`) and the finished file's size (`size`). Both go to the drive only through ExportDestinationProbe: on a GCD
// thread with the export panel's 5 s deadline for a look, at most three checks left waiting on one drive.
// Does not own: when an item is named again (EncodeQueue: on adding, on another output folder, once a listing is back) or
// writing the file (EncodeJob: it never replaces anything, so a name taken after the look only moves the file on).
// Why (2026-11-19, docs/bugfixes/2026-11-19-drive-checks-on-main-thread.md): the name pick asked `fileExists` for each
// candidate on the main thread, the same class as the export panel's freeze on a sleeping or stuck drive
// (docs/bugfixes/2026-11-18-export-folder-chooser-freezes-app.md). Rules: docs/architecture/export-settings.md §5 item 8, §8.
enum EncodeOutputFolder {
    /// The export panel's deadline for a look at a folder (no write test): an asleep drive may need this long to answer.
    static let lookDeadline: TimeInterval = 5

    /// The file an item gets in `folder`: name `number` of `<stem><suffix>.mp4`, past `taken` (the folder's names, folded),
    /// `planned` (other items' files still to be written, `key`) and the input (ffmpeg reading and writing one file destroys it).
    static func target(for input: URL, in folder: URL, suffix: String, planned: Set<String>, taken: Set<String>) -> ExportTarget {
        let stem = input.deletingPathExtension().lastPathComponent + suffix
        // 撞名加编号（规则只有 ExportFileName 一份）；绝不能写到源文件上。
        let number = ExportFileName.unoccupiedNumber(in: folder, stem: stem, pathExtension: "mp4") { candidate in
            planned.contains(key(candidate)) || candidate.standardizedFileURL == input.standardizedFileURL
                || taken.contains(ExportDestinationReport.fold(candidate.lastPathComponent))
        }
        return .newFile(folder: folder, stem: stem, pathExtension: "mp4", number: number)
    }

    /// The names in `folder` (folded), looked at off the main thread; nil when it is missing or does not answer in time.
    static func names(in folder: URL, probe: ExportDestinationProbe, deadline: TimeInterval = lookDeadline) async -> Set<String>? {
        let report = await probe.inspect(folder, writeTest: false, deadline: deadline)
        return report.problem == nil ? report.names : nil
    }

    /// The finished file's size, read off the main thread; nil when its drive does not answer in time.
    static func size(of file: URL, probe: ExportDestinationProbe) async -> Int64? {
        await probe.run(on: file.deletingLastPathComponent(), deadline: lookDeadline, timedOut: nil) { _ in MediaProbe.byteSize(of: file) }
    }

    /// Names compared the way the default macOS volumes compare them (`Clip` and `clip` are one file).
    static func key(_ url: URL) -> String { ExportDestinationReport.fold(url.standardizedFileURL.path) }
}
