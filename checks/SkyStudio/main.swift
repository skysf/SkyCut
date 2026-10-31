import Foundation

// Sky Studio 账号与照授权拦（收费方案第 5 刀）的自检入口。编法与运行见 scripts/check-sky-studio.sh；
// 规则的出处见 docs/architecture/sky-studio-account.md，接口合同在 Sky Studio 仓库的 docs/agents/skycut-api.md。

runKeyChecks()
runMachineChecks()
runMeChecks()
await runAPIChecks()
runLicenseChecks()
runGateChecks()
await runJobChecks()
await runJobRunChecks()
await runSpendChecks()
await runApprovalChecks()
runVoiceChecks()
await runVoiceBudgetChecks()
runGenerationChecks()
runModelPolicyChecks()
await runModelExpansionChecks()
runGenerationFrameChecks()

if failures > 0 {
    print("✗ \(failures) of \(checks) Sky Studio checks failed.")
    exit(1)
}
print("All \(checks) Sky Studio checks passed.")
