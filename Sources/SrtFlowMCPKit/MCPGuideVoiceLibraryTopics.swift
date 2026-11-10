import Foundation

// MARK: - 说明书：list_voices、manage_voices 的主题（手写）
//
// 管什么：声音库两个工具名片之外的话：列出来的是什么、怎么用录音建声音和加一种语言、授权怎么问、设计花多少、改名和删除、两种权限模式、坑。
// 登记在 MCPGuideWrittenTopics（和别的迁移过的工具同一张表、同一套守卫 GuidePilotChecks）；两个都是新工具，没有迁移前的说明原文
// （previousCard 为 nil，名单写死在 GuidePilotChecks）。fields 几节由 MCPGuideTopics 从参数定义现算、接在最后。分节照声音方案 4.10。
// 写的是**这一刀真有的**：全部权限下的长期授权（不再问）是声音 PR 7，change_voice 是声音 PR 9，到时候再补进来。只写英文。
// 出处：docs/plans/2026-11-09-voice-features.md 4.5、4.6、4.7；docs/architecture/voice-library.md；Sky Studio 仓库 docs/agents/skycut-api.md
// 「Voice library」「Uploads and the SkyCut alignment」。
// 不管什么：名片（MCPVoiceLibraryTools）、配旁白（MCPGuideVoiceTopics）、怎么答（MCPGuide）。

enum MCPGuideVoiceLibraryTopics {
    // MARK: list_voices

    static let listVoices = MCPGuideWrittenTopics.Written(
        previousCard: nil,
        sections: [
            MCPGuideSection(name: MCPGuideSection.overview, text: """
            list_voices shows which voices add_voiceover can use: mine (the user's own Sky Studio voices) and the Sky Studio \
            presets for a language. It is free and changes nothing. Call it before naming a voice the user described ("my \
            voice", "a calm female narrator"), and pass the script's language: a preset's gender and description belong to one \
            language, and the same preset can sound like another person in another language. Local voices (SkyCut's own and this \
            Mac's) are not listed here; roles (en_male, zh_female_warm…) are in the add_voiceover topic.
            """),
            MCPGuideSection(name: "mine", about: "the user's voices: voice_… ids, names, languages and their MiniMax versions", text: """
            mine lists the user's voice library, at most 50 voices: id (voice_ followed by 32 hex digits; pass it as \
            add_voiceover voice), name, source (recording or design), and languages: each language the voice has a reference \
            for, the kind of reference and whether its MiniMax version exists (minimax). A voice reads every language, but it \
            sounds most like itself in a language it has a reference for; another language reads cross-language and \
            add_voiceover says so in voice.note.
            """),
            MCPGuideSection(name: "presets", about: "Sky Studio presets per language, the default, and languages without their own list", text: """
            presets lists the Sky Studio voices for one language, best rated first: id (gemini:Name), gender, description and \
            default (gemini:Charon is the default narrator). A language without its own list returns the English one. Without \
            language, both the Chinese and the English lists come back. Pick by the description in the script's language; any \
            preset can still read any language, with a warning in voice.note when it is not listed for it.
            """),
            MCPGuideSection(name: "pitfalls", about: "invented ids, an unavailable voice library, prices", text: """
            Pitfalls. Never invent a voice_… id: use one from mine. When Sky Studio's voice library is unavailable, mine says so \
            (voice_library_unavailable) and presets still come back: narrate with a preset or try the library later. The list \
            has no prices; add_voiceover quotes before it spends anything.
            """)
        ],
        examples: [
            ["language": "en"],
            ["include": "mine"]
        ],
        related: ["add_voiceover", "manage_voices"]
    )

    // MARK: manage_voices

    static let manageVoices = MCPGuideWrittenTopics.Written(
        previousCard: nil,
        sections: [
            MCPGuideSection(name: MCPGuideSection.overview, text: """
            manage_voices changes the user's Sky Studio voice library: create a voice from a recording (cloning the user's own \
            voice), add_reference for another language, design a voice from a description, rename and delete. It never touches \
            the timeline and has no undo: deleting a voice cannot be reversed. Use the new voice_… id with add_voiceover voice.
            """),
            MCPGuideSection(name: "create", about: "create and add_reference: the recording, language, consent and confirm_token", text: """
            create needs file (an audio or video file with one person speaking, no music), name and language (the ISO 639-1 \
            code of what is said). add_reference adds a recording in another language to voice: one reference per language; a \
            language that has one is reference_exists (delete and create again to replace it). SkyCut uses at most 3 minutes: \
            start and end pick the part, and a longer file is trimmed to the 3 minutes with the most speech; the result says \
            which part. It needs at least 10 seconds of clear speech (too_little_speech otherwise). Free. Every recording first \
            returns needs_confirmation with Sky Studio's consent statement: the user must confirm it is their own voice or that \
            the speaker agreed; translate the statement for the user, then repeat the same call with confirm_token. Files \
            outside the opened folder also ask before reading. 50 voices per account (voice_limit).
            """),
            MCPGuideSection(name: "design", about: "design from a description: the one-time fee, the job and its sample_url", text: """
            design creates a new voice from description (how it sounds; a Chinese description designs on MiniMax, any other \
            language on Qwen3), name and optional sample_text (the sentence its sample reads). It is a one-time fee in Sky Studio \
            credits, and the MiniMax design costs far more than Qwen3 (get_status models=true lists typical prices); the exact \
            price is quoted first and returned with needs_confirmation. After the user agrees, repeat with confirm_token: it \
            returns job_id (kind voice_design); wait with \
            get_job, which reports the new voice and a sample_url to listen to (valid one hour). The daily credit limit always \
            applies; a design that fails is refunded.
            """),
            MCPGuideSection(name: "rename_delete", about: "rename, and delete for good (sent again after a storage failure)", text: """
            rename gives voice a new name (1 to 80 characters), free and immediate. delete removes voice and all of its \
            recordings at once and for good; tell the user it cannot be restored. A narration already running with it may \
            finish. If Sky Studio's storage is briefly unavailable, SkyCut sends the deletion again; if that fails too, the voice \
            is already hidden and calling delete again finishes it.
            """),
            MCPGuideSection(name: "permission_modes", about: "what ask mode and full access mode ask, and what a token is bound to", text: """
            In ask mode: create and add_reference ask for consent for every recording, design asks before its one-time fee, and \
            delete asks once. In full access mode delete happens directly and the result says so; recordings and design still \
            return needs_confirmation, because this version has no standing consent or price notice for full access yet. A token is \
            bound to the exact request: another file, part, language, name, description or price gets a new question. Tokens \
            last 30 minutes and work once.
            """),
            MCPGuideSection(name: "pitfalls", about: "consent from the speaker, one voice per person, an unavailable voice library", text: """
            Pitfalls. Never call create on a recording of someone who did not agree. Do not pass the same recording again to \
            make a second voice; use add_reference for a new language instead. voice_library_unavailable means Sky Studio's \
            voice library is not available right now: nothing was charged; try later, and narrate with a preset meanwhile.
            """)
        ],
        examples: [
            ["action": "create", "file": "my-voice.m4a", "name": "Sky", "language": "zh"],
            ["action": "design", "description": "A calm, warm male narrator in his forties", "name": "Calm narrator"],
            ["action": "delete", "voice": "voice_9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d"]
        ],
        related: ["list_voices", "add_voiceover", "paid", "get_job"]
    )
}
