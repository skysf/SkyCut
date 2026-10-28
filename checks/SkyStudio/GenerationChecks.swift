import CoreGraphics
import Foundation
import ImageIO
import SrtFlowMCPKit
import UniformTypeIdentifiers

// generate_media 送 Sky Studio 的那一份（SkyStudioGeneration，收费方案第 6 刀 6b，2026-10-28）：
// - 词表和 App 的类型对账（小程序不链接 App 的类型，词表是抄的）；
// - 每种的默认值：画幅跟画布 / 跟首帧、视频 5 秒 768p、音效 5 秒 wav、音乐纯音乐、不给时长让模型定；秒数取整；
// - 给了但用不上的参数说一句、不送过去；
// - 送 /quote、/jobs 的请求体（图生视频的首帧放 inputs.image_url、/jobs 才带 max_credits）、确认码绑的那几个记号；
// - 离谁最近的画幅（从 fal 那边挪过来的，只留这一份）、成品存成什么扩展名。

func runGenerationChecks() {
    // 1. 词表对账。
    checkEqual(MCPVocabulary.generationKinds, SkyStudioGeneration.Kind.allCases.map(\.rawValue), "generation kinds match SkyStudioGeneration.Kind")
    checkEqual(MCPVocabulary.videoResolutions, SkyStudioGeneration.videoResolutions, "video resolutions match Sky Studio's (no 1080p)")
    checkEqual(MCPVocabulary.generationAspects, SkyStudioGeneration.imageAspects, "aspect ratios match the image model's")
    check(Set(SkyStudioGeneration.videoAspects).isSubset(of: Set(SkyStudioGeneration.imageAspects)), "every video aspect is also an image aspect")

    let wide = 1920.0 / 1080
    let tall = 1080.0 / 1920

    // 2. 图：画幅跟画布、给了照用；时长、分辨率用不上。
    let image = SkyStudioGeneration.make(.image, prompt: "a lighthouse", ask: .init(), canvas: wide)
    checkEqual(image.params, ["aspect_ratio": "16:9"], "an image follows the canvas")
    checkEqual(SkyStudioGeneration.make(.image, prompt: "x", ask: .init(), canvas: 0.8).params["aspect_ratio"], "4:5", "a 4:5 canvas: the image model has 4:5")
    let portrait = SkyStudioGeneration.make(.image, prompt: "x", ask: .init(duration: 5, resolution: "480p", aspectRatio: "2:3"), canvas: wide)
    checkEqual(portrait.params, ["aspect_ratio": "2:3"], "a given aspect is used, the rest is not sent")
    checkEqual(portrait.notes.count, 2, "duration and resolution are said to be ignored")

    // 3. 文生视频：5 秒、768p、画幅跟画布（视频那几种里最近的）；秒数取整。
    let shot = SkyStudioGeneration.make(.textToVideo, prompt: "waves", ask: .init(), canvas: tall)
    checkEqual(shot.params, ["duration": 5, "resolution": "768p", "aspect_ratio": "9:16"], "text_to_video defaults")
    checkEqual(SkyStudioGeneration.make(.textToVideo, prompt: "x", ask: .init(), canvas: 0.8).params["aspect_ratio"], "3:4",
               "a 4:5 canvas: video has no 4:5, the closest is 3:4")
    let longer = SkyStudioGeneration.make(.textToVideo, prompt: "x", ask: .init(duration: 6.6, resolution: "480p", aspectRatio: "21:9"), canvas: wide)
    checkEqual(longer.params, ["duration": 7, "resolution": "480p", "aspect_ratio": "21:9"], "given values are used, seconds whole")
    check(longer.notes.isEmpty, "nothing ignored")

    // 4. 图生视频：画幅送离首帧最近的那个（网页那条路要一个），给了的画幅不用；读不出首帧就跟画布。
    let moving = SkyStudioGeneration.make(.imageToVideo, prompt: "x", ask: .init(aspectRatio: "1:1"), canvas: wide, frame: 1.5)
    checkEqual(moving.params["aspect_ratio"], "4:3", "a 3:2 photo: the closest video aspect is 4:3")
    checkEqual(moving.notes.count, 1, "the given aspect is said to be ignored")
    checkEqual(SkyStudioGeneration.make(.imageToVideo, prompt: "x", ask: .init(), canvas: tall).params["aspect_ratio"], "9:16",
               "no frame size: the canvas")

    // 5. 音乐：纯音乐、不给时长让模型定；不是纯音乐才送歌词。
    let music = SkyStudioGeneration.make(.music, prompt: "calm piano", ask: .init(), canvas: wide)
    checkEqual(music.params, ["instrumental": true], "music: instrumental, the model decides the length")
    let song = SkyStudioGeneration.make(.music, prompt: "x", ask: .init(duration: 90.4, instrumental: false, lyrics: "  la la  "), canvas: wide)
    checkEqual(song.params, ["duration": 90, "instrumental": false, "lyrics": "la la"], "a song: lyrics trimmed, seconds whole")
    let mute = SkyStudioGeneration.make(.music, prompt: "x", ask: .init(aspectRatio: "16:9", lyrics: "la"), canvas: wide)
    checkEqual(mute.params, ["instrumental": true], "lyrics with instrumental music are not sent")
    checkEqual(mute.notes.count, 2, "lyrics and aspect_ratio are said to be ignored")

    // 6. 音效：5 秒、wav；给了的秒数照送（服务器管 0.5–180）。
    let effect = SkyStudioGeneration.make(.soundEffect, prompt: "door creak", ask: .init(), canvas: wide)
    checkEqual(effect.params, ["duration": 5, "audio_format": "wav"], "sound effect defaults")
    checkEqual(SkyStudioGeneration.make(.soundEffect, prompt: "x", ask: .init(duration: 1.25), canvas: wide).params["duration"], 1.25,
               "a sound effect keeps fractions of a second")
    checkEqual(SkyStudioGeneration.make(.soundEffect, prompt: "x", ask: .init(resolution: "768p", instrumental: true), canvas: wide).notes.count, 2,
               "resolution and instrumental are said to be ignored")

    // 7. 请求体：/quote 不带 inputs 和 max_credits；/jobs 带首帧和同意的价。
    let frameURL = URL(string: "https://assets.skystudio.app/originals/u/skycut/frame.jpg")!
    let job = moving.job(model: "minimax-h3", imageURL: frameURL, maxCredits: 80)
    checkEqual(job.kind, "image_to_video", "the kind is Sky Studio's word")
    checkEqual(job.model, "minimax-h3", "the model id from /models")
    checkEqual(job.prompt, "x", "the prompt")
    checkEqual(job.inputs, ["image_url": frameURL.absoluteString], "the first frame goes in inputs.image_url")
    checkEqual(job.jobBody["max_credits"]?.doubleValue, 80, "/jobs carries the agreed price")
    check(job.quoteBody["inputs"] == nil && job.quoteBody["max_credits"] == nil, "/quote carries neither inputs nor max_credits")
    checkEqual(image.job(model: "seedream5-flash").inputs, [:], "an image has no inputs")
    check(image.job(model: "m").idempotencyKey != image.job(model: "m").idempotencyKey, "every request has its own idempotency key")

    // 8. 确认码绑着的记号（不带语言）。
    checkEqual(shot.summary(modelTitle: "MiniMax H3"), "MiniMax H3 · 5 s · 768p", "video summary")
    checkEqual(music.summary(modelTitle: "Lyria 3 Pro"), "Lyria 3 Pro · auto", "music summary without a length")
    checkEqual(song.summary(modelTitle: "Lyria 3 Pro"), "Lyria 3 Pro · 90 s · vocals", "a song's summary")
    checkEqual(effect.summary(modelTitle: "Sonilo"), "Sonilo · 5.0 s", "sound effect summary")
    checkEqual(image.summary(modelTitle: "Seedream 5 Flash"), "Seedream 5 Flash · 16:9", "image summary")

    // 9. 离谁最近的画幅。
    let video = SkyStudioGeneration.videoAspects
    checkEqual(SkyStudioGeneration.nearestAspect(to: wide, in: video), "16:9", "1920×1080 → 16:9")
    checkEqual(SkyStudioGeneration.nearestAspect(to: tall, in: video), "9:16", "1080×1920 → 9:16")
    checkEqual(SkyStudioGeneration.nearestAspect(to: 1, in: video), "1:1", "square")
    checkEqual(SkyStudioGeneration.nearestAspect(to: 2.39, in: video), "21:9", "cinemascope → 21:9")
    checkEqual(SkyStudioGeneration.nearestAspect(to: 0.8, in: video), "3:4", "4:5 → the closest video aspect is 3:4")
    checkEqual(SkyStudioGeneration.nearestAspect(to: 0, in: video), "21:9", "no ratio: the first option")
    checkEqual(SkyStudioGeneration.nearestAspect(to: .nan, in: video), "21:9", "not a number: the first option")
    check(SkyStudioGeneration.aspectValue("16:0") == nil && SkyStudioGeneration.aspectValue("wide") == nil, "bad aspect texts are refused")

    // 10. 成品的扩展名：服务器说的类型 → 地址的扩展名 → 按种类猜。
    let some = URL(string: "https://assets.skystudio.app/outputs/a/b")!
    checkEqual(SkyStudioGeneration.fileExtension(contentType: "image/jpeg", url: some, kind: .image), "jpg", "image/jpeg → jpg")
    checkEqual(SkyStudioGeneration.fileExtension(contentType: "audio/mpeg; charset=binary", url: some, kind: .music), "mp3", "parameters after ; are ignored")
    checkEqual(SkyStudioGeneration.fileExtension(contentType: nil, url: URL(string: "https://x/y/clip.MP4")!, kind: .image), "mp4", "no type: the address")
    checkEqual(SkyStudioGeneration.fileExtension(contentType: nil, url: URL(string: "https://x/y/a.jpeg")!, kind: .image), "jpg", "jpeg → jpg")
    checkEqual(SkyStudioGeneration.fileExtension(contentType: "application/octet-stream", url: some, kind: .soundEffect), "wav", "nothing known: by kind")
    checkEqual(SkyStudioGeneration.fileExtension(contentType: nil, url: some, kind: .textToVideo), "mp4", "video by kind")
}

