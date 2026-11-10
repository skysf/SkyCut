import Foundation

// MARK: - 说明书：add_voiceover 的主题（手写）
//
// 管什么：add_voiceover 名片写短之后的长话：声音从哪来、怎么认、模型和 voice_plan、花积分和确认、字幕的时间、失败了怎么恢复、
// 本机的声音、坑，外加几个最小的例子。登记在 MCPGuideWrittenTopics（和试点的五个同一张表、同一套守卫 GuidePilotChecks）；
// fields 几节不在这里写：MCPGuideTopics 从参数定义现算、接在最后。分节照声音方案 4.10。
// **概要不以迁移前的原文开头**（试点的规矩里唯一的例外，docs/architecture/mcp-guide.md 第 14 条）：这个工具的行为和迁移同一个 PR 改了
// （声音方案 4.2–4.4、第十二节：默认 gemini:Charon、去掉 clone_from、不再收不带前缀的 Rachel），旧说明照抄进来等于叫 AI 用已经没有的东西；
// 旧说明每一句去了哪写在那个 PR（#355）的说明里。
// 写的是**这一刀真有的**：声音库的声音（voice_…）、一次性费用（建 MiniMax 版）、list_voices / manage_voices / change_voice 是声音 PR 6 / 9 的事，
// 到时候再补进来（提到不存在的工具名、参数名守卫会红：GuidePilotChecks）。只写英文（MCP 按需说明方案第八节第 7 条）。
// 不管什么：名片（MCPMediaTools）、怎么答（MCPGuide）、挑哪个主题（MCPGuideTopics）。
// 方案：docs/plans/2026-11-09-voice-features.md 4.2–4.4、4.10、第七节、8.4；docs/plans/2026-11-09-mcp-guide.md 2.3、5.1。

enum MCPGuideVoiceTopics {
    static let addVoiceover = MCPGuideWrittenTopics.Written(
        previousCard: nil,
        sections: [overview, voices, modelsLanguages, paidConfirmation, subtitles, batchesRecovery, localVoices, pitfalls],
        examples: [
            ["lines": [["text": "Welcome to the course."], ["text": "First, open the project.", "start": 4]], "subtitles": true],
            ["lines": [["text": "This is the quiet part of the story."]], "voice": "en_female_warm", "model": "auto"],
            ["resume": "/path/to/Voiceover-1.recovery/voiceover-recovery.json", "generate_missing": true]
        ],
        related: ["paid", "sync_voiceover", "generate_subtitles", "get_job", "add_clips"]
    )

    // 出处：ai-control-mcp.md 第四节第 34、40 条；sky-studio-jobs.md 第五节；声音方案 4.2。
    static let overview = MCPGuideSection(name: MCPGuideSection.overview, text: """
    Narrate lines with a voice, put them on one audio track and optionally add subtitles timed to the voice. The whole \
    call is one undo step. Each line becomes one audio file in a SkyCut voiceover folder; the lines go on one track \
    (track, or a new audio track), each at its start or 0.3 s after the previous line, the first at the playhead.

    Two kinds of voices:
    - Sky Studio voices (cloud; the user's Sky Studio key): presets such as gemini:Charon, the default. Paid in credits. \
    The call quotes the whole script first and only then returns job_id; wait with get_job.
    - Local voices: SkyCut's own voices (after download_voices=true) and the voices installed on this Mac. Free; they \
    finish in the same call and return the result directly.
    """)

    // 出处：声音方案 4.3（认声音的顺序、本机退档）、第十二节（不再收不带前缀的 Eleven 旧名）；ai-control-mcp.md 第四节第 34、35 条。
    static let voices = MCPGuideSection(name: "voices", about: "who speaks: the default, roles, Sky Studio presets, Eleven voices, local voices, fallbacks", text: """
    voice says who speaks (case does not matter):
    - Not given: Sky Studio's default preset, gemini:Charon, a male narrator. Without Sky Studio the local voice of \
    zh_male or en_male reads Chinese or English text.
    - A role: zh_female_lively, zh_female_warm, zh_male, en_female_lively, en_female_warm, en_male, en_female_british or \
    en_male_british. Sky Studio maps each role to one of its presets; the result's voice.name says which. \
    en_male_british only reads English: for other text SkyCut uses that language's male role and says so in voice.note.
    - gemini:Name, or just the preset's name (Charon): a Sky Studio preset. A preset can sound different in another \
    language, and one that is not listed for the script's language still reads it, with a warning in voice.note.
    - eleven:Name: an Eleven v4 voice on Sky Studio.
    - A SkyCut voice name such as af_heart (after download_voices=true) or a voice installed on this Mac: used as named, \
    never Sky Studio.

    When Sky Studio cannot be used (no key, or it does not answer while quoting), the narration falls back to a local \
    voice at once, before anything is paid: a role keeps its own local voice, a preset uses the local role of the same \
    gender, and voice.note says why. Once a paid batch is sent there is no fallback.
    """)

