import Darwin
import Foundation

// MARK: - Checking the export destination without waiting on the drive on the main thread
//
// What it does: everything the export panel needs to know about its destination folder — is it there, is it a folder,
// is the drive read-only, can SkyCut write into it, which names are already taken — on a background thread with a
// deadline. A sleeping, slow, read-only or stuck external drive never freezes the panel: past the deadline the answer
// is "not responding" and the stuck call is left to finish (or not) on its own thread.
// The AI's export_video goes through the same probe (`run`, AIExportDestination): its folder is made, checked and listed
// here too, with the same deadline and the same answers.
// What it doesn't: what the panel shows (ExportDestinationState, ExportFolderRow); writing the video
// (ExportDelivery); which folder the AI exports into (AIExportDestination).
//
// Why (2026-11-18, docs/bugfixes/2026-11-18-export-folder-chooser-freezes-app.md): the export panel asked the drive
// `fileExists` on the main thread several times per redraw, and an NTFS (read-only) or permission-less destination was
// only found out after the whole encode. Rules: docs/architecture/export-settings.md and blocking-media-reads.md.

enum ExportDestinationProblem: Equatable, Sendable {
    case missing
    case notAFolder
    /// The drive itself is mounted read-only (an NTFS drive without extra software, a locked card…).
    case readOnlyVolume
    /// Creating a file in the folder failed; the system's reason.
    case notWritable(String)
    /// The drive did not answer within the deadline (asleep, slow, unplugged mid-way, stuck).
    case noResponse
}

struct ExportDestinationReport: Equatable, Sendable {
    var problem: ExportDestinationProblem?
    /// Every name in the folder, folded the way the default macOS volumes compare names.
    var names: Set<String> = []

    /// Is a file with this name already in the folder? (Same answer `fileExists` gives on a case-insensitive volume.)
    func contains(_ fileName: String) -> Bool { names.contains(Self.fold(fileName)) }

    static func fold(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }
}

final class ExportDestinationProbe: @unchecked Sendable {
    /// The file-system calls (a seam: the checks pass a drive that never answers or is read-only).
    struct FileSystem: Sendable {
        enum Kind: Sendable { case missing, file, folder }
        var kind: @Sendable (URL) -> Kind
        var names: @Sendable (URL) -> [String]
        var isReadOnlyVolume: @Sendable (URL) -> Bool
        /// Creates and removes a small hidden file; nil when that worked, otherwise why not.
        var writeTest: @Sendable (URL) -> ExportDestinationProblem?
        /// Makes the folder and any missing parents (the AI's export folder); nil when it is there now, otherwise why not.
        var createFolder: @Sendable (URL) -> ExportDestinationProblem? = { url in
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return nil
            } catch {
                return ExportDestinationProbe.problem(creating: error)
            }
        }
        /// A file's bytes (the AI encode tools' subtitle files, AIEncodeInputs).
        var read: @Sendable (URL) throws -> Data = { url in try Data(contentsOf: url) }
        /// Writes a new file; never replaces one that is there (convert_subtitles' outputs, AIEncodeInputs).
        var writeNew: @Sendable (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .withoutOverwriting) }

        static let live = FileSystem(
            kind: { url in
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return .missing }
                return isFolder.boolValue ? .folder : .file
            },
            names: { url in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] },
            isReadOnlyVolume: { url in
                (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
            },
            writeTest: { url in
                // Temporary-file prefixes are identity-class names: SrtFlow (docs/architecture/product-name.md).
                let path = url.appendingPathComponent(".SrtFlow-write-check-\(UUID().uuidString)").path
                let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                if fd < 0 {
                    let code = errno
                    return code == EROFS ? .readOnlyVolume : .notWritable(String(cString: strerror(code)))
                }
                close(fd)
                unlink(path)
                return nil
            }
        )
    }

    static let shared = ExportDestinationProbe(fileSystem: .live)

    /// At most this many checks per drive still out: on a stuck drive each one is a thread that may never come back,
    /// and they must not pile up (GCD has a bounded thread pool).
    static let outstandingPerDrive = 3

    let fileSystem: FileSystem
    private let lock = NSLock()
    private var outstanding: [String: Int] = [:]

    init(fileSystem: FileSystem) {
        self.fileSystem = fileSystem
    }

    /// Checks `folder`; `writeTest` also creates and removes a hidden file in it (before an export, not on every redraw).
    /// Never waits longer than `deadline`; the work runs on a GCD thread, never on the caller's.
    func inspect(_ folder: URL, writeTest: Bool, deadline: TimeInterval) async -> ExportDestinationReport {
        await run(on: folder, deadline: deadline, timedOut: ExportDestinationReport(problem: .noResponse)) { fileSystem in
            Self.check(folder, writeTest: writeTest, fileSystem: fileSystem)
        }
    }

    /// Runs `work` against the drive `folder` is on, on a GCD thread (never the caller's, never the cooperative pool),
    /// and never waits longer than `deadline`: past it the answer is `timedOut` and the stuck call is left to finish on
    /// its own thread. Shares the per-drive cap with every other check (`outstandingPerDrive`).
    func run<Value: Sendable>(
        on folder: URL, deadline: TimeInterval, timedOut: Value, _ work: @escaping @Sendable (FileSystem) -> Value
    ) async -> Value {
        let drive = Self.drive(of: folder)
        guard claim(drive) else { return timedOut }
        let fileSystem = fileSystem
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let value = work(fileSystem)
                release(drive)
                once.resume(value)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
                once.resume(timedOut)
            }
        }
    }

    /// Why creating a folder failed, in the panel's terms (a read-only drive is said as such, not as a permission error).
    static func problem(creating error: Error) -> ExportDestinationProblem {
        let posix = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError).flatMap {
            $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil
        }
        if posix == EROFS || (error as NSError).code == NSFileWriteVolumeReadOnlyError { return .readOnlyVolume }
        return .notWritable(posix.map { String(cString: strerror($0)) } ?? error.localizedDescription)
    }

    static func check(_ folder: URL, writeTest: Bool, fileSystem: FileSystem) -> ExportDestinationReport {
        switch fileSystem.kind(folder) {
        case .missing: return ExportDestinationReport(problem: .missing)
        case .file: return ExportDestinationReport(problem: .notAFolder)
        case .folder: break
        }
        let names = Set(fileSystem.names(folder).map(ExportDestinationReport.fold))
        if fileSystem.isReadOnlyVolume(folder) { return ExportDestinationReport(problem: .readOnlyVolume, names: names) }
        if writeTest, let problem = fileSystem.writeTest(folder) { return ExportDestinationReport(problem: problem, names: names) }
        return ExportDestinationReport(problem: nil, names: names)
    }

    /// `/Volumes/<name>` for external drives, `/` for everything else: the unit that gets stuck together.
    static func drive(of folder: URL) -> String {
        let parts = folder.standardizedFileURL.pathComponents
        return parts.count >= 3 && parts[1] == "Volumes" ? "/Volumes/" + parts[2] : "/"
    }

    private func claim(_ drive: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outstanding[drive, default: 0] < Self.outstandingPerDrive else { return false }
        outstanding[drive, default: 0] += 1
        return true
    }

    private func release(_ drive: String) {
        lock.lock()
        outstanding[drive, default: 1] -= 1
        lock.unlock()
    }

    /// Resumes the caller exactly once: whichever of the work and the deadline comes first.
    private final class Once<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?

        init(_ continuation: CheckedContinuation<Value, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Value) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