// 图生视频的首帧（SkyStudioGenerationFrame）：真写几张图来读 —— 摆正之后的宽高比（EXIF 转了 90 度的对调）、认得的格式原样传、
// 别的格式转成 JPEG 传完删掉、读不出来的说清楚。
func runGenerationFrameChecks() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skycut-frame-check-\(getpid())-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func picture(_ name: String, type: UTType, orientation: Int? = nil) -> URL {
        let url = folder.appendingPathComponent(name)
        let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        if let image = context?.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) {
            let properties: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        return url
    }

    let png = picture("frame.png", type: .png)
    checkEqual(SkyStudioGenerationFrame.aspect(of: png), 1.5, "a 300×200 picture is 3:2")
    let turned = picture("turned.jpg", type: .jpeg, orientation: 6)
    checkEqual(SkyStudioGenerationFrame.aspect(of: turned), 200.0 / 300, "a photo turned 90 degrees by EXIF: width and height swap")
    checkEqual(SkyStudioGenerationFrame.aspect(of: folder.appendingPathComponent("none.png")), nil, "no file: nil")

    if let sent = try? SkyStudioGenerationFrame.prepare(png, workFolder: folder.appendingPathComponent("work")) {
        check(sent.url == png && sent.contentType == "image/png" && !sent.temporary, "a PNG is sent as it is")
    } else {
        check(false, "a PNG can be sent")
    }
    let tiff = picture("frame.tiff", type: .tiff)
    if let sent = try? SkyStudioGenerationFrame.prepare(tiff, workFolder: folder.appendingPathComponent("work")) {
        check(sent.temporary && sent.contentType == "image/jpeg" && sent.url.pathExtension == "jpg", "a TIFF is turned into a JPEG")
        check(FileManager.default.fileExists(atPath: sent.url.path), "the JPEG is written")
        sent.cleanUp()
        check(!FileManager.default.fileExists(atPath: sent.url.path), "and removed after sending")
    } else {
        check(false, "a TIFF can be sent after turning it into a JPEG")
    }
    let junk = folder.appendingPathComponent("not-a-picture.heic")
    try? Data("hello".utf8).write(to: junk)
    do {
        _ = try SkyStudioGenerationFrame.prepare(junk, workFolder: folder.appendingPathComponent("work"))
        check(false, "a file that is not a picture is refused")
    } catch let problem as SkyStudioGenerationFrame.Problem {
        check(problem.message.contains("not a picture SkyCut can read"), "says the file is not a picture: \(problem.message)")
    } catch {
        check(false, "refused with the wrong error: \(error)")
    }
}
