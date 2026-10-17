import Foundation

// 版本名怎么拼进文件名（`AIVersionName`，AI 多开方案板 5、L 节）：「南极 - 30s」；空的、只有空白的不加；`/` `:` 换成 `-`；太长截掉；
// 名字里已经带着这个版本不再叠一遍（导出「南极 - 30s」这个工程时又给了 30s）。

func runVersionNameChecks() {
    checkEqual(AIVersionName.stem("南极", version: "30s"), "南极 - 30s", "the version goes after the name")
    checkEqual(AIVersionName.stem("南极", version: nil), "南极", "no version, no suffix")
    checkEqual(AIVersionName.stem("南极", version: "   "), "南极", "a blank version is no version")
    checkEqual(AIVersionName.stem("Trip", version: "9:16 / v2"), "Trip - 9-16 - v2", "path and colon characters become dashes")
    checkEqual(AIVersionName.stem("南极 - 30s", version: "30s"), "南极 - 30s", "a name that already ends with the version is not doubled")
    checkEqual(AIVersionName.stem("南极 - 30S", version: "30s"), "南极 - 30S", "the doubling check ignores case")
    let long = String(repeating: "x", count: 60)
    checkEqual(AIVersionName.clean(long)?.count, AIVersionName.maxLength, "a long version is cut to \(AIVersionName.maxLength) characters")
    checkEqual(AIVersionName.clean(".hidden"), "hidden", "a leading dot is dropped (no hidden files)")
}
