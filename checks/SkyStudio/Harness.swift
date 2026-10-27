import Foundation

// Sky Studio 账号（收费方案第 5 刀）自检的公共小件：计数、断言。编法见 scripts/check-sky-studio.sh。

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

/// 这段 async 代码应该抛 `SkyStudioFailure`；抛了就把它交回来，没抛 / 抛了别的记一条失败。
func expectFailure(_ message: String, file: String = #fileID, line: Int = #line, _ body: () async throws -> Void) async -> SkyStudioFailure? {
    checks += 1
    do {
        try await body()
        failures += 1
        print("FAIL [\(file):\(line)] \(message): expected a SkyStudioFailure, got none")
    } catch let failure as SkyStudioFailure {
        return failure
    } catch {
        failures += 1
        print("FAIL [\(file):\(line)] \(message): expected a SkyStudioFailure, got \(error)")
    }
    return nil
}

/// 本机时间的一刻：2026-10-27 15:04:05 UTC 往后挪几秒。
func moment(_ seconds: TimeInterval = 0) -> Date {
    Date(timeIntervalSince1970: 1_793_113_445).addingTimeInterval(seconds)
}
