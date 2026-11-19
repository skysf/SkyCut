import Foundation

/// Scratch UserDefaults for a check, kept out of the login home's ~/Library/Preferences.
///
/// A suite named like a domain (`UserDefaults(suiteName: "com.srtflow.some-check")`) is stored by cfprefsd as
/// ~/Library/Preferences/<name>.plist, and removing the domain does not remove that file: cfprefsd keeps an empty plist,
/// and one deleted before cfprefsd's delayed write (up to about 10 s after the process exits) is written again. Checks
/// left thousands of them in the real home (docs/bugfixes/2026-11-19-check-defaults-leftovers.md). A suite named by an
/// absolute path is stored beside that path instead, so each scratch suite lives in a temporary folder of its own and is
/// gone with the folder: cfprefsd does not recreate a deleted folder. checks/test-defaults-cleanup.sh keeps every check
/// on this type. It does not cover a staged check app's own domain (its bundle id): scripts/test-defaults-cleanup.sh.
///
/// Use: `let scratch = ScratchDefaults("approval-check")` and `defer { scratch.remove() }` on the next line, then
/// `scratch.defaults`, or `scratch.name` for code under test that opens the suite by name.
final class ScratchDefaults {
    /// The suite's name: an absolute path in a temporary folder, never a domain in ~/Library/Preferences.
    let name: String
    let defaults: UserDefaults
    private let folder: URL

    init(_ label: String) {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("skycut-check-defaults", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            fatalError("Could not make the scratch defaults folder \(folder.path): \(error)")
        }
        name = folder.appendingPathComponent("defaults").path
        guard let defaults = UserDefaults(suiteName: name) else { fatalError("No scratch UserDefaults at \(name)") }
        self.defaults = defaults
    }

    /// Deletes the suite with its folder. A write cfprefsd still has pending then fails instead of recreating it.
    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}
