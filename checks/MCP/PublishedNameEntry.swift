import Foundation
import SrtFlowMCPKit

// MARK: - One name a published style or card uses, checked against a tool vocabulary
//
// What it owns: the rule for one entry of the published names snapshot — a code span `tool name name=value …` (the tool
// exists, each name belongs to that tool at any depth, each value is one of its options and in its range; `<placeholder>`,
// `{…}` / `[…]` and `a|b` alternatives as the content gate allows them) or bare names (each a SkyCut name, a track like V1,
// a number, an a–b range, a #RRGGBB colour or a placeholder). It ports the content gate checker's rules for code spans
// and values (kept with the content, outside this repo), so content the gate let through passes here on the build it
// was checked against.
// What it does not own: the vocabulary (ToolVocabulary) or the snapshot file (PublishedNamesChecks).

enum PublishedNameEntry {
    /// What is wrong with one entry; empty when every part is a real SkyCut name.
    static func problems(_ entry: String, in vocabulary: ToolVocabulary) -> [String] {
        let tokens = entry.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let head = tokens.first else { return ["it is empty"] }
        guard vocabulary.tools[head] != nil else { return tokens.compactMap { bareProblem($0, vocabulary) } }
        var found: [String] = []
        for token in tokens.dropFirst() {
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = parts[0], value = parts.count > 1 ? parts[1] : nil
            guard !name.isEmpty else {
                found.append("\(token) is not a name or name=value")
                continue
            }
            guard let specs = vocabulary.resolve(tool: head, name: name) else {
                found.append("\(head) has no parameter \(name)")
                continue
            }
            guard let value else { continue }
            if head == MCPToolName.skycutGuide.rawValue {
                if name == "topic", vocabulary.topics[value] == nil {
                    found.append("the guide has no topic \(value)")
                    continue
                }
                if name == "section" {
                    let topic = tokens.dropFirst().last { $0.hasPrefix("topic=") }.map { String($0.dropFirst("topic=".count)) }
                    if let topic, let sections = vocabulary.topics[topic], !sections.contains(value) {
                        found.append("guide topic \(topic) has no section \(value) (it has \(sections.joined(separator: ", ")))")
                    }
                    continue
                }
            }
            if let why = valueProblem(value, specs) { found.append("\(name)=\(value): \(why)") }
        }
        return found
    }

    private static func bareProblem(_ token: String, _ vocabulary: ToolVocabulary) -> String? {
        if token.contains("=") { return "\(token): name=value must follow a tool name" }
        if vocabulary.names.contains(token) || matches(token, track) || matches(token, number) || matches(token, range)
            || matches(token, hexColour) || (token.hasPrefix("<") && token.hasSuffix(">")) {
            return nil
        }
        return "\(token) is not a SkyCut tool, parameter, option or result field"
    }

    /// A value fits when every `|` alternative fits one of the places the name is defined.
    static func valueProblem(_ value: String, _ specs: [ToolVocabulary.Spec]) -> String? {
        if value.hasPrefix("<") && value.hasSuffix(">") { return nil }
        if value.hasPrefix("{") || value.hasPrefix("[") { return nil }
        for alternative in value.split(separator: "|", omittingEmptySubsequences: false).map(String.init) {
            if alternative.isEmpty { return "an empty option" }
            let reasons = specs.map { alternativeProblem(alternative, $0) }
            if reasons.contains(where: { $0 == nil }) { continue }
            return Set(reasons.compactMap { $0 }).sorted().joined(separator: "; ")
        }
        return nil
    }

    private static func alternativeProblem(_ text: String, _ spec: ToolVocabulary.Spec) -> String? {
        let numeric = !spec.types.isDisjoint(with: ["number", "integer"])
        let isNumber = matches(text, number) || matches(text, range)
        if let options = spec.options {
            if options.contains(where: { $0.stringValue == text }) { return nil }
            let numbers = options.compactMap(\.doubleValue)
            if matches(text, number), let value = Double(text), numbers.contains(value) { return nil }
            // A number's options (tilt: -45 / 0 / 45) must be met exactly; a string option next to a number (duration:
            // a number or "auto") lets a number through to the range check.
            if !numbers.isEmpty || !(numeric && isNumber) {
                return "not one of its options (\(options.prefix(20).map(describe).joined(separator: " | ")))"
            }
        }
        if numeric && isNumber { return rangeProblem(text, spec) }
        if spec.types.contains("boolean") { return ["true", "false"].contains(text) ? nil : "only true or false" }
        if numeric && !spec.types.contains("string") { return "must be a number" }
        return nil
    }

    private static func rangeProblem(_ text: String, _ spec: ToolVocabulary.Spec) -> String? {
        let values = captures(text, range).compactMap(Double.init) + (matches(text, number) ? [Double(text)].compactMap { $0 } : [])
        guard !values.isEmpty else { return "not a number (or an a–b range)" }
        for value in values {
            if let low = spec.minimum, value < low { return "\(text) is below the minimum \(describe(.number(low)))" }
            if let high = spec.maximum, value > high { return "\(text) is above the maximum \(describe(.number(high)))" }
        }
        return nil
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .number(let number): return number.rounded() == number ? String(Int(number)) : String(number)
        case .bool(let flag): return flag ? "true" : "false"
        default: return value.encodedString()
        }
    }

    // The content checker's patterns: tracks, plain numbers, a–b ranges (hyphen, en or em dash), colours.
    private static let track = pattern(#"^(?:V\d+|A\d+|master)$"#)
    private static let number = pattern(#"^-?\d+(?:\.\d+)?$"#)
    private static let range = pattern(#"^(-?\d+(?:\.\d+)?)\s*(?:–|—|-)\s*(-?\d+(?:\.\d+)?)$"#)
    private static let hexColour = pattern(#"^#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?$"#)

    private static func pattern(_ text: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: text) } catch { fatalError("bad pattern \(text): \(error)") }
    }

    private static func matches(_ text: String, _ regex: NSRegularExpression) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The capture groups of a whole-string match (the two ends of a range); empty when it doesn't match.
    private static func captures(_ text: String, _ regex: NSRegularExpression) -> [String] {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
