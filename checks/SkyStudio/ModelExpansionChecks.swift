import Foundation
import SrtFlowMCPKit

// 新模型生产目录快照的回归：能力不能在 MCP 投影丢失；实参和结算必须进入真实 HTTP 请求。
@MainActor
func runModelExpansionChecks() async {
    let url = URL(fileURLWithPath: "checks/SkyStudio/Fixtures/models-2026-10-31.json")
    guard let data = try? Data(contentsOf: url), let json = try? JSONValue.decode(data), let catalog = SkyStudioCatalog(json: json) else {
        check(false, "required backend model snapshot loads"); return
    }
    checkEqual(catalog.models.count, 7, "all seven new public model ids are discoverable")
    for model in catalog.models { checkEqual(model.json, json["models"]?.arrayValue?.first { $0["id"] == .string(model.id) }, "discovery preserves all metadata: \(model.id)") }
    check(catalog.billingPolicy != nil, "catalog settlement policy is preserved")
    func model(_ id: String) -> SkyStudioModel { catalog.models.first { $0.id == id }! }
    func file(_ type: String, role: String, seconds: Double? = nil) -> SkyStudioReference {
        SkyStudioReference(type: type, file: URL(fileURLWithPath: "/tmp/input.\(type == "image" ? "png" : type == "audio" ? "wav" : "webm")"), role: role,
            bytes: 1000, duration: seconds, width: type == "audio" ? nil : 640, height: type == "audio" ? nil : 640, fps: type == "video" ? 24 : nil,
            contentType: type == "image" ? "image/png" : type == "audio" ? "audio/wav" : "video/webm")
    }
    let voice = file("audio", role: "audio_url", seconds: 5)
    let video = file("video", role: "video_url", seconds: 5.007)
    let portrait = file("image", role: "image_url")
    let heygen = model("heygen-v3-lipsync-precision")
    let plan = SkyStudioReferencePlan(mode: "lipsync", files: [video, voice])
    check(plan.problem(model: heygen) == nil, "HeyGen accepts WebM and replacement WAV")
    var ask = SkyStudioGeneration.Ask()
    ask.controls = ["title": "Dialogue", "enable_caption": true, "enable_dynamic_duration": true, "disable_music_track": true,
                    "enable_speech_enhancement": true, "start_time": 0, "end_time": 4]
    check(SkyStudioGenerationControls.problem(model: heygen, ask: ask, prompt: "", references: plan) == nil, "all seven HeyGen controls validate")
    let generation = SkyStudioGeneration.make(.lipsync, prompt: "", ask: ask, canvas: 1, model: heygen, references: plan)
    checkEqual(generation.params["video_seconds"], .number(5.007), "quote uses actual video duration including fractional seconds")
    checkEqual(generation.params["audio_seconds"], 5, "quote uses measured replacement audio")
    for (field, value) in ask.controls { checkEqual(generation.params[field], value, "HeyGen forwards \(field)") }
    let defaultHeygen = SkyStudioGeneration.make(.lipsync, prompt: "", ask: .init(), canvas: 1, model: heygen, references: plan)
    checkEqual(defaultHeygen.params["enable_dynamic_duration"], false, "dynamic duration explicitly defaults false")
    var invalid = ask; invalid.controls["end_time"] = 6
    check(SkyStudioGenerationControls.problem(model: heygen, ask: invalid, prompt: "", references: plan) != nil, "processing range cannot exceed measured video")
    var large = video; large.bytes = 33_554_433
    check(SkyStudioReferencePlan(mode: "lipsync", files: [large, voice]).problem(model: heygen) != nil, "HeyGen 32 MiB is enforced before spending")
    check(SkyStudioReferencePlan(mode: "lipsync", files: [portrait, voice]).problem(model: heygen) != nil, "HeyGen requires video, cannot substitute a portrait")

    let h3 = model("minimax-h3-max-lip-sync")
    let h3Plan = SkyStudioReferencePlan(mode: "lipsync", files: [portrait, voice])
    check(h3Plan.problem(model: h3) == nil, "H3 Max takes image and audio")
    var short = voice; short.duration = 4.9
    check(SkyStudioReferencePlan(mode: "lipsync", files: [portrait, short]).problem(model: h3) != nil, "H3 minimum measured audio duration is enforced")
    var h3Ask = SkyStudioGeneration.Ask(resolution: "1080p")
    h3Ask.controls = ["seed": 2147483647, "enable_transcription": true, "enable_safety_checker": true]
    let h3Generation = SkyStudioGeneration.make(.lipsync, prompt: "", ask: h3Ask, canvas: 1, model: h3, references: h3Plan)
    checkEqual(h3Generation.params["resolution"], "1080P", "H3 resolution normalizes to actual catalog spelling")
    check(SkyStudioModelPolicy.problem(model: h3, ask: .init(resolution: "720p"), references: h3Plan) != nil, "H3 has no invented 720P tier")
    check(SkyStudioGenerationControls.problem(model: h3, ask: ask, prompt: "", references: h3Plan) != nil, "H3 rejects HeyGen-only parameters")
    let bg = model("ideogram-remove-background")
    var cutout = SkyStudioGeneration.Ask(); cutout.operation = "remove_background"
    let imagePlan = SkyStudioReferencePlan(mode: "images", files: [portrait])
    let cut = SkyStudioGeneration.make(.image, prompt: "", ask: cutout, canvas: 1, model: bg, references: imagePlan)
    checkEqual(cut.params, ["sync_mode": false, "enable_safety_checker": true], "cutout sends only its allowed booleans, never image generation hints")
    var bigImage = portrait; bigImage.bytes = 10_000_001
    check(SkyStudioReferencePlan(mode: "images", files: [bigImage]).problem(model: bg) != nil, "background removal uses decimal 10 MB")
    check(SkyStudioGenerationControls.problem(model: bg, ask: cutout, prompt: "generate a person", references: imagePlan) != nil, "cutout rejects text prompts")
    for id in ["wan-3.0-text-to-video", "wan-3.0-image-to-video", "wan-3.0-reference-to-video"] {
        checkEqual(model(id).choices("resolution"), ["480p", "720p", "1080p"], "Wan exposes all three resolutions: \(id)")
    }
    let wan = model("wan-3.0-reference-to-video")
    let audioOnly = SkyStudioReferencePlan(mode: "multimodal", files: [file("audio", role: "reference_audio", seconds: 2)])
    check(audioOnly.problem(model: wan) == nil, "Wan multimodal allows audio-only references")
    let auto = try? SkyStudioGenerationControls.ask(AIToolArguments(["duration": "auto", "enable_thinking": true]))
    checkEqual(auto?.smartDuration, true, "Wan smart duration parses auto")
    let smart = SkyStudioGeneration.make(.imageToVideo, prompt: "move", ask: auto!, canvas: 1, model: wan, inputMode: "multimodal", references: audioOnly)
    checkEqual(smart.params["duration"], .null, "Wan smart duration stays null on the wire")
    checkEqual(smart.params["mode"], "multimodal", "reference endpoint uses multimodal mode")
    check(smart.summary(modelTitle: wan.title).contains("auto"), "smart duration is never described as zero seconds")
    check(SkyStudioGenerationControls.problem(model: wan, ask: .init(duration: 2.4), prompt: "move", references: audioOnly) != nil, "Wan refuses fractional output seconds instead of silently rounding")
    let frameWan = model("wan-3.0-image-to-video")
    let shaped = SkyStudioGeneration.make(.imageToVideo, prompt: "move", ask: .init(aspectRatio: "9:16"), canvas: 1, frame: 1, model: frameWan)
    checkEqual(shaped.params["aspect_ratio"], "9:16", "Wan frame endpoint preserves its exposed aspect parameter")
    var transparent = portrait; transparent.hasTransparency = true
    check(SkyStudioReferencePlan(mode: "frames", files: [transparent]).problem(model: model("wan-3.0-image-to-video")) != nil, "Wan rejects actual input transparency")
    check(SkyStudioGenerationControls.problem(model: wan, ask: .init(), prompt: "move", references: .init(mode: "multimodal", files: [], webURL: "https://example.org")) == nil, "Wan supports webpage-only input")
    for value: JSONValue in ["auto", .null] {
        check((try? SkyStudioGenerationControls.ask(AIToolArguments(["duration": value])))?.smartDuration == true, "smart duration distinguishes omitted and explicit null")
    }

    let charged = SkyStudioBilling(["status": "charged", "credits_charged": 110, "credits_refunded": 22, "provider_outcome": "succeeded"])!
    let pending = SkyStudioBilling(["status": "pending_review", "credits_charged": .null, "review_required": true])!
    let partial = SkyStudioBilling(["status": "refunded", "credits_charged": 90, "credits_refunded": 18])!
    checkEqual(charged.netCharged, 110, "settlement uses server net charge, not reservation or video duration")
    check(!partial.returnedAll, "unused reservation return does not imply a free generation")
    var failure = SkyStudioJobFailure(message: "saving failed", fields: ["refunded": true]); failure.billing = charged
    check(!SkyStudioJobError.failed(failure).canRefund(beforeAccepted: true), "billing charge overrides a conflicting legacy refunded flag")
    failure.billing = pending
    check(!SkyStudioJobError.failed(failure).canRefund(beforeAccepted: false), "pending review cannot release reserved credits")
    let sidecar = SkyStudioJobResult(json: ["url": "https://example.org/result.webm", "content_type": "video/webm", "duration": 4.028,
        "billing_duration_seconds": 5, "caption_file": "https://example.org/captions.srt"])
    checkEqual(sidecar?.duration, 4.028, "timeline duration is distinct from billable seconds")
    checkEqual(sidecar?.captionFile?.pathExtension, "srt", "optional SRT sidecar is preserved")
    checkEqual(SkyStudioGeneration.fileExtension(contentType: "video/webm", url: sidecar!.url, kind: .lipsync), "webm", "WebM never gets an MP4 extension")

    let key = UUID().uuidString, identity: JSONValue = ["image": "portrait.png", "audio": "speech.wav"]
    check((try? SkyStudioGenerationRequests.begin(key, identity: identity)) == nil, "first request reserves its key")
    do { _ = try SkyStudioGenerationRequests.begin(key, identity: identity); check(false, "pending repeated request must not start a second job") } catch { check(true, "pending repeated request is refused without spending") }
    let response = AIToolResult.ok(["job_id": "generate-original"])
    SkyStudioGenerationRequests.complete(key, result: response)
    checkEqual(try? SkyStudioGenerationRequests.begin(key, identity: identity)?.payload, response.payload, "completed duplicate returns the original job without a new reservation")
    do { _ = try SkyStudioGenerationRequests.begin(key, identity: ["image": "other.png"]); check(false, "changed request must not reuse an identity") } catch { check(true, "changed request cannot reuse a paid identity") }
}
