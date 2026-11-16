import Foundation
import SrtFlowWebMotionKit

// MARK: - skycut-web-motion: the web-motion renderer, a helper process outside SkyCut
//
// SkyCut starts it per render (Contents/Helpers/skycut-web-motion), writes one `WebMotionRequest` (JSON) to its stdin
// and reads `WebMotionEvent` lines from its stdout; the last line is the result. It runs AI-written page code, so it runs
// in its own process: SkyCut can kill it (and with it the page's WebKit processes) without touching itself, and watches
// its memory (WebKit has no public way to stop one page). No window, no NSApplication: a run loop and windowless views.
// docs/architecture/web-motion-renderer.md.

private func refuse(_ message: String) -> Never {
    let result = WebMotionResult(
        accepted: false, checks: WebMotionCheckName.allCases.map { WebMotionCheck(name: $0, passed: nil, detail: "Not reached.") },
        failure: WebMotionFailure(check: .loads, message: message, time: nil), pageErrors: [], frameCount: 0,
        frameHashes: [], blankFrames: [], alpha: nil, versions: nil, timing: WebMotionTiming(), webKitProcesses: [])
    FileHandle.standardOutput.write(WebMotionEvent(kind: .result, result: result).line())
    exit(WebMotionExitCode.invalidRequest)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
let request: WebMotionRequest
do {
    request = try JSONDecoder().decode(WebMotionRequest.self, from: input)
} catch {
    refuse("The render request could not be read: \(error)")
}
let problems = request.problems()
if !problems.isEmpty { refuse("The render request is out of bounds: " + problems.joined(separator: " ")) }

Task { @MainActor in
    await HelperRun(request: request).run()
}
RunLoop.main.run()
