import Foundation

// MARK: - 说明书：批量编辑这一组（第二批，2026-11-10）
//
// 管什么：edit_clips、set_texts、set_shapes 名片写短之后的长话。
// 出处：迁移前的说明原文（MCPGuidePreviousCardsBatch2）、docs/architecture/ai-control-mcp.md 第四节第 54 条（整批先验、一次提交 / 撤销、
// 单项规则共用、错误报从 0 数的序号、异步准备后拒绝旧快照）、MCPBatchTools（条目的字段只在单项工具存一份）。只写英文。
// 不管什么：每个字段本身（读单项工具的主题 edit_clip / set_text / set_shape）、fields 几节（自动生成）。

enum MCPGuideBatchTopics {
    static let editClips = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.editClips,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.editClips, """
            edit_clips applies many edit_clip changes as one undo step.
            """),
            MCPGuideSection(name: "entries", about: "entries, their fields and their order", text: """
            Entries. clips is 1–100 entries in order; each takes the same fields as edit_clip (read topic=edit_clip for them) \
            with clip_id from get_timeline. Omitted fields stay; a clip id in several entries is edited again by each one. Ids \
            in examples are placeholders.
            """),
            MCPGuideSection(name: "checking", about: "checking everything first, errors, overlaps", text: """
            Checking. Every entry is checked before anything changes; if one fails, nothing is applied and the error names the \
            zero-based index of that entry. Overlaps are checked entry by entry, so move a clip out of the way in an earlier \
            entry first. One project per batch.
            """),
            MCPGuideSection(name: "results", about: "final states and the undo step", text: """
            Results. The whole batch is one undo step, and the result lists each clip's final state in order.
            """)
        ],
        examples: [
            ["clips": [["clip_id": "c1", "volume_db": -6], ["clip_id": "c2", "fit": "fill"]]]
        ],
        related: ["edit_clip", "get_timeline"]
    )

    static let setTexts = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.setTexts,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.setTexts, """
            set_texts applies many set_text changes as one undo step.
            """),
            MCPGuideSection(name: "entries", about: "entries, their fields, adding and order", text: """
            Entries. texts is 1–100 entries in order; each takes the same fields as set_text (topic=set_text) with text_id \
            from get_timeline, or no text_id to add a text. New texts start at the playhead as it was when the call began. \
            Omitted fields stay; a text_id in several entries is edited again by each one.
            """),
            MCPGuideSection(name: "checking", about: "checking everything first and errors", text: """
            Checking. Every entry is checked before anything changes; if one fails, nothing is applied and the error names the \
            zero-based index of that entry. One project per batch.
            """),
            MCPGuideSection(name: "results", about: "final states, the undo step, when to use it", text: """
            Results. The whole batch is one undo step, and the result lists each text's final state in order. Use it for \
            titles across a whole video instead of many set_text calls.
            """)
        ],
        examples: [
            ["texts": [["text_id": "t1", "text": "Day 1"], ["text": "Day 2", "start": 12]]]
        ],
        related: ["set_text", "get_timeline"]
    )

    static let setShapes = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.setShapes,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.setShapes, """
            set_shapes applies many set_shape changes as one undo step.
            """),
            MCPGuideSection(name: "entries", about: "entries, their fields, adding and order", text: """
            Entries. shapes is 1–100 entries in order; each takes the same fields as set_shape (topic=set_shape) with shape_id \
            from get_timeline, or no shape_id to add a shape. New shapes start at the playhead as it was when the call began. \
            Omitted fields stay; a shape_id in several entries is edited again by each one.
            """),
            MCPGuideSection(name: "checking", about: "checking everything first and errors", text: """
            Checking. Every entry is checked before anything changes; if one fails, nothing is applied and the error names the \
            zero-based index of that entry. One project per batch.
            """),
            MCPGuideSection(name: "results", about: "final states and the undo step", text: """
            Results. The whole batch is one undo step, and the result lists each shape's final state in order. Covering several \
            watermarks or subtitle bands from look text_scan in one call is a typical use.
            """)
        ],
        examples: [
            ["shapes": [["shape_id": "s1", "color": "#FFAA00"], ["kind": "blur", "x": 0.85, "y": 0.08, "width": 0.2, "height": 0.08]]]
        ],
        related: ["set_shape", "look"]
    )
}
