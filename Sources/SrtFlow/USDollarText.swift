import Foundation

// 历史工程的美元计价记录仍按原样显示；当前云端任务一律记 Sky Studio 积分。
enum USDollarText {
    /// 给人看的美元数：一分钱以上写两位小数，不到一分钱写到有效的那位（音效一秒 $0.0018）。
    static func text(_ usd: Double) -> String {
        if usd >= 0.01 || usd == 0 { return String(format: "$%.2f", usd) }
        let text = String(format: "%.4f", usd)
        var trimmed = text
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        return "$" + trimmed
    }
}
