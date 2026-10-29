import Foundation
import SrtFlowMCPKit
import SrtFlowCore

// MARK: - 语音服务报的时间读成词（纯值）
// 管什么：Eleven 的多段字符时间（同一条全局时间轴）和常见词数组；跨 chunk 的词也拼在一起。
// 不管什么：请求、落盘、字幕排版。不能读全或时间倒退就返回空，不能把缺了后半段的词流交出去。

struct SpeechWordTime: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

enum SpeechWordTimes {
    /// 和本机配音同一份词约定：英文前导空格，CJK 不补空格；尾端只认实际文件的时长。
    static func timedWords(_ times: [SpeechWordTime], text: String, duration: Double) -> [TimedWord] {
        let spoken = text.filter { $0.isLetter || $0.isNumber }.count
        let reported = times.reduce(0) { $0 + $1.text.filter { $0.isLetter || $0.isNumber }.count }
        guard !times.isEmpty, duration > 0, spoken > 0, Double(reported) >= Double(spoken) * 0.7,
              Double(reported) <= Double(spoken) * 1.3 else { return [] }
        var result: [TimedWord] = []
        for time in times {
            let start = max(0, time.start)
            guard start < duration else { continue }
            let end = min(duration, max(start + 0.02, time.end))
            let core = time.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !core.isEmpty else { continue }
            let cjk = core.unicodeScalars.first.map(isCJK) ?? false
            result.append(TimedWord(text: result.isEmpty || cjk ? core : " " + core, start: start, end: end))
        }
        return result
    }

    static func parse(_ raw: JSONValue) -> [SpeechWordTime] {
        let words: [SpeechWordTime]
        if let alignments = alignments(raw) {
            var characters: [SpeechWordTime] = []
            for alignment in alignments {
                guard let chunk = Self.characters(in: alignment) else { return [] }
                characters += chunk
            }
            guard sane(characters) else { return [] }
            words = group(characters)
        } else if let entries = raw.arrayValue {
            var parsed: [SpeechWordTime] = []
            for entry in entries {
                if let object = entry.objectValue {
                    guard let text = firstText(object, ["word", "text", "token", "char", "character"]),
                          let start = firstNumber(object, ["start", "start_time", "start_s", "startTime", "begin"]),
                          let end = firstNumber(object, ["end", "end_time", "end_s", "endTime", "stop"]) else { return [] }
                    parsed.append(SpeechWordTime(text: text, start: start, end: end))
                } else if let triple = entry.arrayValue, triple.count >= 3,
                          let text = triple[0].stringValue, let start = triple[1].doubleValue, let end = triple[2].doubleValue {
                    parsed.append(SpeechWordTime(text: text, start: start, end: end))
                } else { return [] }
            }
            words = parsed.allSatisfy { $0.text.count == 1 } && parsed.contains { $0.text.allSatisfy(\.isWhitespace) }
                ? group(parsed) : parsed.filter { !$0.text.allSatisfy(\.isWhitespace) }
        } else { return [] }
        return sane(words) ? words : []
    }

    private static func sane(_ words: [SpeechWordTime]) -> Bool {
        var previous = -Double.infinity
        for word in words {
            guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.end >= word.start, word.start >= previous else { return false }
            previous = word.start
        }
        return true
    }

    private static func alignments(_ raw: JSONValue) -> [[String: JSONValue]]? {
        if let object = alignment(raw) { return [object] }
        guard let entries = raw.arrayValue, !entries.isEmpty else { return nil }
        let found = entries.compactMap(alignment)
        // 有一段像字符时间，就要求每一段都读到；不能退回把坏 chunk 当一个普通词。
        guard !found.isEmpty else { return nil }
        return found.count == entries.count ? found : [[:]]
    }

    private static func alignment(_ raw: JSONValue) -> [String: JSONValue]? {
        guard let object = raw.objectValue else { return nil }
        if object["characters"] != nil { return object }
        for key in ["alignment", "normalized_alignment"] {
            if let nested = object[key]?.objectValue, nested["characters"] != nil { return nested }
        }
        return nil
    }

    private static func characters(in alignment: [String: JSONValue]) -> [SpeechWordTime]? {
        guard let chars = alignment["characters"]?.arrayValue,
              let starts = alignment["character_start_times_seconds"]?.arrayValue,
              let ends = alignment["character_end_times_seconds"]?.arrayValue,
              chars.count == starts.count, chars.count == ends.count else { return nil }
        var result: [SpeechWordTime] = []
        for index in chars.indices {
            guard let text = chars[index].stringValue, let start = starts[index].doubleValue, let end = ends[index].doubleValue else { return nil }
            result.append(SpeechWordTime(text: text, start: start, end: end))
        }
        return result
    }

    private static func group(_ characters: [SpeechWordTime]) -> [SpeechWordTime] {
        var result: [SpeechWordTime] = []
        var current: SpeechWordTime?
        func flush() {
            if let word = current { result.append(word) }
            current = nil
        }
        for character in characters {
            if character.text.allSatisfy(\.isWhitespace) { flush(); continue }
            if let scalar = character.text.unicodeScalars.first, isCJK(scalar) {
                flush()
                result.append(character)
            } else if current == nil, !result.isEmpty, character.text.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) {
                result[result.count - 1].text += character.text
                result[result.count - 1].end = character.end
            } else if var word = current {
                word.text += character.text
                word.end = character.end
                current = word
            } else {
                current = character
            }
        }
        flush()
        return result
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
    }

    private static func firstText(_ object: [String: JSONValue], _ keys: [String]) -> String? {
        keys.compactMap { object[$0]?.stringValue }.first
    }

    private static func firstNumber(_ object: [String: JSONValue], _ keys: [String]) -> Double? {
        keys.compactMap { object[$0]?.doubleValue }.first
    }
}
