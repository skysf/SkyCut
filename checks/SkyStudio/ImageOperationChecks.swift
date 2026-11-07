import Foundation
import SrtFlowMCPKit

// 图片目录与两种媒体操作：真实生产编码 / 校验经假 HTTP 协议，不访问在线服务或钱包。
func imageModelCatalog() -> SkyStudioCatalog? {
    let file = URL(fileURLWithPath: "checks/SkyStudio/Fixtures/models-image-2026-11-07.json")
    guard let data = try? Data(contentsOf: file), let json = try? JSONValue.decode(data) else { return nil }
    return SkyStudioCatalog(json: json)
}

func imageInputPlan() -> SkyStudioReferencePlan {
    .init(mode: "images", files: [.init(type: "image", file: URL(fileURLWithPath: "/tmp/source.png"), role: "image_url",
        bytes: 1000, width: 640, height: 480, contentType: "image/png")])
}

func imageOperationAsk(_ operation: String, _ extra: [String: JSONValue] = [:]) throws -> SkyStudioGeneration.Ask {
    try SkyStudioGenerationControls.ask(AIToolArguments(.object(extra.merging(["kind": "image", "operation": .string(operation)]) { _, new in new })))
}

@MainActor
func runImageOperationChecks() async {
    guard let catalog = imageModelCatalog() else { check(false, "required final image catalog fixture loads"); return }
    checkEqual(catalog.models.count, 9, "nine actual image catalog records are available")
    checkImageCatalog(catalog)
    checkImageControls(catalog)
    await checkImageRequests(catalog)
    await checkOrdinaryImageRequests(catalog)
    await checkImageErrors(catalog)
}

private func checkImageCatalog(_ catalog: SkyStudioCatalog) {
    let plan = imageInputPlan()
    for id in ["nano2-lite", "nano-banana-pro", "gpt-image-2", "seedream5-pro", "seedream5-flash", "nano2"] {
        guard let model = catalog.model(id, kind: "image") else { check(false, "model \(id) exists"); continue }
        let ask = SkyStudioGeneration.Ask()
        checkEqual(SkyStudioModelPolicy.select(catalog: catalog, kind: "image", requested: id)?.id, id, "explicit model: \(id)")
        checkEqual(model.json["billing_policy"]?["version"], "2026-10-31", "billing policy is retained: \(id)")
        check(model.price["credits_with_references_by_resolution"] != nil, "reference display prices survive discovery: \(id)")
        for ratio in model.choices("aspect_ratio") {
            var asked = ask; asked.aspectRatio = ratio
            check(SkyStudioGenerationControls.problem(model: model, ask: asked, prompt: "Interior", references: plan) == nil, "catalog shape accepted: \(id) \(ratio)")
            checkEqual(SkyStudioGeneration.make(.image, prompt: "Interior", ask: asked, canvas: 1, model: model, references: plan).params["aspect_ratio"], .string(ratio), "catalog shape encoded: \(id) \(ratio)")
        }
        for tier in model.choices("resolution") {
            var asked = ask; asked.resolution = tier
            check(SkyStudioModelPolicy.problem(model: model, ask: asked, references: plan) == nil, "catalog tier accepted: \(id) \(tier)")
        }
        var tooMany = plan
        let max = model.referenceLimits(mode: "images")?["max_images"]?.intValue ?? 0
        tooMany.files = Array(repeating: plan.files[0], count: max + 1)
        check(tooMany.problem(model: model) != nil, "catalog reference cap enforced: \(id)")
        let generation = SkyStudioGeneration.make(.image, prompt: "Interior", ask: ask, canvas: 16 / 9, model: model, references: plan)
        checkEqual(generation.params["resolution"], .string(model.choices("resolution")[0]), "default image tier from catalog: \(id)")
        check(generation.job(model: id).quoteBody["operation"] == nil, "ordinary generate omits operation: \(id)")
    }
    let nano = catalog.model("nano2", kind: "image")!
    for ratio in ["1:4", "1:8"] {
        check(SkyStudioGenerationControls.problem(model: nano, ask: .init(aspectRatio: ratio), prompt: "Interior", references: plan) != nil, "Nano 2 retired ratio refused: \(ratio)")
    }
    let reversed = SkyStudioCatalog(models: catalog.models.reversed())
    let compatible: (SkyStudioModel) -> Bool = { $0.operation == "generate" }
    checkEqual(SkyStudioModelPolicy.select(catalog: reversed, kind: "image", requested: nil, imageContext: "asian", accepts: compatible)?.id, "seedream5-flash", "Asian default order unchanged")
    checkEqual(SkyStudioModelPolicy.select(catalog: reversed, kind: "image", requested: nil, accepts: compatible)?.id, "nano2", "other default order unchanged")
    for id in ["pro", "nano-banana", "seedream5-lite", "dreamina"] {
        check(SkyStudioModelPolicy.select(catalog: catalog, kind: "image", requested: id) == nil, "retired/private id not offered: \(id)")
    }
}

