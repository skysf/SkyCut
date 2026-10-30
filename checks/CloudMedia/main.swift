import Foundation

// 只验证生产仍在共用的每日账与阶段；接口请求在 check-sky-studio。
runSpendChecks()
runPhaseChecks()
runTaskSummaryChecks()
if failures > 0 {
    print("✗ \(failures) of \(checks) cloud media checks failed.")
    exit(1)
}
print("All \(checks) cloud media checks passed.")
