import Foundation

// 「听声音的引擎」第 2、3 步的纯计算自检（scripts/check-listening.sh；docs/architecture/listening-engine.md「守卫」）。
//   不带参数：跑全部自检。
//   --dump <目录>：只把和 Python 版对账的输入写出来（重算对照值时用），不跑自检。

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--dump") {
    guard flag + 1 < arguments.count else {
        print("✗ 用法：--dump <目录>")
        exit(2)
    }
    do {
        try ListeningDump.write(to: URL(fileURLWithPath: arguments[flag + 1]))
        exit(0)
    } catch {
        print("✗ 写不出来：\(error)")
        exit(1)
    }
}

runDFTChecks()
runESTOIChecks()
runMaskerChecks()
runTraitChecks()
runParityChecks()
print("和 Python 版最大的相对差：\(largestParityGap)（容差 \(ListeningParity.tolerance)）")
if failures > 0 {
    print("✗ \(failures) of \(checks) listening checks failed.")
    exit(1)
}
print("All \(checks) listening checks passed.")
