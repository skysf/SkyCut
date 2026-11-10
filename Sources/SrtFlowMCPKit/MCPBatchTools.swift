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
        /// 名片里例子前后的两段（2026-11-10 名片迁移：长话进说明书 topic=edit_clips / set_texts / set_shapes）。
        let lead: String
        let example: String
        let tail: String
    }

    private static func source(for name: MCPToolName) -> Source? {
        switch name {
        case .editClips:
            return Source(tool: .editClip, key: "clips", id: "clip_id", lead: "Change many clips in one call with the same fields as edit_clip (ids from get_timeline). Everything is checked first and applied as one undo step; any error applies nothing.",
                          example: #"{"clips":[{"clip_id":"c1","volume_db":-6}]}"#,
                          tail: "Entries apply in order (1-\(maximumItems)); omitted fields stay. Returns the final state of each clip.")
        case .setTexts:
            return Source(tool: .setText, key: "texts", id: "text_id", lead: "Add or change many texts in one call with the same fields as set_text (text_id from get_timeline; leave it out to add). Everything is checked first and applied as one undo step; any error applies nothing.",
                          example: #"{"texts":[{"text_id":"t1","text":"Review title","font_size":36}]}"#,
                          tail: "Entries apply in order (1-\(maximumItems)); omitted fields stay.")
        case .setShapes:
            return Source(tool: .setShape, key: "shapes", id: "shape_id", lead: "Add or change many shapes in one call with the same fields as set_shape (shape_id from get_timeline; leave it out to add). Everything is checked first and applied as one undo step; any error applies nothing.",
                          example: ##"{"shapes":[{"shape_id":"s1","color":"#FFAA00"}]}"##,
                          tail: "Entries apply in order (1-\(maximumItems)); omitted fields stay.")
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
            description: source.lead + "\nExample: " + source.example + "\n" + source.tail,
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
