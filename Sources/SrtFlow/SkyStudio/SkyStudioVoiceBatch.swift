import Foundation

// MARK: - 一段旁白的几句怎么装进几次请求（纯值）
// 管什么（SkyCut 声音方案 8.1）：按 /models 给的 Unicode code point 上限装批（约 60 秒）。`pack` 时整句往里装、装不下就开下一批 ——
// 批和批只在两句之间分，**不切在句子中间**；不 `pack`（这台 Mac 切不开）就一句一单。一句本身就超过上限：先在句末标点（。！？.!?）处分开，
// 一个句子都放不下才在逗号类、空白处分，再不行才按字切；几片记住原来属于哪一句（全齐后拼回一句，SkyStudioVoiceRender）。
// 同一句分出来的几片尽量少：放得下的几个句子留在同一片里（原文照抄，不在中间插换行）。
// 上限可以每句不一样（`limit` 按这一句的字给：服务器按每一批自己的语言卡，SkyStudioModel.characterLimit(text:)）：一批的上限是
// 它装着的几句里最小的那个。
// 不管什么：价、HTTP、语音怎么切（SkyStudioVoiceSplit）；上限不在本机抄一份。

struct SkyStudioVoiceBatch: Equatable, Sendable, Codable {
    struct Part: Equatable, Sendable, Codable {
        let line: Int
        let text: String
    }

    let parts: [Part]
    var prompt: String { parts.map(\.text).joined(separator: "\n") }

    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func make(lines: [String], limit: Int, pack: Bool) throws -> [SkyStudioVoiceBatch] {
        try make(lines: lines, pack: pack) { _ in limit }
    }

    /// `limit`：这一句（按它的字）一次请求最多多少字。
    static func make(lines: [String], pack: Bool, limit: (String) -> Int) throws -> [SkyStudioVoiceBatch] {
        var batches: [SkyStudioVoiceBatch] = []
        var pending: [Part] = []
        var used = 0
        /// 这一批已经装的几句里最小的上限。
        var cap = Int.max
        func flush() {
            if !pending.isEmpty { batches.append(SkyStudioVoiceBatch(parts: pending)) }
            pending = []
            used = 0
            cap = .max
        }
        for (line, text) in lines.enumerated() {
            let own = limit(text)
            guard own > 0 else { throw Problem(message: "Sky Studio did not give a character limit for this voice's language.") }
            for piece in try pieces(Substring(text), limit: own, level: 0) {
                let count = piece.unicodeScalars.count
                if used + count + (pending.isEmpty ? 0 : 1) > min(cap, own) { flush() }
                if !pending.isEmpty { used += 1 }
                pending.append(Part(line: line, text: piece))
                used += count
                cap = min(cap, own)
                if !pack { flush() }
            }
        }
        flush()
        return batches
    }

    // MARK: 一句超过上限

    /// 从粗到细：句末、逗号类、空白。
    private enum Break: CaseIterable { case sentence, clause, space }

    /// 放得下就整句；放不下按 `level` 那一级的断点切成几段、相邻的能合就合（原文照抄），还放不下的那段换下一级。
    private static func pieces(_ text: Substring, limit: Int, level: Int) throws -> [String] {
        let whole = trimmed(text)
        if whole.isEmpty { return [] }
        if whole.unicodeScalars.count <= limit { return [whole] }
        guard level < Break.allCases.count else { return try hardCut(whole, limit: limit) }
        let units = cut(text, at: Break.allCases[level])
        guard units.count > 1 else { return try pieces(text, limit: limit, level: level + 1) }
        var result: [String] = []
        var current = Substring()
        for unit in units {
            let joined = text[(current.isEmpty ? unit.startIndex : current.startIndex) ..< unit.endIndex]
            if trimmed(joined).unicodeScalars.count <= limit { current = joined; continue }
            if !trimmed(current).isEmpty { result.append(trimmed(current)) }
            if trimmed(unit).unicodeScalars.count <= limit { current = unit }
            else { result += try pieces(unit, limit: limit, level: level + 1); current = Substring() }
        }
        if !trimmed(current).isEmpty { result.append(trimmed(current)) }
        return result
    }

    /// 在这一级的断点后面切开（断点后面紧跟的空白、句末和逗号类后面紧跟的收尾标点跟着前一段）。切出来的几段连起来就是原文。
    private static func cut(_ text: Substring, at kind: Break) -> [Substring] {
        var units: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if isBreak(text[index], next: next < text.endIndex ? text[next] : nil, kind: kind) {
                var end = next
                while end < text.endIndex, text[end].isWhitespace || (kind != .space && closers.contains(text[end])) {
                    end = text.index(after: end)
                }
                units.append(text[start ..< end])
                start = end
                index = end
            } else {
                index = next
            }
        }
        if start < text.endIndex { units.append(text[start...]) }
        return units
    }

    private static let fullWidthSentenceEnds: Set<Character> = ["。", "！", "？", "…"]
    private static let sentenceEnds: Set<Character> = [".", "!", "?"]
    private static let fullWidthClauseMarks: Set<Character> = ["，", "、", "；", "："]
    private static let clauseMarks: Set<Character> = [",", ";", ":"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", "」", "』", ")", "）", "]", "》", "〉", "】", "…", ".", "!", "?", "。", "！", "？"]

    /// 全角的句末、逗号类总算断点；半角的要后面是空白或者到头了（「U.S.」「3.5」「1,000」「10:30」不切）。
    private static func isBreak(_ character: Character, next: Character?, kind: Break) -> Bool {
        let latinEnd = next.map { $0.isWhitespace || closers.contains($0) } ?? true
        switch kind {
        case .sentence: return fullWidthSentenceEnds.contains(character) || (sentenceEnds.contains(character) && latinEnd)
        case .clause: return fullWidthClauseMarks.contains(character) || (clauseMarks.contains(character) && (next.map(\.isWhitespace) ?? true))
        case .space: return character.isWhitespace
        }
    }

    /// 一个断点都没有（很长的一串字）：按完整的字切，不拆代理对 / 组合字。
    private static func hardCut(_ text: String, limit: Int) throws -> [String] {
        var result: [String] = []
        var current = ""
        var count = 0
        for character in text {
            let size = character.unicodeScalars.count
            guard size <= limit else { throw Problem(message: "A character in the voiceover exceeds Sky Studio's character limit.") }
            if count + size > limit { result.append(current); current = ""; count = 0 }
            current.append(character)
            count += size
        }
        if !current.isEmpty { result.append(current) }
        return result.map(trimmed).filter { !$0.isEmpty }
    }

    private static func trimmed<S: StringProtocol>(_ text: S) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
