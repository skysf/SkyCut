import Foundation

// MARK: - AI 传来的参数名，工具的说明上有没有
//
// 管什么：一次工具调用里有没有这个工具的说明（`inputSchema`）上没有的名字 —— 第一层、说明里写了字段的里层对象、数组里的对象都查；
// 有就回一句写给 AI 的话，App 整个调用不做（AIToolRouter.handle）。以前不认识的名字直接丢掉：Codex 给 set_text 传了 `end`，
// 字照样加上、时长悄悄用了默认的 3 秒（docs/bugfixes/2026-10-27-unknown-tool-arguments-silently-ignored.md）。
// 值是 null 的不算（等于没传）。里层对象的说明没写字段就照收（以前 generate_media 的 `options` 原样转给 fal 的模型；2026-10-28 起清单里没有这样的参数了）；
// 第一层没写字段说的是「这个工具不收参数」，照查。
// 不管什么：值的类型和范围（各工具读参数时自己管，AIToolArguments）。

public enum MCPArgumentCheck {
    /// 哪个工具都可以带的名字：`project`。不收 project 的工具（get_job、open_folder……）带了也不碍事 ——
    /// 子代理被要求每次都带（docs/architecture/ai-control-mcp.md 第四节第 46 条），不能因为这个挡掉。
    static let anywhere: Set<String> = ["project"]

    /// 实现里认、说明上没写的别名（只列真在读的）：set_shape 把 `length` 当成 `width`（线的长度，说明里写在 width 那一句）。
    static let aliases: [MCPToolName: Set<String>] = [.setShape: ["length"]]

    /// 有说明上没有的名字，回一句写给 AI 的话（英文）；都认识回 nil。
    public static func problem(tool: MCPToolName, arguments: JSONValue) -> String? {
        let schema = tool.definition.inputSchema
        let extra = anywhere.union(aliases[tool] ?? [])
        guard let finding = firstUnknown(in: arguments, schema: schema, path: nil, extra: extra) else { return nil }
        return message(tool: tool, finding)
    }

    /// 找到的第一个不认识的名字：在哪（nil = 第一层）、叫什么、那里收哪些。
    struct Finding: Equatable {
        let path: String?
        let key: String
        let fields: [String]
    }

    /// 按说明一层层往里找。名字按字母顺序看，同样的调用每次报同一个。
    static func firstUnknown(in value: JSONValue, schema: JSONValue, path: String?, extra: Set<String>) -> Finding? {
        switch value {
        case .object(let object):
            guard let fields = fieldNames(of: schema, topLevel: path == nil) else { return nil }
            let known = Set(fields).union(extra)
            let keys = object.keys.sorted()
            if let key = keys.first(where: { !known.contains($0) && object[$0]?.isNull == false }) {
                return Finding(path: path, key: key, fields: fields)
            }
            for key in keys {
                guard let child = object[key], let childSchema = schema["properties"]?[key] else { continue }
                let childPath = path.map { "\($0).\(key)" } ?? key
                if let found = firstUnknown(in: child, schema: childSchema, path: childPath, extra: []) { return found }
            }
            return nil
        case .array(let items):
            guard let itemSchema = schema["items"], let path else { return nil }
            for (index, item) in items.enumerated() {
                if let found = firstUnknown(in: item, schema: itemSchema, path: "\(path)[\(index)]", extra: []) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    /// 说明里这个对象写了哪些字段；里层对象没写字段（自由的对象）回 nil = 不查。第一层空着 = 不收参数。
    static func fieldNames(of schema: JSONValue, topLevel: Bool) -> [String]? {
        guard let properties = schema["properties"]?.objectValue else { return topLevel ? [] : nil }
        if properties.isEmpty && !topLevel { return nil }
        return properties.keys.sorted()
    }

    static func message(tool: MCPToolName, _ finding: Finding) -> String {
        let quoted = "\"\(finding.key)\""
        var text: String
        if let path = finding.path {
            text = "\(tool.rawValue) has no field \(quoted) in \(path), so nothing was done. "
            text += finding.fields.isEmpty ? "" : "The fields there: \(finding.fields.joined(separator: ", "))."
        } else if finding.fields.isEmpty {
            text = "\(tool.rawValue) takes no parameters (it got \(quoted)), so nothing was done."
        } else {
            text = "\(tool.rawValue) has no parameter \(quoted), so nothing was done. Its parameters: \(finding.fields.joined(separator: ", "))."
        }
        if let hint = hint(for: finding.key, fields: finding.fields) { text += " " + hint }
        return text
    }

    /// 两种最常见的写错：大小写 / 下划线不一样（fontSize → font_size）；给了结束时间而工具要的是时长。
    static func hint(for key: String, fields: [String]) -> String? {
        func normalized(_ name: String) -> String { name.lowercased().filter { $0 != "_" && $0 != "-" } }
        if let match = fields.first(where: { normalized($0) == normalized(key) }) { return "Did you mean \"\(match)\"?" }
        if ["end", "end_time"].contains(key.lowercased()), fields.contains("duration") {
            return "For an end time, give duration in seconds (end minus start)."
        }
        return nil
    }
}
