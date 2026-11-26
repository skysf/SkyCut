import Foundation

// scripts/check-app-update.sh: who updates itself (AppUpdateEligibility.decide), every case: only the release app signed by
// the pinned team with a plain version, from a folder it can replace itself in; the installer disk, a translocated
// download, a privacy-protected folder (Desktop, Documents, Downloads, iCloud Drive) and an unwritable place only tell;
// SkyCut Beta, ad-hoc and dev builds, build and scratch folders, a copy running from inside the Updates folder and scripted
// runs never check (a scripted run may with a loopback test feed); an AI-started launch is a normal one.

enum EligibilityChecks {
    static func run(check: (Bool, String) -> Void) {
        print("==> who updates")
        typealias Facts = AppUpdateEligibility.Facts
        func facts(_ path: String = "/Applications/SkyCut.app", id: String? = "com.srtflow.SrtFlow", team: String? = "26TVX3S9FR",
                   version: String? = "0.18.69", env: [String: String] = [:], home: String = "/Users/someone",
                   loopbackHook: Bool = false, insideUpdates: Bool = false, diskImage: Bool = false, folderWritable: Bool = true,
                   bundleWritable: Bool = true, swap: Bool = true, sameVolume: Bool = true) -> Facts {
            Facts(bundlePath: path, bundleIdentifier: id, teamIdentifier: team, version: version, environment: env,
                  homeDirectory: home, testHookIsLoopback: loopbackHook, insideUpdatesFolder: insideUpdates,
                  onReadOnlyDiskImage: diskImage, folderWritable: folderWritable, bundleWritable: bundleWritable,
                  volumeSupportsSwap: swap, stagingOnSameVolume: sameVolume)
        }
        let translocated = "/private/var/folders/x1/abc/T/AppTranslocation/5B0F2D0C-8E4A-4C59-9E3B-2A7F7B0E1C11/d/SkyCut.app"
        let staged = "/Users/someone/Library/Application Support/SrtFlow/Updates/staged.noindex/0.19.0/SkyCut.app"
        let cases: [(Facts, AppUpdateEligibility.Decision, String)] = [
            (facts(), .updates, "the release app in /Applications updates"),
            (facts("/Applications/SkyCut.app/"), .updates, "a trailing slash"),
            (facts("/Users/someone/Applications/SkyCut.app"), .updates, "~/Applications updates"),
            (facts("/Users/someone/Apps/SkyCut.app"), .updates, "a writable folder the person chose updates"),
            (facts("/Users/someone/DownloadsArchive/SkyCut.app"), .updates, "a folder that only starts like Downloads updates"),
            (facts(env: ["SRTFLOW_AI_LAUNCH": "1"]), .updates, "a launch the AI helper made is a normal launch"),
            (facts("/Volumes/SkyCut/SkyCut.app", diskImage: true), .notifyOnly(.installerDisk), "the installer disk only tells"),
            (facts(translocated), .notifyOnly(.translocated), "a translocated download only tells"),
            (facts("/Users/someone/Downloads/SkyCut.app"), .notifyOnly(.protectedFolder), "Downloads only tells"),
            (facts("/Users/someone/Desktop/SkyCut.app"), .notifyOnly(.protectedFolder), "the Desktop only tells"),
            (facts("/Users/someone/Documents/Apps/SkyCut.app"), .notifyOnly(.protectedFolder), "anywhere inside Documents only tells"),
            (facts("/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/SkyCut.app"), .notifyOnly(.protectedFolder),
             "iCloud Drive only tells"),
            (facts("/users/someone/downloads/SkyCut.app"), .notifyOnly(.protectedFolder), "letter case doesn't matter"),
            (facts("/System/Volumes/Data/Users/someone/Downloads/SkyCut.app"), .notifyOnly(.protectedFolder),
             "Downloads reached through the Data volume only tells"),
            (facts("/Users/someone/Downloads/SkyCut.app", home: "/Users/other"), .updates, "another user's Downloads is a plain folder here"),
            (facts(folderWritable: false), .notifyOnly(.folderNotWritable), "a folder this user can't write only tells"),
            (facts(bundleWritable: false), .notifyOnly(.bundleNotWritable), "a bundle this user can't write only tells"),
            (facts(swap: false), .notifyOnly(.volumeCannotSwap), "a volume without atomic swaps only tells"),
            (facts(sameVolume: false), .notifyOnly(.stagingOnOtherVolume), "the staging folder on another volume only tells"),
            (facts(staged, insideUpdates: true), .never(.updatesFolder), "a staged copy started by its path never updates"),
            (facts(insideUpdates: true), .never(.updatesFolder), "anything running from inside the Updates folder never updates"),
            (facts(id: "com.srtflow.SrtFlow.beta"), .never(.otherBundle), "SkyCut Beta never updates"),
            (facts(id: "com.srtflow.SrtFlow.updatecheck"), .never(.otherBundle), "a check bundle never updates"),
            (facts(id: nil), .never(.otherBundle), "no bundle id never updates"),
            (facts(team: nil), .never(.notReleaseSignature), "an ad-hoc build never updates"),
            (facts(team: "ABCDE12345"), .never(.notReleaseSignature), "another team's signature never updates"),
            (facts(version: "0.18.67-local.20261126.d3a6c971"), .never(.developmentVersion), "a local build's version never updates"),
            (facts(version: nil), .never(.developmentVersion), "no version never updates"),
            (facts("/Users/someone/SkyCut/dist/SkyCut.app"), .never(.developmentFolder), "dist/ never updates"),
            (facts("/Users/someone/SkyCut/.build/arm64-apple-macosx/debug/SkyCut.app"), .never(.developmentFolder), ".build never updates"),
            (facts("/private/tmp/skycut-e2e.Ab12/SkyCut.app"), .never(.developmentFolder), "/private/tmp never updates"),
            (facts("/var/folders/x1/abc/T/tmp.Q1/SkyCut.app"), .never(.developmentFolder), "a temporary folder never updates"),
            (facts("/Applications/SrtFlow"), .never(.notAppBundle), "a bare executable never updates"),
            (facts(env: ["CI": "true"]), .never(.scripted), "CI never checks"),
            (facts(env: ["SRTFLOW_SMOKE_MUTE": "1"]), .never(.scripted), "a smoke run never checks"),
            (facts(env: ["SRTFLOW_FFMPEG": "/x/ffmpeg", "SRTFLOW_AI_LAUNCH": "1"]), .never(.scripted), "an E2E run never checks"),
            (facts(env: ["CI": "true"], loopbackHook: true), .updates, "a scripted run with a loopback test feed may"),
        ]
        for (facts, expected, label) in cases {
            let decision = AppUpdateEligibility.decide(facts)
            check(decision == expected, "\(label): expected \(expected), got \(decision)")
        }
        check(AppUpdateEligibility.Decision.notifyOnly(.translocated).checks && !AppUpdateEligibility.Decision.never(.scripted).checks,
              "notify-only copies check; never-copies don't")
    }
}
