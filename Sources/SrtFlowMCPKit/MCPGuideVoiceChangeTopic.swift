import Foundation

// MARK: - 说明书：change_voice 的主题（手写）
//
// 管什么：变声名片之外的话：挑哪个声音、一次多长、花多少怎么问、做完时间线上是什么样、用哪种语言的录音、工程变了怎么办、坑。
// 登记在 MCPGuideWrittenTopics（和别的迁移过的工具同一张表、同一套守卫 GuidePilotChecks）；新工具，没有迁移前的说明原文
// （previousCard 为 nil，名单写死在 GuidePilotChecks）。fields 由 MCPGuideTopics 从参数定义现算、接在最后。只写英文。
// 价、一次最长多少秒都不写数（只在 Sky Studio 的 /models、/quote；现在是 5 分钟，写「get_status models=true 列着」）。
// 出处：docs/plans/2026-11-09-voice-features.md 4.8、4.9；docs/architecture/voice-library.md 第十节；Sky Studio 仓库
// docs/agents/skycut-api.md「voice_convert」。
// 不管什么：名片（MCPVoiceChangeTool）、声音库（MCPGuideVoiceLibraryTopics）、配旁白（MCPGuideVoiceTopics）、怎么答（MCPGuide）。

enum MCPGuideVoiceChangeTopic {
    static let changeVoice = MCPGuideWrittenTopics.Written(
        previousCard: nil,
        sections: [
            MCPGuideSection(name: MCPGuideSection.overview, text: """
            change_voice replaces the voice in one clip with another voice and keeps everything else the clip sounded like: Sky \
            Studio separates the speech from the background, re-voices the speech with the target voice at the same timing, and \
            returns two files. Use it to dub a clip in the user's own voice, or to give a speaker another voice. It works on a \
            video or audio clip that has sound and is not muted. It is paid and runs as a job; nothing on the timeline changes \
            until the job is done.

            Which voice. Prefer the user's own voice: a voice_… id from list_voices mine (create one with manage_voices if there \
            is none). A preset (gemini:Name) also works as the target, but that is untested: a preset's sample is only a few \
            seconds long, so the result may not sound like it. Say so before the user pays for it.
            """),
            MCPGuideSection(name: "cost_and_limits", about: "the quote, the daily credit limit, the longest clip, almost silent clips", text: """
            Cost. SkyCut quotes the clip's source seconds first and returns credits (the most it can cost) with job_id; tell \
            the user the price. It never returns needs_confirmation: the only gate is the daily credit limit, in every \
            permission mode. Over it, the result is status blocked with daily_budget_exceeded and nothing starts. The charge is \
            settled when the job ends (credits_charged); a job that fails is refunded by Sky Studio.

            Limits. One call changes one clip, and a clip can use only so many seconds of its source (the voice_convert limit in \
            get_status models=true). A longer clip is refused before anything is charged: split it with split_clip and change \
            each part. An almost silent clip is refused too. A clip that is already being changed is refused until that job ends.
            """),
            MCPGuideSection(name: "result", about: "what the timeline looks like when the job is done, undo, the two files, a project that changed", text: """
            When the job is done (get_job): the original clip is muted, not deleted; two new audio tracks hold the changed voice \
            (voice_clip_id) and the separated background (background_clip_id) at the clip's place, with the clip's speed, \
            volume, fades and volume curve. The three clips share one link group, so with linkage on they move, trim and delete \
            together. All of it is one undo step: one undo brings the original sound back. The user can turn the background \
            down on its own track. model and fallback_used say which model ran.

            The two files (voice_file, background_file) are saved next to the clip's source file and never replace a file. If \
            the clip was moved or shortened while the job ran, the result lands on the clip as it is now. If the clip was \
            deleted, got another source file, was trimmed outwards, or its project was closed, the files are kept and nothing on \
            the timeline changes (landed is false): add them with add_clips and mute the clip yourself.
            """),
            MCPGuideSection(name: "language", about: "language, and which of the target voice's recordings Sky Studio uses", text: """
            language is the ISO 639-1 code of what the clip says. A library voice can hold one recording per language, and the \
            change sounds most like the voice when Sky Studio works from the recording in the clip's own language. SkyCut asks \
            for that recording (target_language in the result) only when it knows the clip's language and the voice has a \
            recording in it. Pass language when you know it (from the script, transcribe or the user); without it SkyCut tries \
            to detect it on this Mac, and if it cannot, Sky Studio picks a recording itself (Chinese first). note in the result \
            says when another language's recording is used; relay it.
            """),
            MCPGuideSection(name: "pitfalls", about: "sending the same change twice, music under speech, subtitles, an unavailable voice library", text: """
            Pitfalls. Never call change_voice again for the same clip because a job seems slow or its result is unknown: check \
            get_job first; a second job is a second charge. The background keeps music and noise but is mono. Existing \
            subtitles stay as they are (the words and timing do not change). To change the voice of narration that add_voiceover \
            made, narrate again with another voice instead. voice_library_unavailable means Sky Studio's voice storage is not \
            available right now: nothing was charged; try later.
            """)
        ],
        examples: [
            ["clip_id": "c1", "voice": "voice_9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d"],
            ["clip_id": "c1", "voice": "voice_9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d", "language": "en"]
        ],
        related: ["list_voices", "manage_voices", "split_clip", "paid", "get_job"]
    )
}
