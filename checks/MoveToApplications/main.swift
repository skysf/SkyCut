import Foundation

// scripts/check-move-to-applications.sh: when SkyCut offers to move itself into Applications (the pure rule, every case),
// the move against scratch folders (MoverChecks) and the installer disk on real scratch images (DiskChecks). Never the real
// /Applications, the person's Trash or a running SkyCut: every destination, Trash and running probe is injected.

@main
struct MoveToApplicationsChecks {
    static func main() {
        guard CommandLine.arguments.count == 2 else { fatalError("usage: check-move-to-applications <scratch folder>") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        decisions(check)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            print("==> the move against scratch folders")
            try MoverChecks.run(in: root, check: check)
            print("==> the installer disk on scratch images")
            try DiskChecks.run(in: root, check: check)
        } catch {
            check(false, "fixture: \(error)")
        }
        print("move-to-applications: \(checks) checks, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// The launch rule: asks from a disk image or a translocated path, never anywhere else.
    static func decisions(_ check: (Bool, String) -> Void) {
        print("==> when the launch asks")
        let home = "/Users/someone"
        func facts(_ path: String, diskImage: Bool = false, id: String? = "com.srtflow.SrtFlow",
                   environment: [String: String] = [:]) -> MoveToApplicationsOffer.Facts {
            MoveToApplicationsOffer.Facts(bundlePath: path, bundleIdentifier: id, homeDirectory: home,
                                          onReadOnlyDiskImage: diskImage, environment: environment)
        }
        let translocated = "/private/var/folders/x1/abc123/T/AppTranslocation/5B0F2D0C-8E4A-4C59-9E3B-2A7F7B0E1C11/d/SkyCut.app"
        let cases: [(MoveToApplicationsOffer.Facts, MoveToApplicationsOffer.Decision, String)] = [
            (facts("/Volumes/SkyCut/SkyCut.app", diskImage: true), .offer(.diskImage), "the installer disk asks"),
            (facts("/Volumes/SkyCut/SkyCut.app/", diskImage: true), .offer(.diskImage), "the installer disk asks (trailing slash)"),
            (facts("/Volumes/SkyCut/SkyCut Beta.app", diskImage: true, id: "com.srtflow.SrtFlow.beta"), .offer(.diskImage), "the Beta on a disk image asks"),
            (facts(translocated), .offer(.translocated), "a translocated download asks"),
            (facts(String(translocated.dropFirst("/private".count))), .offer(.translocated), "a translocated download under /var asks"),
            (facts("/Applications/SkyCut.app"), .skip(.installed), "/Applications never asks"),
            (facts("/Applications/SkyCut.app", diskImage: true), .skip(.installed), "/Applications never asks, whatever the volume says"),
            (facts("/Applications/Video/SkyCut.app"), .skip(.installed), "a subfolder of /Applications never asks"),
            (facts("/System/Volumes/Data/Applications/SkyCut.app"), .skip(.installed), "/Applications by its data-volume path never asks"),
            (facts(home + "/Applications/SkyCut.app"), .skip(.installed), "~/Applications never asks"),
            (facts("/Users/someone/Projects/SkyCut/dist/SkyCut.app", diskImage: true), .skip(.developmentFolder), "dist/ never asks"),
            (facts("/Users/someone/Projects/SkyCut/.build/arm64-apple-macosx/debug/SkyCut.app", diskImage: true), .skip(.developmentFolder), ".build never asks"),
            (facts("/private/tmp/skycut-e2e.Ab12/SkyCut.app", diskImage: true), .skip(.developmentFolder), "/private/tmp never asks"),
            (facts("/tmp/skycut-e2e.Ab12/SkyCut.app", diskImage: true), .skip(.developmentFolder), "/tmp never asks"),
            (facts("/var/folders/x1/abc123/T/tmp.Q1/SkyCut.app", diskImage: true), .skip(.developmentFolder), "a temporary folder never asks"),
            (facts("/Users/someone/Downloads/SkyCut.app"), .skip(.elsewhere), "a folder the person chose (not translocated) never asks"),
            (facts("/Volumes/External/SkyCut.app"), .skip(.elsewhere), "a writable external drive never asks"),
            (facts("/Volumes/SkyCut/SkyCut.app", diskImage: true, environment: ["SRTFLOW_SMOKE_MUTE": "1"]), .skip(.scripted), "a smoke environment never asks"),
            (facts(translocated, environment: ["SRTFLOW_FFMPEG": "/x/ffmpeg"]), .skip(.scripted), "an E2E run never asks"),
            (facts("/Volumes/SkyCut/SkyCut.app", diskImage: true, environment: ["CI": "true"]), .skip(.scripted), "CI never asks"),
            (facts("/Volumes/SkyCut/SkyCut.app", diskImage: true, id: "com.srtflow.e2e123.skystudiosmoke"), .skip(.otherBundle), "a smoke bundle never asks"),
            (facts("/Volumes/SkyCut/SkyCut.app", diskImage: true, id: "com.srtflow.SrtFlow.movecheck"), .skip(.otherBundle), "a check bundle never asks"),
            (facts("/Volumes/SkyCut/SkyCut.app", diskImage: true, id: nil), .skip(.otherBundle), "no bundle identifier never asks"),
            (facts("/Volumes/SkyCut/SrtFlow", diskImage: true), .skip(.notAppBundle), "a bare executable never asks"),
        ]
        for (facts, expected, label) in cases {
            let decision = MoveToApplicationsOffer.decide(facts)
            check(decision == expected, "\(label): expected \(expected), got \(decision)")
        }
        check(MoveToApplicationsOffer.isTranslocated(translocated), "the translocation pattern")
        check(!MoveToApplicationsOffer.isTranslocated("/Users/someone/AppTranslocation/SkyCut.app"), "AppTranslocation outside the temporary folders is a folder name")
    }
}
