import Foundation
import SrtFlowMCPKit

// 动态模型默认值、完整参考限制、真人拒绝的退款证据。只跑纯值，不读用户文件，不调用真实服务。
func runModelPolicyChecks() {
    let imageCaps: JSONValue = ["max_images": 14, "max_audio": 0, "max_videos": 0, "max_total_files": 14]
    let h3Caps: JSONValue = ["max_images": 9, "max_videos": 3, "max_audio": 3, "max_total_files": 12,
        "audio_requires_visual": true, "max_total_video_seconds": 15, "max_total_audio_seconds": 15,
        "max_total_video_bytes_exclusive": 52_428_800, "max_audio_bytes": 15_728_640,
        "min_video_clip_seconds": 2, "max_video_clip_seconds": 15, "resolution": ["480p", "768p", "2K", "4K"]]
    let omniCaps: JSONValue = ["max_images": 10, "max_videos": 3, "max_audio": 0, "max_total_files": 13,
        "max_video_clip_seconds": 10, "duration_tolerance_seconds": 0.1, "max_total_bytes": 62_914_560]
    let s25Caps: JSONValue = ["max_images": 30, "max_videos": 10, "max_audio": 10, "max_total_files": 50,
        "max_total_video_seconds": 30.2, "max_total_audio_seconds": 30.2]
    func video(_ id: String, resolution: String, seconds: Int = 5, caps: JSONValue? = nil) -> SkyStudioModel {
        var modes: [String: JSONValue] = ["frames": ["max_images": 2, "max_audio": 0, "max_videos": 0, "resolution": [.string(resolution)]]]
        if let caps { modes["multimodal"] = caps }
        return SkyStudioModel(id: id, kind: "image_to_video", title: id,
            params: ["duration_values": .array((id == "veo-pro" ? [8] : Array(3...15)).map { .number(Double($0)) }),
                     "resolution": [.string(resolution)], "aspect_ratio": ["16:9", "9:16"], "mode": ["frames", "multimodal"]],
            defaults: ["duration": .number(Double(seconds)), "resolution": .string(resolution)], inputs: ["modes": .object(modes)])
    }
    let seedream = SkyStudioModel(id: "seedream5-flash", kind: "image", title: "Seedream", params: ["resolution": ["2K"], "aspect_ratio": ["16:9", "9:16"]],
        limits: ["references": imageCaps], defaults: ["resolution": "2K"])
    let nano = SkyStudioModel(id: "nano2", kind: "image", title: "Nano", params: ["resolution": ["1K", "2K", "4K"], "aspect_ratio": ["16:9", "4:1", "1:4"]],
        limits: ["references": imageCaps], defaults: ["resolution": "2K"])
    let h3 = video("minimax-h3", resolution: "768p", caps: h3Caps)
    let omni = video("gemini-omni-1.1-flash", resolution: "720p", caps: omniCaps)
    let s25 = video("seedance-2-5", resolution: "720p", caps: s25Caps)
    let veo = video("veo-pro", resolution: "1080p", seconds: 8)
    let catalog = SkyStudioCatalog(models: [seedream, nano, veo, s25, omni, h3])
    checkEqual(SkyStudioModelPolicy.select(catalog: catalog, kind: "image", requested: nil)?.id, "nano2", "mixed/unclear images default to Nano 2, independently of catalog order")
    checkEqual(SkyStudioModelPolicy.select(catalog: catalog, kind: "image", requested: nil, imageContext: "asian")?.id, "seedream5-flash", "Asian subjects prefer Seedream Flash")
    checkEqual(SkyStudioModelPolicy.select(catalog: catalog, kind: "image_to_video", requested: nil)?.id, "minimax-h3", "ordinary video prefers H3")
    checkEqual(SkyStudioModelPolicy.select(catalog: catalog, kind: "image_to_video", requested: nil, quality: "highest")?.id, "seedance-2-5", "explicit unconstrained quality prefers Seedance 2.5")
    checkEqual(SkyStudioModelPolicy.select(catalog: catalog, kind: "image_to_video", requested: "veo-pro")?.id, "veo-pro", "a named model overrides the preference")

    let noReferences = SkyStudioReferencePlan(mode: "frames", files: [])
    let veoGeneration = SkyStudioGeneration.make(.imageToVideo, prompt: "x", ask: .init(), canvas: 16 / 9, model: veo)
    checkEqual(veoGeneration.params["duration"], 8, "Veo reads 8 seconds from server defaults")
    checkEqual(veoGeneration.params["resolution"], "1080p", "Veo does not inherit H3's 768p")
    let nanoGeneration = SkyStudioGeneration.make(.image, prompt: "x", ask: .init(resolution: "4K"), canvas: 4, model: nano)
    checkEqual(nanoGeneration.params["aspect_ratio"], "4:1", "new server image ratios are used without a static enum")
    checkEqual(nanoGeneration.params["resolution"], "4K", "image output resolution is sent")
    check(SkyStudioModelPolicy.problem(model: veo, ask: .init(duration: 5), references: noReferences) != nil, "an incompatible explicit duration is reported")

    func file(_ type: String, _ number: Int = 1, bytes: Double = 1000, seconds: Double? = nil) -> SkyStudioReference {
        SkyStudioReference(type: type, file: URL(fileURLWithPath: "/tmp/\(type)-\(number)"), role: "reference_\(type)", bytes: bytes, duration: seconds)
    }
    let plan = SkyStudioReferencePlan(mode: "multimodal", files: [file("image"), file("video", seconds: 3), file("audio", seconds: 2)])
    check(plan.problem(model: h3) == nil, "H3 accepts the complete image/video/audio set")
    checkEqual(plan.quoteParams["reference_video_seconds"], 3, "quote uses measured video input seconds")
    checkEqual(plan.quoteParams["reference_image_count"], 1, "quote uses actual image count")
    check(plan.problem(model: omni) != nil, "Omni cannot silently drop the audio reference")
    let audioOnly = SkyStudioReferencePlan(mode: "multimodal", files: [file("audio", seconds: 3)])
    check(audioOnly.problem(model: h3) != nil && audioOnly.problem(model: s25) == nil, "audio-only eligibility differs by model")
    let thirteen = SkyStudioReferencePlan(mode: "multimodal", files: (1...9).map { file("image", $0) } + (1...3).map { file("video", $0, seconds: 2) } + [file("audio", seconds: 2)])
    check(thirteen.problem(model: h3) != nil, "independent type ceilings do not override the 12-file total")
    let tooLong = SkyStudioReferencePlan(mode: "multimodal", files: [file("video", seconds: 16)])
    check(tooLong.problem(model: h3) != nil, "overlong references are refused before upload")
    let fiftyMB = SkyStudioReferencePlan(mode: "multimodal", files: [file("video", bytes: 52_428_800, seconds: 3)])
    check(fiftyMB.problem(model: h3) != nil, "H3's combined 50 MB video limit is exclusive")
    let slop = SkyStudioReferencePlan(mode: "multimodal", files: [file("video", seconds: 10.006)])
    check(slop.problem(model: omni) == nil, "Omni's own container-duration slop is accepted")
    let roundTrip = SkyStudioModel(json: h3.json)
    checkEqual(roundTrip?.json, h3.json, "discovery preserves server defaults, input modes and limits")

    let original = SkyStudioGeneration.make(.imageToVideo, prompt: "keep all references", ask: .init(duration: 5, resolution: "720p"), canvas: 16 / 9, model: s25,
        inputMode: "multimodal", references: plan)
    let unknown = SkyStudioJobFailure(message: "real person; refunded", fields: ["provider_code": "REAL_PERSON_REFERENCE"])
    check(!SkyStudioJobError.failed(unknown).canRefund(beforeAccepted: false), "unknown refund keeps the local reservation")
    check(!SkyStudioJobError.request(.network("timeout")).canRefund(beforeAccepted: true), "unknown submission outcome never proves no charge")
    let ordered: [JSONValue] = [["type": "image", "url": "https://example.test/1"], ["type": "video", "url": "https://example.test/2"]]
    let request = original.job(model: "seedance-2-5", maxCredits: 100, uploaded: ["last_frame_url": "https://example.test/end"], references: ordered)
    checkEqual(request.jobBody["inputs"]?["references"], .array(ordered), "ordered reference URLs cross the actual request boundary")
    check(request.quoteBody["inputs"] == nil, "quote uses measured parameters without uploading first")
    check(SkyStudioApproval.identity(job: request, credits: 100) != SkyStudioApproval.identity(job: original.job(model: "seedance-2-5"), credits: 100), "approval identity binds reference order and URLs")
}
