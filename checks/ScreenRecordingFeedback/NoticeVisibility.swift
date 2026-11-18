import AppKit
import Foundation
import SrtFlowCore
import SwiftUI
@testable import SrtFlow

// UI-2 (2026-11-18): an earlier recording result stays off screen while the next take is set up, captured and saved, so
// recording SkyCut's own window no longer puts that notice into the new footage; it comes back afterwards, hidden and not
// dismissed. Lays out the real notice view off screen (no window) at each state the real coordinator passes through.
extension FeedbackAssertions {
    func checkNoticeOffScreenWhileRecording(target: VideoEditProject, result: ScreenRecordingResult) {
        let coordinator = ScreenRecordingCoordinator.shared
        func height() -> CGFloat { NSHostingView(rootView: ScreenRecordingNotice()).fittingSize.height }
        let notices = ScreenRecordingFeedback.shared.notices.count
        require(notices > 0 && coordinator.state == .idle && height() > 40, "fixture: an earlier recording result is on screen")
        var session = ScreenRecordingSession()
        session.driver = .ai
        require(coordinator.beginAutomated(session, for: target), "a new take begins")
        require(height() > 40, "the earlier result still shows while the take is configured")
        let capture: [ScreenRecordingState] = [.choosingSource, .choosingDestination, .preparing, .countingDown(remaining: 3),
                                               .countingDown(remaining: 0), .starting, .recording(startedAt: Date()), .stopping, .finishing]
        for state in capture {
            require(coordinator.transition(to: state), "the take reaches \(state)")
            require(height() == 0, "no recording result on screen while the next take is \(state)")
        }
        var partial = result
        partial.isPartial = true
        require(coordinator.transition(to: .partialRecovery(partial)) && height() > 40,
                "a take waiting for a decision shows the notices again (the decision buttons live there)")
        require(coordinator.transition(to: .importing) && height() == 0, "nothing on screen while the take is added")
        require(coordinator.transition(to: .finished(result)) && coordinator.transition(to: .idle), "the take ends")
        require(height() > 40 && ScreenRecordingFeedback.shared.notices.count == notices,
                "afterwards the earlier results are back: hidden, never dismissed")
        coordinator.invalidateSession()
        require(coordinator.state == .idle, "fixture cleaned up")
    }
}
