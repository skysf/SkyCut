import Foundation

// 「听声音的引擎」纯计算的自检断言。编法见 scripts/check-listening.sh，口径见 docs/architecture/listening-engine.md「守卫」。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [\(file):\(line)] \(message)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL [\(file):\(line)] \(message): got \(actual), expected \(expected)")
    }
}

/// |实际 − 期望| ≤ 容差 × max(1, |期望|)（大的数按相对差，小的数按绝对差）。
func checkClose(_ actual: Double?, _ expected: Double?, _ message: String, tolerance: Double,
                file: String = #fileID, line: Int = #line) {
    checks += 1
    switch (actual, expected) {
    case (nil, nil):
        return
    case let (a?, e?) where abs(a - e) <= tolerance * max(1, abs(e)):
        return
    default:
        failures += 1
        print("FAIL [\(file):\(line)] \(message): got \(String(describing: actual)), expected \(String(describing: expected))")
    }
}

/// 和 Python 版对账时顺手记下最大的差，跑完打印出来（写进架构文档「和 Python 版对」的就是这个数）。
var largestParityGap = 0.0

func checkParity(_ actual: Double?, _ expected: Double?, _ message: String, file: String = #fileID, line: Int = #line) {
    if let actual, let expected {
        largestParityGap = max(largestParityGap, abs(actual - expected) / max(1, abs(expected)))
    }
    checkClose(actual, expected, message + "（和 Python 版）", tolerance: ListeningParity.tolerance, file: file, line: line)
}
