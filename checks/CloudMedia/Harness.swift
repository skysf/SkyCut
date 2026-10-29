import Foundation
import SrtFlowMCPKit

// 云端媒体通用阶段与每日额度的自检断言。编法见 scripts/check-cloud-media.sh。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line, file: String = #fileID) {
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

func checkClose(_ actual: Double?, _ expected: Double, _ message: String, tolerance: Double = 1e-9, file: String = #fileID, line: Int = #line) {
    checks += 1
    guard let actual, abs(actual - expected) <= tolerance else {
        failures += 1
        print("FAIL [\(file):\(line)] \(message): got \(String(describing: actual)), expected \(expected)")
        return
    }
}

/// 这段代码应该抛错；没抛就记一条失败。
func checkThrows(_ message: String, file: String = #fileID, line: Int = #line, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("FAIL [\(file):\(line)] \(message): expected an error, got none")
    } catch {}
}
