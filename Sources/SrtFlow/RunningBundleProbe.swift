import Darwin
import Foundation

// MARK: - Is SkyCut open from this app bundle, right now?
//
// What it does: lists every process on the Mac (`proc_listpids`) and reads where each one's executable is
// (`proc_pidpath`). The bundle counts as open when one of them is the app itself: an executable in the bundle's
// `Contents/MacOS/`, in any login session. Letter case is ignored (a case-insensitive volume names one bundle two ways).
// Live on every call, and safe off the main thread: AppBundleMover asks it again right before the Trash. A process whose
// path can't be read (another user's protected one) is not counted.
//
// Helpers don't count (`Contents/Helpers/`: an AI client's skycut-mcp, the web-motion renderer). An AI client keeps its
// skycut-mcp running for as long as its session is open, SkyCut open or not, so counting it would make every launch from
// the disk say «SkyCut is open» and quit while Claude or Codex is open (review FBM2, N1). Moving the bundle to the Trash
// under a running helper is harmless (review FBM1, B4): the Trash is a rename, so the helper keeps its open files and
// keeps running; it worked out its app's path once at start, so its next launch opens the new copy at the same path; and
// an older helper next to a newer app is already handled (MCPCatalogSync). Replacing the bundle under a running helper is
// what an update by hand already does.
// What it doesn't: quit anything, or decide what to do about it (MoveToApplicationsFlow, AppBundleMover).
// Rules: docs/build/build-and-packaging.md "Installing from the DMG".

enum RunningBundleProbe {
    /// Whether the app itself is open from `bundle` (its `Contents/MacOS/` executable); helpers don't count.
    static func isRunning(_ bundle: URL) -> Bool {
        !processes(inside: bundle).isEmpty
    }

    /// The processes that are the app itself: their executable lies in `bundle`'s `Contents/MacOS/`.
    static func processes(inside bundle: URL) -> [pid_t] {
        processes(under: bundle.appendingPathComponent("Contents/MacOS", isDirectory: true))
    }

    /// The processes whose executable lies anywhere under `folder` (the checks use it to see a helper run).
    static func processes(under folder: URL) -> [pid_t] {
        let folders = names(of: folder)
        return executables().filter { _, path in folders.contains { isInside(path, $0) } }.map(\.pid)
    }

    /// `path` is inside `folder` (not the folder itself, not a sibling that only starts the same), ignoring letter case.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        var folder = folder
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        return path.lowercased().hasPrefix(folder.lowercased() + "/")
    }

    /// The folder's path as given and as the file system resolves it (`/var` → `/private/var`): the kernel reports the
    /// resolved one.
    private static func names(of folder: URL) -> [String] {
        var names = [folder.standardizedFileURL.path]
        if let resolved = realpath(folder.path, nil) {
            names.append(String(cString: resolved))
            free(resolved)
        }
        return names
    }

    private static func executables() -> [(pid: pid_t, path: String)] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return (pid, String(cString: buffer))
        }
    }
}