    // 出处：声音方案 4.2（model）、4.4（选模型、跨语言提示）、8.4（整段一个模型、每批带回 selection）。
    static let modelsLanguages = MCPGuideSection(name: "models_languages", about: "model=auto and voice_plan, named models, one selection for the whole script", text: """
    model only matters for Sky Studio voices. auto (the default) lets Sky Studio choose: SkyCut sends the whole script \
    and the voice, and the quote answers with voice_plan: selection (the model and voice that read every batch), rule, \
    reason (one English sentence), languages (each language's share of the reading time), cross_language, warnings and \
    fallback. job_id comes back with voice_plan; tell the user what is in voice.note before they listen.

    A named model (a voice model from get_status models=true) reads every batch. A model that does not fit the voice or \
    the script's language is refused while quoting, with Sky Studio's own words, and nothing is paid.

    The whole script reads with one selection: every batch is sent with the same voice_plan selection. If one batch's \
    model fails, Sky Studio may finish that batch with the fallback; get_job reports each batch's model and \
    fallback_used.
    """)

    // 出处：sky-studio-jobs.md 第一节、第五节、第十一节（每日硬预算）；ai-control-mcp.md 第四节第 6、39、40 条；声音方案 4.2 第 2–5 步。
    static let paidConfirmation = MCPGuideSection(name: "paid_confirmation", about: "quotes, reservations, the daily credit limit, missing credits and confirm_token", text: """
    Sky Studio narration costs credits. Before job_id comes back, SkyCut quotes the whole script once (each batch's \
    price is the most it can cost) and reserves that much against the daily credit limit; each batch is settled at \
    what Sky Studio actually charged and the rest is returned.
    - Over the daily credit limit: nothing starts and the result says daily_budget_exceeded. Tell the user; switch to a \
    local voice only if they ask.
    - Not enough Sky Studio credits: the job fails with recharge_url; tell the user.
    - needs_confirmation from this tool asks to read a recovery file outside the opened folder (ask mode only): ask the \
    user, then repeat the same call with confirm_token.
    """)

    // 出处：ai-control-mcp.md 第四节第 34 条（字幕）、第 36 条（几行）；sky-studio-jobs.md 第五节（本机切句）；声音方案第七节。
    static let subtitles = MCPGuideSection(name: "subtitles", about: "subtitles=true, max_lines, and how word times are found", text: """
    subtitles=true adds the spoken words to the original subtitle track, timed to the voice. Lines that would overlap \
    existing subtitles are skipped (the result says how many), and nothing is added when that track is in another \
    language. max_lines is 1 (default) or 2 lines per subtitle and stays with the project.

    Timing: local voices and eleven-v4 report when each word is spoken. Gemini presets do not, so SkyCut transcribes the \
    finished audio on this Mac, which needs macOS 26 and this Mac's speech model for the script's language. Without it \
    the call is refused before anything is paid: run generate_subtitles once on any clip in that language to install \
    the model, call again with subtitles=false, or name model=eleven-v4.
    """)

    // 出处：sky-studio-jobs.md 第五节「2026-11-01：后续本地失败不否定已成功的生成」；声音方案 8.4（恢复只 GET 原单、补的批照原来的 selection）。
    static let batchesRecovery = MCPGuideSection(name: "batches_recovery", about: "batches, recovery_file, resume and generate_missing after a failure", text: """
    Sky Studio reads the script in batches. A cloud job keeps what it paid for in recovery_file: every batch's audio, \
    which line is in which batch, and Sky Studio's job ids. When get_job reports failed or cancelled:
    - Never call add_voiceover with the original lines again: that pays twice.
    - add_voiceover resume=<recovery_file> finishes from what exists: it fetches finished batches, splits and aligns them \
    on this Mac and inserts once. It never pays.
    - Add generate_missing=true to also pay for batches that were never generated. They are quoted again with the saved \
    voice_plan selection, so the voice and model stay the same.
    - A batch whose outcome is unknown is only looked up on Sky Studio, never sent again.
    - Reopen the original project first; resume refuses another project. It never inserts twice, not even after the \
    user undid the insertion.
    get_job lists completed_line_indices, not_generated_line_indices, unknown_batch_indices and the recovery arguments.
    """)

    // 出处：ai-control-mcp.md 第四节第 34、35 条（本机的声音、下载、语速）。
    static let localVoices = MCPGuideSection(name: "local_voices", about: "download_voices, languages and speed for local voices", text: """
    download_voices=true only downloads SkyCut's own voices (about 333 MB) and returns job_id; tell the user it is \
    downloading. They read Chinese, English, Japanese, Spanish, French, Italian, Portuguese and Hindi; other languages \
    use this Mac's voices. speed (0.5 to 2) works for local voices only. A Mac voice of basic quality comes with \
    voice.note on where to download a better one.
    """)

    // 出处：ai-control-mcp.md 第四节第 34 条（录好的声音走 add_clips、换了旁白之后 sync_voiceover）；声音方案第十二节（Rachel）、4.2（speed）；
    // sky-studio-jobs.md 第五节（失败后别重发原稿）。
    static let pitfalls = MCPGuideSection(name: "pitfalls", about: "recordings, sync_voiceover, Eleven names, speed and never paying twice", text: """
    Pitfalls. This tool speaks text: recordings and existing narration files go on the timeline with add_clips. To move \
    pictures to new narration, let this job finish, then use sync_voiceover. Bare old Eleven names such as Rachel are not \
    voices; write eleven:Name. speed only changes local voices; Sky Studio voices ignore it (voice.note says so). After a \
    failed or cancelled job never send the same lines again: that pays twice; use resume. Over the daily credit limit, \
    do not switch to a local voice unless the user asks.
    """)
}
