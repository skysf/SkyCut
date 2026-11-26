import AppKit

// MoveToApplicationsAlerts' buttons and lines (scripts/check-move-to-applications.sh), built for real, never shown: Move is
// the default (Return) and Not Now answers Escape; the Trash line only when replacing; the running alert's one button
// quits; Not Now on the folder alert and OK on the not-opened alert answer Escape; the reasons say what is true. The words
// are the English keys (L10n below is the identity); the tables are covered by scripts/check-localization-coverage.sh.

/// The check binary has no string tables: the key is the English text.
func L10n(_ key: String) -> String { key }

enum AlertChecks {
    @MainActor static func run(check: (Bool, String) -> Void) {
        print("==> the alerts' buttons and lines")
        let returnKey = "\r", escape = "\u{1b}"
        let question = MoveToApplicationsAlerts.question(appName: "SkyCut", replacing: false)
        check(question.buttons.map(\.title) == ["Move to Applications", "Not Now"], "question: Move, then Not Now")
        check(question.buttons.map(\.keyEquivalent) == [returnKey, escape], "question: Return moves, Escape answers Not Now")
        check(question.informativeText.contains("won't open once the disk is ejected"), "question: the true reason")
        check(!question.informativeText.contains("Trash"), "question: no Trash line when nothing is there")
        let replacing = MoveToApplicationsAlerts.question(appName: "SkyCut", replacing: true)
        check(replacing.informativeText.contains("The SkyCut that's there now goes to the Trash."), "question: the Trash line when replacing")

        let running = MoveToApplicationsAlerts.running(appName: "SkyCut")
        check(running.buttons.map(\.title) == ["Quit"], "running: one button, Quit")
        check(running.informativeText.contains("this copy quits now"), "running: says this copy quits")

        let folder = MoveToApplicationsAlerts.notWritable(appName: "SkyCut")
        check(folder.buttons.map(\.keyEquivalent) == [returnKey, escape], "not writable: Escape answers Not Now")

        let notOpened = MoveToApplicationsAlerts.openFailed(appName: "SkyCut", detail: nil)
        check(notOpened.buttons.map(\.keyEquivalent) == [returnKey, escape], "not opened: Escape answers OK")
        check(notOpened.informativeText.contains("This copy keeps running from the installer disk."), "not opened: says this copy goes on")
    }
}
