import AppKit
import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// A look never leaves the AI waiting for minutes (docs/bugfixes/2026-11-17-look-hangs-and-dropped-calls.md). Real App objects:
// - LineChecks: the router's lines (AICallLines): turns in joining order, several lines at once, a read letting go early,
//   positions and the call that holds a line, letting go before the turn does nothing;
// - LookCallChecks: real 12-frame looks (AILookTool) on two background projects of two AI sessions, through AILookCall and get_job /
//   cancel_job (AIExportTools): every look answers with its picture or a job_id that brings the picture; a look waiting behind an edit
//   becomes a queued job (position, waiting_for) and runs after it; cancelled while queued it never starts; cancelled while running it
//   stops; another session cannot cancel it; an edit behind a look gets its turn before the look's frames are done.
// RouterSwitchChecks also exercises queue selection and actual routing after the unchanged authorization gates.
// LookSoundChecks: look sound=… on a real project draws the engine's mix and a track under the frames (MCP-66).
@main enum LookJobChecks {
    @MainActor static func main() async {
        let domain = Bundle.main.bundleIdentifier ?? ""
        guard domain.hasPrefix("com.srtflow.SrtFlow.lookjobscheck.") else { fatalError("Look job checks require the isolated test bundle") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_LOOK_JOBS_DIR"]!).standardizedFileURL
        // The production wait before a look answers with a job: well inside a client's one-minute patience (the groups below shorten it).
        require(AILookCall.answerWithin > 0 && AILookCall.answerWithin <= 30, "a look answers or becomes a job within 30 s (answerWithin \(AILookCall.answerWithin))")
        await runLineChecks()
        do {
            try await runLookCallChecks(root)
            try await runRouterSwitchChecks(root)
            // look sound=… (MCP-66): the engine's mix drawn under the frames (LookSoundChecks).
            try await runLookSoundPathChecks(root)
        } catch {
            LookCheckLog.failures += 1
            print("FAIL: look call checks stopped: \(error)")
        }
        require(AIKeepAwake.shared.holders == 0, "every look job gave its keep-awake lease back (\(AIKeepAwake.shared.holders) left)")
        UserDefaults.standard.removePersistentDomain(forName: domain)
        if LookCheckLog.failures > 0 { print("FAIL: \(LookCheckLog.failures) look job checks"); exit(1) }
        print("PASS: look jobs: lines keep joining order across several lines and let a look go once it has read the project; "
            + "two sessions x two parallel 12-frame looks all answered with their pictures (directly or through get_job); a look behind an "
            + "edit became a queued job with its position and what it waits for, then ran; cancelled while queued it never started, while "
            + "running it stopped; another session could not cancel it; an edit behind a look got its turn before the look's frames; implicit switch waits became jobs before selection, real close_project completed and the look used the new target")
        exit(0)
    }
}

@MainActor enum LookCheckLog {
    static var failures = 0
}

@MainActor func require(_ condition: Bool, _ message: String) {
    if !condition { LookCheckLog.failures += 1; print("FAIL: \(message)") }
}
