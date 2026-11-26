import Foundation

// MARK: - The shell that opens SkyCut again after Restart and Update
//
// What it does: starts a small shell that outlives SkyCut. It waits for this process to exit (never two SkyCut instances;
// it gives up after 60 s), then opens the app at the same path, but only while that path still holds an app (its
// Info.plist): the new version when the swap went in, the old one when it didn't, nothing when the app was moved or renamed
// meanwhile. Never a second instance: `open` gets the path alone, never its -n flag. The pid, the path and the opener go
// in as arguments, never into the script's text.
// InstallerDisk's eject shell with `open` in place of `hdiutil detach`.
// What it doesn't: decide to restart (AppUpdateRestart), install (AppUpdateInstaller).
// Rules: docs/architecture/app-updates.md "Restart and Update".

enum AppUpdateRelaunch {
    /// What opens the app (the checks pass a recorder instead).
    static let opener = "/usr/bin/open"

    /// Waits for $1 to exit (at most 600 polls of 0.1 s), then, if $2 still holds an app, runs $3 with $2 alone.
    static let script = """
        i=0; while kill -0 "$1" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 600 ] && exit 0; sleep 0.1; done; \
        [ -f "$2/Contents/Info.plist" ] || exit 0; exec "$3" "$2"
        """

    /// Starts the shell for `bundle` after process `pid` has exited; nil if it couldn't start.
    @discardableResult
    static func start(_ bundle: URL, afterExitOf pid: Int32, opener: String = opener) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(pid), bundle.path, opener]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        return process
    }
}
