import Foundation

// MARK: - How AI places and changes a web-motion clip
// Sources: web-motion-renderer.md (page contract and six checks), motion-presets.md (one library, native first),
// ai-control-mcp.md (approval modes, jobs, one undo step). No renderer or persistence implementation belongs here.

enum MCPGuideMotionTopic {
    static let written = MCPGuideWrittenTopics.Written(
        previousCard: nil,
        sections: [
            MCPGuideSection(name: "overview", text: """
            set_motion places a reusable web page, rendered on this Mac into a premultiplied ProRes 4444 movie, on an upper \
            video track. One successful call is one undo step. Native motions still use set_text motion_preset: try those \
            first, then a ready-made web template, and write a page only when neither fits. get_timeline returns motion_library \
            in that order; native and web entries belong to the same motion-preset library.

            No external browser, download, server, paid model or network is used. A result may include job_id: wait with \
            get_job; do not submit the same page again merely because rendering is slow.
            """),
            MCPGuideSection(name: "placing", about: "template or page, parameters, timing, upper tracks, changing the same clip", text: """
            Choose template from get_timeline's web entries (a project: id reuses a page already stored in this project), or \
            supply page HTML as the fallback. parameters is a JSON object exposed to the page as frozen MOTION_PARAMS. \
            Pass fields to describe its editable form: key, label and type (text, font, color or number), with optional \
            minimum and maximum for numbers. fonts lists fixed installed font dependencies used directly by the page; \
            editable font choices belong in font-type fields and their parameter values. Font controls only offer fonts \
            available on this Mac. name labels the reusable project page.

            at is the timeline start; hit_at instead places the page's local hit second at that timeline second, so start \
            is hit_at minus hit. Never pass both. duration is the full page length (at most 60 seconds); hit must be inside \
            it and the calculated start cannot be negative. track is V2 or above, or new_video; never V1 or audio. An \
            overlap lifts the new clip to a free upper track.

            With clip_id, omitted values stay. parameters merges its top-level keys into the stored values, and the same \
            clip id stays through the new render. Nothing changes until all checks pass; failure leaves the old clip and \
            its movie intact. A deleted clip or a project edited while rendering is never overwritten by an old result.
            """),
            MCPGuideSection(name: "page_contract", about: "frame entry, parameters, page time, resources, deterministic drawing and the network lock", text: """
            Define window.motion = { frame(t), duration, ready }. frame(t) draws the picture at t seconds; it may return a \
            promise. Optional ready is a promise awaited once for fonts or image decoding; it must not wait on timers. \
            Use window.MOTION_PARAMS for parameters and window.MOTION_RENDER for the CSS viewport, output size, fps and \
            duration. The default viewport is 1080 CSS pixels high; its width follows the canvas aspect ratio. Text uses \
            this Mac's fonts. Declare those names in fonts (and font-type fields).

            Make every frame a pure function of t. Math.random and crypto are seeded for that time; page time, timers, \
            CSS animations, Web Animations and SVG animations use render time. Several page instances draw out of order; \
            never accumulate motion from the previous frame. Use installed fonts and embedded data or blob images. \
            The page receives duration and hit in MOTION_PARAMS from the record; parameter values cannot override them. \
            There are no web fonts, external files, network, workers, frames, eval, navigation, popups, media permissions or \
            lasting storage. These locks are never relaxed, including in full access mode. An unavailable lock refuses \
            the render. The page runs only in the separate locked renderer helper.
            """),
            MCPGuideSection(name: "approval", about: "new page code, confirm_token, request approval and full access", text: """
            New or changed AI-written page code follows the permission mode. Request approval returns needs_confirmation \
            once before rendering: relay its question in the user's language and, only after agreement, repeat that exact \
            call with confirm_token. The token is bound to the request; changing the page or parameters needs a new \
            approval. Full access proceeds without asking. An already approved stored page, including a parameter-only \
            re-render, does not ask again. Approval never unlocks network or relaxes rendering limits.
            """),
            MCPGuideSection(name: "results", about: "page checks, verbatim errors, render time, look times and portable caches", text: """
            The accepted result identifies the clip and reports render_seconds, checks, and look_times: inspect those \
            timeline moments with look before calling it finished. The six checks are loads, frame_entry, same_twice, \
            no_blank_frames, no_page_errors and no_timeout. A failed page returns its own error verbatim with the check \
            results; fix that error, not the network lock. Same-time frames must match across instances, and a one- or \
            two-frame empty gap between drawn frames is refused.

            The project stores page and parameters; the movie is a cache next to it under SkyCut/Motion. Its name includes \
            the page, parameters, render settings, renderer and system fingerprint. If the cache is missing SkyCut can \
            re-render it. A carried movie remains in use on another Mac until a parameter changes; different system or \
            missing fonts produce a warning because text pixels may change. Preview and export use the same movie.
            """)
        ],
        examples: [
            ["template": "project:11111111-2222-3333-4444-555555555555", "parameters": ["text": "EXPEDITION"],
             "hit_at": 58.79, "hit": 1.2, "duration": 4],
            ["clip_id": "c1", "parameters": ["text": "TO THE POLE"]]
        ],
        related: ["set_text", "get_timeline", "get_job", "look", "rules"],
        readingTip: "For a stored template or a parameter change, read only section=placing; for a new page, also read section=page_contract."
    )
}