private func checkImageControls(_ catalog: SkyStudioCatalog) {
    let plan = imageInputPlan(), camera = catalog.model("qwen-angles", kind: "image")!, upscale = catalog.model("image-upscale", kind: "image")!
    let properties = MCPToolName.generateMedia.definition.inputSchema["properties"]
    checkEqual(properties?["operation"]?["enum"]?.arrayValue?.compactMap(\.stringValue), SkyStudioImageOperation.names, "operation schema matches parser")
    for (axis, stops) in [("rotate", SkyStudioCameraAngle.rotations), ("tilt", SkyStudioCameraAngle.tilts), ("zoom", SkyStudioCameraAngle.zooms)] {
        checkEqual(properties?["camera_angle"]?["properties"]?[axis]?["enum"]?.arrayValue?.compactMap(\.intValue), stops, "axis schema matches parser: \(axis)")
    }
    for rotate in SkyStudioCameraAngle.rotations {
        for tilt in SkyStudioCameraAngle.tilts {
            for zoom in SkyStudioCameraAngle.zooms where rotate != 0 || tilt != 0 || zoom != 0 {
                let ask = try? imageOperationAsk("camera_angle", ["camera_angle": ["rotate": .number(Double(rotate)), "tilt": .number(Double(tilt)), "zoom": .number(Double(zoom))]])
                check(ask.map { SkyStudioGenerationControls.problem(model: camera, ask: $0, prompt: "", references: plan) == nil } == true, "published camera move validates: \(rotate)/\(tilt)/\(zoom)")
            }
        }
    }
    for extra: [String: JSONValue] in [["camera_angle": [:]], ["camera_angle": ["rotate": 22]], ["camera_angle": ["rotate": 45.5]],
        ["camera_angle": ["tilt": 90]], ["camera_angle": ["zoom": 3]], ["camera_angle": []], ["camera_angle": ["rotate": 45, "pan": 0]]] {
        check((try? imageOperationAsk("camera_angle", extra)) == nil, "bad/zero camera request refused: \(extra)")
    }
    for value in ["x1", "x5", "2"] { check((try? imageOperationAsk("upscale", ["upscale_factor": .string(value)])) == nil, "bad upscale factor refused: \(value)") }
    for (model, operation, extra) in [(camera, "camera_angle", ["camera_angle": ["rotate": 135]] as [String: JSONValue]), (upscale, "upscale", [:])] {
        guard let ask = try? imageOperationAsk(operation, extra) else { check(false, "valid image ask parses"); continue }
        let accepts: (SkyStudioModel) -> Bool = { SkyStudioModelPolicy.problem(model: $0, ask: ask, references: plan) == nil && SkyStudioGenerationControls.problem(model: $0, ask: ask, prompt: "", references: plan) == nil }
        checkEqual(SkyStudioModelPolicy.select(catalog: catalog, kind: "image", requested: nil, accepts: accepts)?.id, model.id, "operation selects matching catalog model")
        for files in [[], [plan.files[0], plan.files[0]]] as [[SkyStudioReference]] {
            check(SkyStudioGenerationControls.problem(model: model, ask: ask, prompt: "", references: .init(mode: "images", files: files)) != nil, "operation requires exactly one image: \(operation)")
        }
        for prompt in ["Describe", " "] { check(SkyStudioGenerationControls.problem(model: model, ask: ask, prompt: prompt, references: plan) != nil, "no prompt allowed: \(operation)") }
        var reference = plan; reference.files[0].role = "reference_image"
        check(SkyStudioGenerationControls.problem(model: model, ask: ask, prompt: "", references: reference) == nil, "one reference image is allowed: \(operation)")
        var oversized = plan; oversized.files[0].bytes = 30 * 1024 * 1024 + 1
        check(oversized.problem(model: model) != nil, "30 MiB catalog cap: \(operation)")
        var badMIME = plan; badMIME.files[0].contentType = "image/tiff"
        check(badMIME.problem(model: model) != nil, "catalog input MIME: \(operation)")
        for field in ["duration", "instrumental", "generate_audio", "lyrics"] {
            let value: JSONValue = field == "duration" ? 5 : field == "lyrics" ? "Words" : true
            let invalid = try? imageOperationAsk(operation, extra.merging([field: value]) { _, new in new })
            check(invalid.map { SkyStudioGenerationControls.problem(model: model, ask: $0, prompt: "", references: plan) != nil } == true, "irrelevant \(field) refused: \(operation)")
        }
        check((try? imageOperationAsk(operation, extra.merging(["film": [:]]) { _, new in new })) == nil, "film refused before ordinary/official dispatch: \(operation)")
        check((try? SkyStudioImageOperation.validateRoute(AIToolArguments(["kind": "text_to_video", "operation": .string(operation)]))) == nil, "image operation does not route to video")
    }
    let factor = try! imageOperationAsk("upscale")
    checkEqual(SkyStudioGeneration.make(.image, prompt: "", ask: factor, canvas: 1, model: upscale, references: plan).params, ["upscale_factor": "x2"], "image upscale defaults x2 without image generation selectors")
    for value in ["x2", "x3", "x4"] {
        let ask = try! imageOperationAsk("upscale", ["upscale_factor": .string(value)])
        check(SkyStudioGenerationControls.problem(model: upscale, ask: ask, prompt: "", references: plan) == nil, "published upscale factor validates: \(value)")
    }
    for field in ["resolution", "aspect_ratio"] {
        let invalid = try! imageOperationAsk("upscale", [field: "1K"])
        check(SkyStudioGenerationControls.problem(model: upscale, ask: invalid, prompt: "", references: plan) != nil, "upscale refuses \(field)")
    }
    let wrong = try! imageOperationAsk("generate", ["upscale_factor": "x4"])
    check(SkyStudioGenerationControls.problem(model: catalog.model("nano2", kind: "image")!, ask: wrong, prompt: "Interior", references: plan) != nil, "factor cannot be silently ignored by a generator")
}

