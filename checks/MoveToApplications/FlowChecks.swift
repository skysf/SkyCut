import Foundation

// MoveToApplicationsFlow, the launch's decisions (scripts/check-move-to-applications.sh): a launch that doesn't offer
// carries on; an app of that name running in Applications ends the launch with the running alert instead of the question
// (never a promise of the Trash for it); Not Now carries on; after the move, what is said, which disk is ejected (only the
// one SkyCut ran from the top of), and that a launch that quits never carries on as well.

enum FlowChecks {
    static func run(check: (Bool, String) -> Void) {
        print("==> the launch flow's decisions")
        let offer = MoveToApplicationsOffer.Decision.offer(.diskImage)
        typealias Flow = MoveToApplicationsFlow
        check(Flow.start(.skip(.installed), installed: .init(exists: true, running: true)) == .continueLaunch,
              "start: a launch that doesn't offer carries on")
        check(Flow.start(offer, installed: .init(exists: true, running: true)) == .end(.running),
              "start: the app there is running: the running alert, not the question")
        check(Flow.start(offer, installed: .init(exists: false, running: true)) == .end(.running),
              "start: something running from that path, even with no bundle seen: the running alert")
        check(Flow.start(offer, installed: .init(exists: true, running: false)) == .ask(replacing: true),
              "start: a stopped app there: the question with the Trash line")
        check(Flow.start(offer, installed: .init(exists: false, running: false)) == .ask(replacing: false),
              "start: nothing there: the question without the Trash line")

        check(Flow.continuesAfter(.notNow), "Not Now carries on from the disk")
        check(!Flow.continuesAfter(.move), "Move does not carry on before the move")

        let original = URL(fileURLWithPath: "/Volumes/SkyCut/SkyCut.app", isDirectory: true)
        let installed = URL(fileURLWithPath: "/Applications/SkyCut.app", isDirectory: true)
        let top = InstallerDisk(mountPoint: URL(fileURLWithPath: "/Volumes/SkyCut", isDirectory: true), wholeDisk: "/dev/disk9")
        let other = InstallerDisk(mountPoint: URL(fileURLWithPath: "/Volumes/Archive", isDirectory: true), wholeDisk: "/dev/disk8")
        let nested = URL(fileURLWithPath: "/Volumes/Archive/Apps/SkyCut.app", isDirectory: true)
        check(Flow.end(.moved(installed), opened: .opened, disk: top, original: original) == .reopened(eject: top),
              "end: reopened from the top of the installer disk: that disk is ejected")
        check(Flow.end(.moved(installed), opened: .opened, disk: other, original: nested) == .reopened(eject: nil),
              "end: reopened from a subfolder of an image: nothing is ejected")
        check(Flow.end(.moved(installed), opened: .opened, disk: nil, original: original) == .reopened(eject: nil),
              "end: reopened from a translocated download: nothing is ejected")
        check(Flow.end(.moved(installed), opened: .failed("no"), disk: top, original: original) == .notOpened(installed: installed, detail: "no"),
              "end: moved but not opened: says so, with macOS's reason")
        check(Flow.end(.runningAtDestination(installed), opened: .notTried, disk: top, original: original) == .running,
              "end: running when the Trash came: the running alert")
        check(Flow.end(.destinationNotWritable(installed), opened: .notTried, disk: top, original: original) == .notWritable,
              "end: unwritable: the folder alert")
        check(Flow.end(.failed(.trash, detail: "d", oldAppInTrash: nil), opened: .notTried, disk: top, original: original)
              == .failed(.trash, detail: "d", oldAppInTrash: nil), "end: a failed step: that step, its reason")

        check(!Flow.End.reopened(eject: top).continuesLaunch && !Flow.End.running.continuesLaunch,
              "a launch that quits (reopened, running) never carries on as well")
        check(Flow.End.notWritable.continuesLaunch && Flow.End.notOpened(installed: installed, detail: nil).continuesLaunch
              && Flow.End.failed(.copy, detail: nil, oldAppInTrash: nil).continuesLaunch,
              "a move that stopped carries on from the disk")
    }
}
