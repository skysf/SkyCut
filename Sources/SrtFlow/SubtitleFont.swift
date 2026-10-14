import Foundation

/// 字幕能用的一款字体（FontCatalog 扫出来的）：族名、文件、有没有中文字形，以及字体文件里这一族的别的名字。
struct SubtitleFont: Identifiable, Hashable, Sendable {
    var id: String { familyName }
    var familyName: String
    var fileURL: URL
    var supportsChinese: Bool
    /// 同一族在字体文件里的别的名字（别的语言写的族名，`FontFamilyNames`）：用户装的「蘋方-簡」那份文件里还写着
    /// 「PingFang SC」。AI 和用户都可能用其中任何一个叫它。
    var aliases: [String] = []

    /// 这个名字叫的是不是这一款（不分大小写）：族名或者别名。
    func answers(to name: String) -> Bool {
        ([familyName] + aliases).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}