private func checkOrdinaryImageRequests(_ catalog: SkyStudioCatalog) async {
    for id in ["nano2-lite", "nano-banana-pro", "gpt-image-2", "seedream5-pro", "seedream5-flash", "nano2"] {
        let model = catalog.model(id, kind: "image")!
        let generation = SkyStudioGeneration.make(.image, prompt: "A quiet interior", ask: .init(), canvas: 16 / 9, model: model, references: imageInputPlan())
        let request = generation.job(model: id, maxCredits: 43, references: [["type": "image", "url": "https://example.org/own-upload"]], idempotencyKey: "ordinary-image")
        SkyStudioStub.reset { seen in
            let body = seen.body.flatMap { try? JSONValue.decode($0) }
            checkEqual(body?["model"], .string(id), "ordinary public id crosses HTTP unchanged: \(id)")
            checkEqual(body?["prompt"], "A quiet interior", "ordinary prompt crosses HTTP unchanged")
            checkEqual(body?["params"]?["resolution"], .string(model.choices("resolution")[0]), "ordinary tier comes from catalog")
            check(body?["operation"] == nil, "ordinary generator never receives a special operation")
            if seen.url.hasSuffix("/quote") {
                checkEqual(body?["params"]?["reference_image_count"], 1, "quote uses actual image count")
                check(body?["inputs"] == nil && body?["max_credits"] == nil, "ordinary quote has no upload/ceiling")
                return .http(200, #"{"credits":43,"typical_seconds":40}"#)
            }
            checkEqual(body?["inputs"]?["references"]?.arrayValue?.count, 1, "ordinary references survive submission")
            checkEqual(body?["max_credits"], 43, "ordinary submission carries server quote")
            return .http(200, #"{"job_id":"ordinary","status":"done","billing":{"status":"charged","credits_charged":43},"result":{"url":"https://example.org/image","content_type":"image/jpeg"}}"#)
        }
        checkEqual(try? await jobAPI().quote(request, key: jobKey).credits, 43, "ordinary quote: \(id)")
        let done = try? await SkyStudioJobRun(api: jobAPI(), key: jobKey).run(request)
        checkEqual(done?.result?.contentType, "image/jpeg", "ordinary JPEG result envelope: \(id)")
    }
}

private func checkImageRequests(_ catalog: SkyStudioCatalog) async {
    let api = jobAPI(), plan = imageInputPlan()
    let input = URL(string: "https://assets.skystudios.app/originals/USER/skycut/ref.png")!
    let cases: [(String, String, JSONValue, JSONValue)] = [
        ("qwen-angles", "camera_angle", ["resolution": "1K", "aspect_ratio": "16:9", "camera_angle": ["rotate": 135, "tilt": 0, "zoom": 0]], ["camera_angle": ["rotate": 135], "resolution": "1K", "aspect_ratio": "16:9"]),
        ("image-upscale", "upscale", ["upscale_factor": "x4"], ["upscale_factor": "x4"])
    ]
    for (id, operation, params, args) in cases {
        let ask = try! imageOperationAsk(operation, args.objectValue!)
        let generation = SkyStudioGeneration.make(.image, prompt: "", ask: ask, canvas: 1, model: catalog.model(id, kind: "image"), references: plan)
        let request = generation.job(model: id, imageURL: input, maxCredits: 41.25, idempotencyKey: "image-contract")
        let expected: JSONValue = ["kind": "image", "model": .string(id), "operation": .string(operation), "params": params]
        SkyStudioStub.reset { seen in
            let body = seen.body.flatMap { try? JSONValue.decode($0) }
            if seen.url.hasSuffix("/quote") { checkEqual(body, expected, "exact /quote contract: \(operation)"); return .http(200, #"{"credits":41.25,"typical_seconds":60}"#) }
            if seen.method == "POST" {
                var submit = expected.objectValue!
                submit["inputs"] = ["image_url": .string(input.absoluteString)]; submit["max_credits"] = 41.25; submit["idempotency_key"] = "image-contract"
                checkEqual(body, .object(submit), "exact /jobs contract: \(operation)")
                return .http(202, #"{"job_id":"image-original","status":"queued","poll_after_seconds":2}"#)
            }
            return .http(200, #"{"job_id":"image-original","status":"done","generation_status":"succeeded","delivery_status":"saved","billing":{"status":"charged","credits_charged":41.25},"result":{"url":"https://example.org/image","generation_id":"durable","content_type":"image/png","width":1280,"height":960}}"#)
        }
        let quote = try? await api.quote(request, key: jobKey)
        checkEqual(quote?.credits, 41.25, "server quote is authoritative, including multi-call angles: \(operation)")
        var runner = SkyStudioJobRun(api: api, key: jobKey); runner.sleep = SleepLog().sleep
        let done = try? await runner.run(request)
        checkEqual(done?.result?.width, 1280, "actual output dimensions retained: \(operation)")
        checkEqual(done?.billing?.netCharged, 41.25, "server billing retained: \(operation)")
        checkEqual(SkyStudioStub.log.map(\.method), ["POST", "POST", "GET"], "one quote, one submission, original poll: \(operation)")
        SkyStudioStub.reset { _ in .failure(.timedOut) }
        _ = await jobFailure { _ = try await runner.run(request) }
        checkEqual(SkyStudioStub.log.count, 1, "unknown submission is never replayed: \(operation)")
    }
}

private func checkImageErrors(_ catalog: SkyStudioCatalog) async {
    let api = jobAPI()
    for (id, operation, fields) in [("qwen-angles", "camera_angle", ["camera_angle": ["rotate": -135]] as [String: JSONValue]), ("image-upscale", "upscale", ["upscale_factor": "x3"])] {
        let ask = try! imageOperationAsk(operation, fields)
        let request = SkyStudioGeneration.make(.image, prompt: "", ask: ask, canvas: 1, model: catalog.model(id, kind: "image"), references: imageInputPlan()).job(model: id, maxCredits: 60, idempotencyKey: "keep-original")
        for (status, code) in [(400, "invalid_request"), (409, "price_changed"), (402, "insufficient_credits"), (429, "too_many_jobs")] {
            SkyStudioStub.reset { _ in .http(status, #"{"error":{"code":"\#(code)","message":"Server explanation","needed":60,"balance":1}}"#) }
            if case .server(let error)? = await expectFailure("operation error: \(operation) \(code)", { _ = try await api.quote(request, key: jobKey) }) {
                checkEqual(error.code, code, "server error code is preserved")
                checkEqual(error.message, "Server explanation", "server error message is preserved")
            } else { check(false, "expected server error: \(code)") }
        }
        SkyStudioStub.reset { _ in .http(200, #"{"job_id":"original","status":"failed","generation_status":"failed","delivery_status":"review_required","error":{"code":"provider_error","message":"Second camera step failed","refunded":true},"billing":{"status":"refunded","credits_charged":30,"credits_refunded":30}}"#) }
        var runner = SkyStudioJobRun(api: api, key: jobKey); runner.sleep = SleepLog().sleep
        let failure = await jobFailure { _ = try await runner.resume("original") }
        checkEqual(failure?.failure?.billing?.netCharged, 30, "partial provider costs survive failed operation: \(operation)")
        check(failure?.canRefund(beforeAccepted: false) == false, "legacy refund flag cannot erase partial provider costs")
        checkEqual(SkyStudioStub.log.map(\.method), ["GET"], "recovery only reads original operation")
    }
}
