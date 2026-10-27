import Foundation

// Sky Studio 账号（收费方案第 5 刀第一步）的自检入口。编法与运行见 scripts/check-sky-studio.sh；
// 规则的出处见 docs/architecture/sky-studio-account.md，接口合同在 Sky Studio 仓库的 docs/agents/skycut-api.md。

runKeyChecks()
runMachineChecks()
runMeChecks()
await runAPIChecks()
runLicenseChecks()

if failures > 0 {
    print("✗ \(failures) of \(checks) Sky Studio checks failed.")
    exit(1)
}
print("All \(checks) Sky Studio checks passed.")
