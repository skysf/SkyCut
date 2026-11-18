import Darwin
import Foundation
import SrtFlowWebMotionKit

// A bounded negative check can use the first view as its load subject, so a prior calibration process cannot hide
// missing discovery. The source still uses the real locks and clock; the probe never emits a process event.
@MainActor
enum LoadMemoryProbe {
    private static var path: String? {
        ProcessInfo.processInfo.environment["SRTFLOW_WEB_MOTION_TEST_LOAD_PROBE"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func calibrationHTML(_ request: WebMotionRequest) -> String {
        path == nil ? WebMotionAlphaCalibration.html : request.html
    }

    static func record(_ page: PageWorker, deadline: Double) async throws {
        guard let path else { return }
        let value = try await page.web.evaluateJavaScript("window.__srtflowHeldBytes")
        guard let held = value as? NSNumber,
              let pid = Lockdown.processIdentifier("_webProcessIdentifier", of: page.web) else {
            throw HelperFailure(description: "The bounded load-memory fixture did not expose its WebContent allocation.")
        }
        let data = try JSONSerialization.data(withJSONObject: ["pid": pid, "helper": getpid(), "heldBytes": held.intValue, "deadline": deadline])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
