import AppKit
import Foundation
@testable import SrtFlow

// Full-App integration checks for the project, AI call and recoverable web-motion cache.
// The fixture is an isolated bundle with synthetic HTML, never the installed app or a user's project.
private enum MotionCheckGroup: String { case core, official }

@main enum MotionPlacementChecks {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 2, let group = MotionCheckGroup(rawValue: CommandLine.arguments[1]) else {
            fputs("Usage: MotionPlacementCheck <core|official>\n", stderr)
            exit(2)
        }
        print("motion checks \(group.rawValue): isolated setup")
        let domain = Bundle.main.bundleIdentifier ?? ""
        guard domain.hasPrefix("com.srtflow.SrtFlow.motionplacementcheck.") else {
            fatalError("Motion placement checks require their isolated test bundle")
        }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        _ = NSApplication.shared
        do {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_MOTION_PLACEMENT_DIR"]!)
            switch group {
            case .core: try await runCoreChecks(root)
            case .official: try await runMotionOfficialChecks(root)
            }
        } catch {
            motionRequire(false, "motion placement \(group.rawValue) checks stopped: \(error)")
        }
        motionRequire(AIJobs.shared.running.filter { $0.kind == .motion }.isEmpty, "no motion job is left running")
        motionRequire(AIKeepAwake.shared.holders == 0, "motion jobs returned every keep-awake lease")
        UserDefaults.standard.removePersistentDomain(forName: domain)
        if MotionCheckLog.failures > 0 {
            print("FAIL: \(MotionCheckLog.failures) of \(MotionCheckLog.assertions) motion placement \(group.rawValue) checks")
            exit(1)
        }
        print("PASS: \(MotionCheckLog.assertions) motion placement \(group.rawValue) checks: real helper, timeline and AI calls; approval, "
              + "one-step undo, immutable cache keys, template reuse, failure atomicity and automatic recovery")
        exit(0)
    }

    @MainActor private static func runCoreChecks(_ root: URL) async throws {
        print("motion checks: fingerprints")
        try runMotionFingerprintChecks()
        print("motion checks: project fixture")
        let fixture = try MotionFixture(root: root)
        defer { _ = OpenProjects.shared.close(fixture.project) }
        print("motion checks: placement and editing")
        try await runMotionActionChecks(fixture)
        print("motion checks: approval")
        try await runMotionApprovalChecks(fixture)
        print("motion checks: duration and frame-rate bounds")
        try await runMotionDurationBoundsChecks(fixture)
        print("motion checks: failure and recovery")
        try await runMotionFailureRecoveryChecks(fixture)
        print("motion checks: saved versions")
        try await runMotionVersionChecks(root)
        print("motion checks: editor drafts, add and drop")
        try await runMotionEditorChecks(root)
    }
}

@MainActor enum MotionCheckLog {
    static var assertions = 0
    static var failures = 0
}

@MainActor func motionRequire(_ condition: Bool, _ message: String) {
    MotionCheckLog.assertions += 1
    if !condition { MotionCheckLog.failures += 1; print("FAIL: \(message)") }
}
