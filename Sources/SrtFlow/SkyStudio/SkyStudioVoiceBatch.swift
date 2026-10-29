import Foundation

// MARK: - 克隆的多句怎么装进一次请求（纯值）
// 管什么：按 /models 给的 Unicode code point 上限装满一批；超过上限的一句先在字边界切开，记住每片原来属于哪一句。
// 不管什么：价、HTTP、语音怎么切（SkyStudioVoiceSplit）；上限不在本机抄一份。

struct SkyStudioVoiceBatch: Equatable, Sendable {
    struct Part: Equatable, Sendable {
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
        guard limit > 0 else { throw Problem(message: "Sky Studio did not give a character limit for this voice's language.") }
        var batches: [SkyStudioVoiceBatch] = []
        var pending: [Part] = []
        var used = 0
        func flush() {
            if !pending.isEmpty { batches.append(SkyStudioVoiceBatch(parts: pending)) }
            pending = []
            used = 0
        }
        for (line, text) in lines.enumerated() {
            for piece in try pieces(text, limit: limit) {
                let count = piece.unicodeScalars.count
                if used + count + (pending.isEmpty ? 0 : 1) > limit { flush() }
                if !pending.isEmpty { used += 1 }
                pending.append(Part(line: line, text: piece))
                used += count
                if !pack { flush() }
            }
        }
        flush()
        return batches
    }

    private static func pieces(_ text: String, limit: Int) throws -> [String] {
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [String] = []
        while !remaining.isEmpty {
            if remaining.unicodeScalars.count <= limit { result.append(remaining); break }
            var count = 0
            var end = remaining.startIndex
            var breakAt: String.Index?
            var breakCount = 0
            for index in remaining.indices {
                let character = remaining[index]
                let nextCount = count + character.unicodeScalars.count
                guard nextCount <= limit else { break }
                count = nextCount
                end = remaining.index(after: index)
                if character.isWhitespace || character.isPunctuation { breakAt = end; breakCount = count }
            }
            guard end > remaining.startIndex else {
                throw Problem(message: "A character in the voiceover exceeds Sky Studio's character limit.")
            }
            // 避免把一个英文词切成两份；没有断点的中文按完整 Character 切，不拆代理对 / 组合字。
            if let breakAt, breakCount >= limit / 2 { end = breakAt }
            let piece = String(remaining[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }
            remaining = String(remaining[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}
