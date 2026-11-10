import Foundation
import SrtFlowCore

// MARK: - 一句原文切成「词」（纯值）
//
// 管什么：配音的字幕要显示**原文**（不是识别出来的字），时间从别处来（SpeechWordAlignment 对齐、SpeechWordEstimate 估）。
// 原文照字幕那一套认的写法切成词（和 SpeechWordTimes、AIVoiceWords 交给 SubtitleSegmenter 的一样）：
// - 中日韩的字（假名、汉字、谚文）一个字一个词；别的字（字母、数字）连着的算一个词，空白分开；
// - 标点贴在前一个词后面（「好，」「world.」「U.S.」「don't」）；句首、空白后面的标点（开引号）贴在后一个词前面；
// - 原文里词前有空白的，词前带一个半角空格（几个空白只算一个）—— 不按文字猜，韩文词之间的空格也留着。
// 每个词还带：在原文里的位置（UTF-16，含贴着的标点，对齐时按它找对上的字）、说它要几份（中日韩的字、数字一个一份，
// 别的字母 0.3 份：英文一秒十几个字母、中文四五个字）、后面停几份（句末标点 2、逗号类 1；缩写里的点不算）。
// 不管什么：时间。

struct SpeechWordToken: Equatable, Sendable {
    /// 交给字幕的写法（词前原文有空白时带一个空格）。
    var text: String
    /// 在原文里的位置（UTF-16，含贴着的标点、不含词前的空格）。
    var range: Range<Int>
    /// 说这个词要几份。
    var units: Double
    /// 这个词后面停几份。
    var pause: Double
}

enum SpeechWordTokens {
    static let fullWidthUnit = 1.0
    static let digitUnit = 1.0
    static let letterUnit = 0.3
    static let sentencePause = 2.0
    static let clausePause = 1.0
    static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    static let clauseMarks: Set<Character> = [",", ";", ":", "，", "；", "：", "、"]

    static func tokens(_ text: String) -> [SpeechWordToken] {
        var tokens: [SpeechWordToken] = []
        var current: SpeechWordToken?
        var currentIsFullWidth = false
        /// 下一个词前面的东西：空白（记成一个空格）和句首 / 空白后面的标点。
        var pending = ""
        var pendingStart: Int?
        var offset = 0
        func flush() {
            guard var token = current else { return }
            token.pause = pause(after: token.text)
            tokens.append(token)
            current = nil
        }
        func open(_ character: Character, units: Double, at start: Int, width: Int) {
            current = SpeechWordToken(text: pending + String(character), range: (pendingStart ?? start) ..< start + width, units: units, pause: 0)
            pending = ""
            pendingStart = nil
        }
        for character in text {
            let width = character.utf16.count
            defer { offset += width }
            if character.isWhitespace {
                flush()
                if !(tokens.isEmpty && pending.isEmpty), !pending.hasSuffix(" ") { pending += " " }
            } else if isFullWidthLetter(character) {
                flush()
                open(character, units: fullWidthUnit, at: offset, width: width)
                currentIsFullWidth = true
            } else if character.isLetter || character.isNumber {
                let units = character.isNumber ? digitUnit : letterUnit
                if var token = current, !currentIsFullWidth, pending.isEmpty {
                    token.text.append(character)
                    token.range = token.range.lowerBound ..< offset + width
                    token.units += units
                    current = token
                } else {
                    flush()
                    open(character, units: units, at: offset, width: width)
                    currentIsFullWidth = false
                }
            } else if var token = current, pending.isEmpty {
                // 标点、符号贴在前一个词后面。
                token.text.append(character)
                token.range = token.range.lowerBound ..< offset + width
                current = token
            } else {
                // 句首、空白后面的标点：贴在下一个词前面。
                if pendingStart == nil { pendingStart = offset }
                pending.append(character)
            }
        }
        flush()
        // 末尾空白后面还剩的标点（「Hello .」）贴在最后一个词后面；一个词都没有（全是标点）就没有词。
        let rest = pending.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty, var last = tokens.popLast() {
            last.text += pending.hasPrefix(" ") ? " " + rest : rest
            last.range = last.range.lowerBound ..< offset
            last.pause = max(last.pause, pause(after: rest))
            tokens.append(last)
        }
        return tokens
    }

    /// 中日韩的字（全宽的字母类：假名、汉字、谚文）：一个字一个词。
    static func isFullWidthLetter(_ character: Character) -> Bool {
        character.isLetter && (character.unicodeScalars.first.map(SubtitleLineMeasure.isFullWidth) ?? false)
    }

    /// 词尾的标点决定后面停几份：句末 2、逗号类 1；缩写（U.S.）的点不算。
    private static func pause(after text: String) -> Double {
        let trailing = text.reversed().prefix { !$0.isLetter && !$0.isNumber }
        let acronym = text.dropLast(trailing.count).contains(".")
        if trailing.contains(where: { sentenceEnds.contains($0) && !(acronym && $0 == ".") }) { return sentencePause }
        return trailing.contains(where: clauseMarks.contains) ? clausePause : 0
    }
}
