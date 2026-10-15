import Foundation
import SrtFlowMCPKit

// 确认令牌（AIConfirmations，2026-10-15）：同一件事还在等答复就回同一张（有效期重新算）、别的事不认也不消耗、一次有效、
// 三十分钟过期；被拒时按原因说（过期 / 用过了 / 别的请求 / 不认识），结果里带 valid_for_minutes 和 confirm_token_refused。
// 用例是用户转来的反馈：AI 等用户回话时又调了一次、拿到第二张码，以为第一张过期了
// （docs/bugfixes/2026-10-15-confirmation-token-refused-without-reason.md）。编法见 scripts/check-mcp.sh。

@MainActor
func runConfirmationChecks() {
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    let confirmations = AIConfirmations(now: { clock })
    func token(_ result: AIToolResult) -> String { result.payload["confirm_token"]?.stringValue ?? "" }

    let first = confirmations.ask("Trash a.mp4?", action: "trash:/a.mp4")
    checkEqual(first.payload["status"]?.stringValue, "needs_confirmation", "asking returns needs_confirmation")
    checkEqual(first.payload["valid_for_minutes"]?.doubleValue, 30, "the result says how long the code lasts")
    check(first.payload["confirm_token_refused"] == nil, "a first ask does not talk about a refused code")
    checkEqual(token(first).count, 6, "a six-character code")
    clock += 20 * 60
    let again = confirmations.ask("Trash a.mp4?", action: "trash:/a.mp4")
    checkEqual(token(again), token(first), "asking the same thing again while the user has not answered returns the same code")
    let other = confirmations.ask("Trash b.mp4?", action: "trash:/b.mp4")
    check(token(other) != token(first), "a different request gets its own code")

    checkEqual(confirmations.redeem(nil, for: "trash:/a.mp4"), .notGiven, "no code = a first ask")
    checkEqual(confirmations.redeem("zzzzzz", for: "trash:/a.mp4"), .refused(.unknown), "a code SrtFlow never issued")
    checkEqual(confirmations.redeem(token(other), for: "trash:/a.mp4"), .refused(.otherAction), "b's code does not open a")
    checkEqual(confirmations.redeem(token(other), for: "trash:/b.mp4"), .accepted, "…and was left untouched: still good for b")
    checkEqual(confirmations.redeem(token(other), for: "trash:/b.mp4"), .refused(.used), "a code is good for one call")
    // 45 分钟后：第一张在第 20 分钟时重新算过有效期，还差 5 分钟才过期。
    clock += 25 * 60
    checkEqual(confirmations.redeem(token(first), for: "trash:/a.mp4"), .accepted,
               "asking again renewed the code: still good 25 minutes after the second ask")
    let fresh = confirmations.ask("Trash a.mp4?", action: "trash:/a.mp4")
    check(token(fresh) != token(first), "once used, asking again mints a new code")

    let third = confirmations.ask("Trash c.mp4?", action: "trash:/c.mp4")
    clock += 31 * 60
    checkEqual(confirmations.redeem(token(third), for: "trash:/c.mp4"), .refused(.expired), "31 minutes later the code has expired")
    let replaced = confirmations.ask("Trash c.mp4?", action: "trash:/c.mp4", refused: .expired)
    check(token(replaced) != token(third), "an expired code is replaced")
    let reason = replaced.payload["confirm_token_refused"]?.stringValue ?? ""
    check(reason.contains("expired") && reason.contains("30 minutes"), "the result says the old code expired and how long codes last (got \(reason))")
    clock += 61 * 60
    _ = confirmations.ask("Trash d.mp4?", action: "trash:/d.mp4")
    checkEqual(confirmations.redeem(token(third), for: "trash:/c.mp4"), .refused(.unknown),
               "an hour past its expiry SrtFlow has forgotten it: not one it issued")
    for refusal in [AIConfirmations.Refusal.unknown, .expired, .used, .otherAction] {
        check(refusal.message.contains("confirm_token"), "every refusal names the confirm_token (\(refusal))")
    }
}
