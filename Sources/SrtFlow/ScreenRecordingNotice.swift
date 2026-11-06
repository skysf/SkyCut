import AppKit
import SwiftUI

// 全 App 的录屏结果 notice：挂在主窗口与每个工程窗口，不靠录制工程本身的 notice 才看得见。
// 非模态、常驻到用户关闭；只有点“打开工程”才切窗口，点“在访达中显示”才打开 Finder。
struct ScreenRecordingNotice: View {
    @ObservedObject private var feedback = ScreenRecordingFeedback.shared
    @ObservedObject private var language = AppLanguageStore.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if let receipt = feedback.notices.last {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label {
                        Text(verbatim: ScreenRecordingNoticeText.title(receipt))
                    } icon: {
                        Image(systemName: receipt.status == .done && !receipt.incomplete ? "checkmark.circle" : "exclamationmark.triangle")
                    }
                    .font(.headline)
                    Spacer()
                    if feedback.notices.count > 1 {
                        Text("Recording results: \(feedback.notices.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        feedback.dismiss(receipt.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(receipt.waitingForDecision)
                    .instantHelp("Dismiss this message")
                }
                ScrollView {
                    Text(verbatim: ScreenRecordingNoticeText.message(presentation(receipt)))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 165)
                HStack(spacing: 12) {
                    if let file = receipt.video ?? receipt.files.first {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                    }
                    if let project = OpenProjects.shared.project(shortID: receipt.projectID),
                       project.documentGeneration == receipt.projectGeneration {
                        Button("Open recorded project") { OpenProjects.shared.focus(project) }
                    }
                    if receipt.waitingForDecision {
                        Button("Add to timeline") { Task { await ScreenRecordingCoordinator.shared.resolvePartial(import: true) } }
                        Button("Keep file only") { Task { await ScreenRecordingCoordinator.shared.resolvePartial(import: false) } }
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: 680, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.4)))
            .shadow(radius: 6, y: 2)
            .padding(10)
            .accessibilityIdentifier("screen-recording-result-notice")
        }
    }

    /// 回执冻结的是停止时的状态；用户点开窗口后，界面不再声称工程仍没有窗口。
    private func presentation(_ receipt: ScreenRecordingReceipt) -> ScreenRecordingReceipt {
        var result = receipt
        if let project = OpenProjects.shared.project(shortID: receipt.projectID), project.documentGeneration == receipt.projectGeneration {
            result.background = OpenProjects.shared.isHeadless(project)
        }
        return result
    }
}
