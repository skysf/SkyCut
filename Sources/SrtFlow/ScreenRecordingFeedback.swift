import Combine
import Foundation
import SrtFlowMCPKit

// 全 App 的录屏 notice 与每个 AI 会话的收尾回执；不订阅播放时钟、不激活窗口，不把 current 指针当历史。
@MainActor
final class ScreenRecordingFeedback: ObservableObject {
    static let shared = ScreenRecordingFeedback()
    @Published private(set) var notices: [ScreenRecordingReceipt] = []
    private(set) var latest: ScreenRecordingReceipt?
    private var recordings: [String: ScreenRecordingReceipt] = [:]
    private var attempts: [String: ScreenRecordingReceipt] = [:]
    private var receipts: [String: ScreenRecordingReceipt] = [:]
    private var pending: [String: [ScreenRecordingReceipt]] = [:]

    func acceptsCompletion(_ id: String) -> Bool {
        receipts[id] == nil || receipts[id]?.waitingForDecision == true
    }

    func publish(_ receipt: ScreenRecordingReceipt) {
        // 同一段的迟到取消不能覆盖成功；残缺待决那一段可以在用户选择后更新为入轨 / 仅留文件。
        guard acceptsCompletion(receipt.id) else { return }
        receipts[receipt.id] = receipt
        if receipt.began || receipt.status != .cancelled || latest == nil { latest = receipt }
        let owner = receipt.ownerSession ?? "manual"
        attempts[owner] = receipt
        if receipt.began || receipt.status != .cancelled { recordings[owner] = receipt }
        if let index = notices.firstIndex(where: { $0.id == receipt.id }) { notices[index] = receipt }
        else { notices.append(receipt) }
        if receipt.stop.by == "user", let session = receipt.ownerSession {
            var notes = pending[session] ?? []
            notes.removeAll { $0.id == receipt.id }
            notes.append(receipt)
            pending[session] = notes
        }
    }

    func recent(for session: String) -> ScreenRecordingReceipt? {
        recordings[session] ?? attempts[session] ?? recordings["manual"] ?? attempts["manual"]
    }

    func dismiss(_ id: String) { notices.removeAll { $0.id == id } }

    /// 只在原会话下一次工具调用开始时取走；别的会话、probe、已经在飞行的调用都不消费。
    func takeNote(for session: String) -> String? {
        guard let notes = pending.removeValue(forKey: session), !notes.isEmpty else { return nil }
        return notes.map { "Note: The user stopped the screen recording. \($0.message)" }.joined(separator: "\n")
    }
}
