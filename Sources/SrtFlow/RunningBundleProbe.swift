import Darwin
import Foundation

// MARK: - Is anything running from this app bundle, right now?
//
// What it does: lists every process on the Mac (`proc_listpids`) and reads where each one's executable is
// (`proc_pidpath`); the bundle counts as running when any of them lies inside it: the app itself, its helpers, an AI
// client's skycut-mcp, in any login session. Letter case is ignored (a case-insensitive volume names one bundle two ways).
// Live on every call, and safe off the main thread: AppBundleMover asks it again right before the Trash. A process whose
// path can't be read (another user's protected one) is not counted.
// What it doesn't: quit anything, or decide what to do about it (MoveToApplicationsFlow, AppBundleMover).
// Rules: docs/build/build-and-packaging.md "Installing from the DMG".

enum RunningBundleProbe {
    static func isRunning(_ bundle: URL) -> Bool {
        !processes(inside: bundle).isEmpty
    }

    /// The processes whose executable lies inside `bundle`.
    static func processes(inside bundle: URL) -> [pid_t] {
        let folders = names(of: bundle)
        return executables().filter { _, path in folders.contains { isInside(path, $0) } }.map(\.pid)
    }

    /// `path` is inside the folder `bundle` (not the folder itself, not a sibling that only starts the same), ignoring
    /// letter case.
    static func isInside(_ path: String, _ bundle: String) -> Bool {
        var folder = bundle
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        return path.lowercased().hasPrefix(folder.lowercased() + "/")
    }

    /// The bundle's path as given and as the file system resolves it (`/var` → `/private/var`): the kernel reports the
    /// resolved one.
    private static func names(of bundle: URL) -> [String] {
        var names = [bundle.standardizedFileURL.path]
        if let resolved = realpath(bundle.path, nil) {
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
