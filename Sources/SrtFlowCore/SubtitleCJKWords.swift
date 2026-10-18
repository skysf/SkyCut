import Foundation
import NaturalLanguage

// 一句字里的中日文词在哪（2026-10-18）：字幕折行（`SubtitleRowBreaks`，App 里的 SubtitleLineWrap 用它）和生成字幕切条
// （`SubtitleBreaks.wordBoundaries`）都不许切在一个词的中间，词边界只在这里算一份。
//
// 只把汉字 / 假名连成的那几段交给系统分词（NLTokenizer），每段单独分：整句一起分时，中英文连着写的句子系统会漏掉一大截
// （「南极的冰山一望无际Penguins站在风里等待the…」从「的」到「the」整段没有词，2026-10-18 实测）。语言按文字定：有假名是日文，
// 否则按简体中文 —— 不问 NLLanguageRecognizer（一次约 1.5 毫秒，预览每画一次字幕都要折行；中英混排时它还会认成英文）。
// 分词器中日文各一个、上锁复用（新建一个约 0.2 毫秒，复用一次约 0.01 毫秒）。分词漏掉的字各自算一个词（宁可多一个能断的地方，
// 也不把一大截当成一个词）。
// 案例：docs/bugfixes/2026-10-18-subtitle-wrap-splits-chinese-words.md。
// 不管什么：断在哪好（SubtitleRowBreaks）、字多宽（App 里的 SubtitleLineWrap）。

public enum SubtitleCJKWords {
    /// 汉字和假名（不含标点、全角字母、注音）：连成一段交给分词。
    public static func isHanOrKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,    // 平假名、片假名
             0x31F0...0x31FF,    // 片假名扩展
             0x3400...0x4DBF,    // 扩展 A
             0x4E00...0x9FFF,    // 汉字
             0xF900...0xFAFF,    // 兼容汉字
             0x20000...0x3134F:  // 扩展 B–G
            return true
        default:
            return false
        }
    }

    /// 这句字里每个中日文词的位置（UTF-16，按先后）。
    public static func words(in text: String) -> [NSRange] {
        let whole = text as NSString
        let japanese = text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        var result: [NSRange] = []
        var index = 0
        while index < whole.length {
            let first = whole.rangeOfComposedCharacterSequence(at: index)
            guard isRun(whole.substring(with: first)) else {
                index = NSMaxRange(first)
                continue
            }
            var end = NSMaxRange(first)
            while end < whole.length {
                let next = whole.rangeOfComposedCharacterSequence(at: end)
                guard isRun(whole.substring(with: next)) else { break }
                end = NSMaxRange(next)
            }
            let run = whole.substring(with: NSRange(location: index, length: end - index))
            result += Tokenizers.shared.words(in: run, japanese: japanese).map { NSRange(location: index + $0.location, length: $0.length) }
            index = end
        }
        return result
    }

    /// 落在一个中日文词中间的位置（UTF-16：词的第二个字起、到最后一个字为止）。
    public static func interior(of text: String) -> Set<Int> {
        var result: Set<Int> = []
        for word in words(in: text) where word.length > 1 {
            result.formUnion((word.location + 1)..<NSMaxRange(word))
        }
        return result
    }

    private static func isRun(_ character: String) -> Bool {
        !character.isEmpty && character.unicodeScalars.allSatisfy(isHanOrKana)
    }
}

/// 中日文各一个分词器，上锁复用（NLTokenizer 不能多线程同时用；预览、AI 读框、烧录可能在不同线程上折行）。
private final class Tokenizers: @unchecked Sendable {
    static let shared = Tokenizers()

    private let lock = NSLock()
    private let chinese = NLTokenizer(unit: .word)
    private let japanese = NLTokenizer(unit: .word)

    /// 一段汉字 / 假名里的词（UTF-16，相对这一段）；分词漏掉的字各自算一个词。
    func words(in run: String, japanese isJapanese: Bool) -> [NSRange] {
        lock.lock()
        defer { lock.unlock() }
        let tokenizer = isJapanese ? japanese : chinese
        tokenizer.string = run
        tokenizer.setLanguage(isJapanese ? .japanese : .simplifiedChinese)
        let whole = run as NSString
        var result: [NSRange] = []
        var covered = 0
        func singles(upTo end: Int) {
            while covered < end {
                let one = whole.rangeOfComposedCharacterSequence(at: covered)
                result.append(one)
                covered = NSMaxRange(one)
            }
        }
        tokenizer.enumerateTokens(in: run.startIndex..<run.endIndex) { range, _ in
            let low = range.lowerBound.utf16Offset(in: run), high = range.upperBound.utf16Offset(in: run)
            singles(upTo: low)
            if high > covered {
                result.append(NSRange(location: covered, length: high - covered))
                covered = high
            }
            return true
        }
        singles(upTo: whole.length)
        return result
    }
}
