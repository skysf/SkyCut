import Foundation

// 回执的人类文案；路径、工程名与轨道名原样展示，所有固定文案都经 L10n。
enum ScreenRecordingNoticeText {
    static func title(_ receipt: ScreenRecordingReceipt) -> String {
        switch receipt.status {
        case .done: return receipt.incomplete ? L10n("Recording saved with issues") : L10n("Recording saved")
        case .failed: return L10n("Recording failed")
        case .cancelled: return L10n("Recording cancelled")
        }
    }

    static func message(_ receipt: ScreenRecordingReceipt) -> String {
        var parts: [String] = []
        if let reason = receipt.reason { parts.append(String(format: L10n("Reason: %@"), reason)) }
        for file in receipt.files {
            if file.unavailable {
                parts.append(String(format: L10n("The recording location is unavailable; this file could not be checked: %@"), file.url.path))
            } else if !file.usable {
                parts.append(String(format: L10n("A file remains but could not be read: %@"), file.url.path))
            } else if file.temporary {
                parts.append(String(format: L10n("Usable temporary file: %@"), file.url.path))
            } else {
                parts.append(String(format: L10n("Saved to: %@"), file.url.path))
            }
        }
        if receipt.files.allSatisfy({ !$0.usable && !$0.unavailable }) { parts.append(L10n("No usable recording file was kept.")) }
        if receipt.addedToTimeline {
            let tracks = receipt.clips.map(\.track).joined(separator: ", ")
            parts.append(String(format: L10n("Added to “%1$@” (%2$@), track %3$@."), receipt.projectName, receipt.projectID, tracks))
        } else if receipt.waitingForDecision {
            parts.append(L10n("Choose whether to add this recording to the timeline or keep the file only."))
        } else {
            parts.append(L10n("Not added to the timeline."))
        }
        if receipt.background { parts.append(L10n("This project is in the background and has no window.")) }
        return parts.joined(separator: "\n")
    }
}
