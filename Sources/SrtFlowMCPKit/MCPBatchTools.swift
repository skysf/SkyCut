import Foundation

// MARK: - 批量编辑的工具说明与单项参数表引用
//
// 管什么：edit_clips / set_texts / set_shapes 的清单。条目的完整字段说明只在单项工具存一份；
// 给客户端列出身份字段并允许其余字段，MCPArgumentCheck 校验时展开为单项的完整 schema（含别名）。
// 不管什么：编辑与事务提交（App 的 AIBatchEditTools / AIBatchEdit）。

public enum MCPBatchTools {
    public static let maximumItems = 100

    private struct Source {
        let tool: MCPToolName
        let key: String
        let id: String
    }

    private static func source(for name: MCPToolName) -> Source? {
        switch name {
        case .editClips: return Source(tool: .editClip, key: "clips", id: "clip_id")
        case .setTexts: return Source(tool: .setText, key: "texts", id: "text_id")
        case .setShapes: return Source(tool: .setShape, key: "shapes", id: "shape_id")
        default: return nil
        }
    }

    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        guard let source = source(for: name) else { preconditionFailure("Not a batch tool: \(name)") }
        // 10 万字符的总清单不能复制三套参数。AI 用到时读单项工具，参数核对仍用单项完整的那一份。
        let item: JSONValue = [
            "type": "object", "properties": [source.id: ["type": "string"]], "additionalProperties": true,
            "required": source.tool.definition.inputSchema["required"] ?? []
        ]
        var list = MCPSchema.array(of: item, "Arguments of \(source.tool.rawValue).", minItems: 1).objectValue ?? [:]
        list["maxItems"] = .number(Double(maximumItems))
        return MCPToolDefinition(
            name, title: "Batch \(source.tool.rawValue)",
            description: """
            Batch \(source.tool.rawValue): read that tool for all entry fields/defaults. 1-\(maximumItems) ordered entries; all must \
            pass before one commit/undo and at most one preview rebuild. Errors name the zero-based index; nothing is \
            applied. Repeated ids edit again. \
            \(source.tool == .editClip ? "Omitted fields stay unchanged." : "New entries without start use the initial playhead.") \
            Results follow input order, \
            showing final state. No changes: no undo. project is batch-wide. \
            \(source.tool == .editClip ? "Overlaps are checked after each entry; move obstructions first." : "Omit the id to add; give it to edit.")
            """,
            input: MCPSchema.object([source.key: .object(list)], required: [source.key])
        )
    }

    /// 参数名核对时按单项完整 schema 展开，不能因发现清单里省了字段而丢掉未知参数检查。
    public static func validationSchema(for name: MCPToolName) -> JSONValue? {
        guard let source = source(for: name) else { return nil }
        var item = source.tool.definition.inputSchema.objectValue ?? [:]
        var fields = item["properties"]?.objectValue ?? [:]
        fields.removeValue(forKey: "project")
        if source.tool == .setShape { fields["length"] = fields["width"] }
        item["properties"] = .object(fields)
        var schema = name.definition.inputSchema.objectValue ?? [:]
        var properties = schema["properties"]?.objectValue ?? [:]
        var list = properties[source.key]?.objectValue ?? [:]
        list["items"] = .object(item)
        properties[source.key] = .object(list)
        schema["properties"] = .object(properties)
        return .object(schema)
    }
}
