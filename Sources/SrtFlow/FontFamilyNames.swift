import CoreText
import Foundation

// MARK: - 一款字体在字体文件里的所有族名（name 表）
//
// 管什么：字体文件的 name 表里，同一族常常用几种语言各写一遍名字（nameID 1 族名、16 印刷族名）。Core Text 的
// `kCTFontFamilyNameAttribute` 只给其中一个：用户自己装的苹方（~/Library/Fonts/PingFang-SC-Regular.ttf）给的是「蘋方-簡」，
// 而 AI、set_text、用户嘴里说的都是「PingFang SC」。这里把表里的族名全读出来，字幕的字体按任何一个名字都认得
// （docs/bugfixes/2026-10-14-ai-tool-small-issues-from-blind-test.md 第 5 条）。
// 不管什么：哪些字体能进字幕的清单（FontCatalog、FontCmapSanity）。

enum FontFamilyNames {
    /// 这款字体 name 表里的族名（去重，按表里的顺序）。读不到 name 表就是空。
    static func names(of font: CTFont) -> [String] {
        guard let data = CTFontCopyTable(font, CTFontTableTag(kCTFontTableName), []) as Data? else { return [] }
        return names(inNameTable: data)
    }

    /// 纯值：整张 name 表的字节。只认 Unicode / Windows 平台（UTF-16BE）和 Mac 平台的 Roman 编码；别的编码跳过。
    static func names(inNameTable table: Data) -> [String] {
        let bytes = [UInt8](table)
        guard bytes.count >= 6 else { return [] }
        let count = Int(be16(bytes, 2))
        let storage = Int(be16(bytes, 4))
        var names: [String] = []
        for index in 0..<count {
            let record = 6 + index * 12
            guard record + 12 <= bytes.count else { break }
            let platform = be16(bytes, record)
            let encoding = be16(bytes, record + 2)
            let nameID = be16(bytes, record + 6)
            let length = Int(be16(bytes, record + 8))
            let start = storage + Int(be16(bytes, record + 10))
            guard nameID == 1 || nameID == 16, length > 0, start + length <= bytes.count else { continue }
            let raw = Data(bytes[start..<(start + length)])
            let text: String?
            switch platform {
            case 0, 3: text = String(data: raw, encoding: .utf16BigEndian)
            case 1 where encoding == 0: text = String(data: raw, encoding: .macOSRoman)
            default: text = nil
            }
            guard let name = text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    private static func be16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
}
