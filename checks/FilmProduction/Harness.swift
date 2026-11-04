import Foundation

// 纯值/真实存盘/假 URLSession 的共用断言；这里不启动 App 或媒体管线。
var checks = 0
var failures = 0
func check(_ value: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !value { failures += 1; print("FAIL [\(line)] \(message)") }
}

enum ProductionCheckFailure: Error { case timedOut(String) }
