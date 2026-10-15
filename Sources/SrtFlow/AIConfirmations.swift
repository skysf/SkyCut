import Foundation
import SrtFlowMCPKit

// MARK: - 确认令牌：「用户在对话里点过头」的凭据
//
// 管什么：要用户点头的事（删文件进废纸篓、读点名文件夹以外的文件；方案第 34 条）怎么问、怎么认：结果里回
// needs_confirmation + 一张令牌，AI 把问题转述给用户，用户同意之后带着令牌再调一次。
// - 令牌绑着具体那件事（`action`：「删这几个文件」「读这几个文件」），换一件事拿它来不认、也不消耗它；
// - 一次有效；三十分钟过期（2026-10-15 从十分钟延长）；
// - **同一件事还在等答复就回同一张、有效期重新算**：AI 等用户回话时又调了一次，拿到的还是它，不会误以为上一张过期了
//   （2026-10-15 用户转来的反馈：「等你回复的工夫第一个确认码就过期了，SrtFlow 又发了一个新的」—— 其实是每问一次就发一张新的、
//   旧的还活着，而且被拒时不说原因，docs/bugfixes/2026-10-15-confirmation-token-refused-without-reason.md）；
// - **拒绝时说清楚为什么**（过期 / 用过了 / 是别的请求的 / 不是 SrtFlow 发的），写在结果的 confirm_token_refused 里；
//   有效期写在 valid_for_minutes 里。
// 时钟可注入，自检够得着（checks/MCP/ConfirmationChecks.swift）。
// 不管什么：什么时候问（AIFileTools.confirmTrash、AIWorkspace.confirmReading —— 会问的只许这两处，scripts/check-mcp.sh 钉着）。

@MainActor
final class AIConfirmations {
    static let shared = AIConfirmations()

    /// 一张令牌有效多久。
    nonisolated static let lifetime: TimeInterval = 30 * 60

    /// 带来的令牌怎么了。
    enum Redemption: Equatable {
        /// 对这件事、没用过、没过期：收下了（从此作废）。
        case accepted
        /// 没带令牌：这是第一次问。
        case notGiven
        case refused(Refusal)

        var refusal: Refusal? {
            if case .refused(let refusal) = self { return refusal }
            return nil
        }
    }

    /// 没收的原因（结果里的 confirm_token_refused）。
    enum Refusal: Equatable {
        case unknown, expired, used, otherAction

        var message: String {
            let minutes = Int(AIConfirmations.lifetime / 60)
            switch self {
            case .unknown:
                return "The confirm_token you passed is not one SrtFlow issued, or it was issued too long ago. Ask the user again and use the new one below."
            case .expired:
                return "The confirm_token you passed expired (each lasts \(minutes) minutes). Ask the user again and use the new one below."
            case .used:
                return "The confirm_token you passed was already used; each is good for a single call. Ask the user again and use the new one below."
            case .otherAction:
                return "The confirm_token you passed belongs to a different request (other files or another question) and was left untouched. Use the one below for this request."
            }
        }
    }

    private struct Issued {
        var action: String
        var expires: Date
        var usedAt: Date?
    }

    private var issued: [String: Issued] = [:]
    private let now: () -> Date
    private static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// 问一句、给一张令牌。`action` 写清楚放行的是哪一件事；这件事还有没用过、没过期的令牌就回它（有效期重新算），
    /// 不另发一张。`refused`：这次带来的令牌为什么没收，一并写进结果。
    func ask(_ question: String, action: String, refused: Refusal? = nil) -> AIToolResult {
        purge()
        let moment = now()
        let pending = issued.first { $0.value.action == action && $0.value.usedAt == nil && $0.value.expires > moment }
        let token = pending?.key ?? mint()
        issued[token] = Issued(action: action, expires: moment.addingTimeInterval(Self.lifetime))
        return .needsConfirmation(question: question, token: token, validMinutes: Int(Self.lifetime / 60), refused: refused?.message)
    }

    /// 收令牌：对这件事、没用过、没过期就收下（从此作废）；不对就说为什么、什么都不动。
    func redeem(_ token: String?, for action: String) -> Redemption {
        guard let token else { return .notGiven }
        guard let entry = issued[token] else { return .refused(.unknown) }
        if entry.usedAt != nil { return .refused(.used) }
        if entry.action != action { return .refused(.otherAction) }
        if entry.expires <= now() { return .refused(.expired) }
        issued[token]?.usedAt = now()
        return .accepted
    }

    /// 过期的、用过的留一阵（好说出「过期了」「用过了」而不是「不认识」），再久的忘掉。
    private func purge() {
        let cutoff = now().addingTimeInterval(-Self.lifetime)
        issued = issued.filter { ($0.value.usedAt ?? $0.value.expires) > cutoff }
    }

    private func mint() -> String {
        while true {
            let token = String((0..<6).map { _ in Self.alphabet.randomElement()! })
            if issued[token] == nil { return token }
        }
    }
}
