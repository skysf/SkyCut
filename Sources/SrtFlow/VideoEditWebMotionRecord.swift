import Foundation
import SrtFlowCore

// Persistent web-motion source, parameter form and render provenance, together with EditClip's Codable boundary.
// Rendering and cache files belong to WebMotionActions and WebMotionProjectFiles; this file performs no I/O.

struct WebMotionClipRecord: Hashable, Sendable, Codable {
    var templateID: String?
    var name: String
    var page: String
    /// Canonical JSON object, supplied by the rendering service and retained verbatim on save.
    var parametersJSON: String
    var parameterFields: [WebMotionParameterField]
    /// Fonts used directly by the page, separate from editable font parameters and the preceding render.
    var fonts: [String]
    /// Full rendered source length and local source-time hit; trimming and splitting do not alter either.
    var duration: Double
    var hitTime: Double
    var width: Int
    var height: Int
    var fps: Int
    var provenance: WebMotionClipProvenance?

    init(page: String, parametersJSON: String = "{}", templateID: String? = nil, name: String = "Web Motion",
         parameterFields: [WebMotionParameterField] = [], fonts: [String] = [], duration: Double = 3, hitTime: Double = 0,
         width: Int = 1920, height: Int = 1080, fps: Int, provenance: WebMotionClipProvenance? = nil) {
        self.templateID = templateID
        self.name = name
        self.page = page
        self.parametersJSON = parametersJSON
        self.parameterFields = parameterFields
        self.fonts = fonts
        self.duration = duration
        self.hitTime = hitTime
        self.width = width
        self.height = height
        self.fps = fps
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey {
        case templateID, name, page, parametersJSON, parameterFields, fonts, duration, hitTime, width, height, fps, provenance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(page: try c.decode(String.self, forKey: .page),
                  parametersJSON: try c.decodeIfPresent(String.self, forKey: .parametersJSON) ?? "{}",
                  templateID: try c.decodeIfPresent(String.self, forKey: .templateID),
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Web Motion",
                  parameterFields: try c.decodeIfPresent([WebMotionParameterField].self, forKey: .parameterFields) ?? [],
                  fonts: try c.decodeIfPresent([String].self, forKey: .fonts) ?? [],
                  duration: try c.decodeIfPresent(Double.self, forKey: .duration) ?? 3,
                  hitTime: try c.decodeIfPresent(Double.self, forKey: .hitTime) ?? 0,
                  width: try c.decodeIfPresent(Int.self, forKey: .width) ?? 1920,
                  height: try c.decodeIfPresent(Int.self, forKey: .height) ?? 1080,
                  fps: try c.decodeIfPresent(Int.self, forKey: .fps) ?? ProjectFrameRate.fallback.fps,
                  provenance: try c.decodeIfPresent(WebMotionClipProvenance.self, forKey: .provenance))
    }
}

struct WebMotionParameterField: Hashable, Sendable, Codable {
    enum Kind: String, Sendable, Codable {
        case text, font, color, number

        init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .text
        }
    }

    var key: String
    var label: String
    var kind: Kind
    var minimum: Double?
    var maximum: Double?

    init(key: String, label: String, kind: Kind = .text, minimum: Double? = nil, maximum: Double? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.minimum = minimum
        self.maximum = maximum
    }

    private enum CodingKeys: String, CodingKey { case key, label, kind, minimum, maximum }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let key = try c.decode(String.self, forKey: .key)
        self.init(key: key, label: try c.decodeIfPresent(String.self, forKey: .label) ?? key,
                  kind: try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .text,
                  minimum: try c.decodeIfPresent(Double.self, forKey: .minimum),
                  maximum: try c.decodeIfPresent(Double.self, forKey: .maximum))
    }
}

struct WebMotionClipProvenance: Hashable, Sendable, Codable {
    var fingerprint: String
    var renderer: Int
    var macOS: String
    var macOSBuild: String
    var webKit: String
    var fonts: [String]
    var renderedAt: Date

    init(fingerprint: String, renderer: Int, macOS: String, macOSBuild: String = "", webKit: String,
         fonts: [String] = [], renderedAt: Date = Date()) {
        self.fingerprint = fingerprint
        self.renderer = renderer
        self.macOS = macOS
        self.macOSBuild = macOSBuild
        self.webKit = webKit
        self.fonts = fonts
        self.renderedAt = renderedAt
    }

    private enum CodingKeys: String, CodingKey { case fingerprint, renderer, macOS, macOSBuild, webKit, fonts, renderedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(fingerprint: try c.decode(String.self, forKey: .fingerprint),
                  renderer: try c.decodeIfPresent(Int.self, forKey: .renderer) ?? 0,
                  macOS: try c.decodeIfPresent(String.self, forKey: .macOS) ?? "",
                  macOSBuild: try c.decodeIfPresent(String.self, forKey: .macOSBuild) ?? "",
                  webKit: try c.decodeIfPresent(String.self, forKey: .webKit) ?? "",
                  fonts: try c.decodeIfPresent([String].self, forKey: .fonts) ?? [],
                  renderedAt: try c.decodeIfPresent(Date.self, forKey: .renderedAt) ?? Date(timeIntervalSince1970: 0))
    }
}

extension EditClip: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, sourceURL, isAudioOnly, sourceStart, sourceDuration, speed, timelineStart
        case isMuted, volume, linkGroup, transitionAfter, transitionDuration
        case placement, info, audioAssetDuration, stillImageURL, remoteKey
        case videoFadeInDuration, videoFadeOutDuration
        case rotationDegrees, opacity, flippedHorizontally, flippedVertically, crop, animation
        case presetAnimation
        case markers
        case fadeInDuration, fadeOutDuration
        case isHidden
        case volumeCurve, soundScene, voiceBandDB, soundRole
        case upscale, webMotion, isScreenRecording
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 素材路径是唯一必需的字段：没有它这段就不成立。
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            sourceURL: try c.decode(URL.self, forKey: .sourceURL),
            isAudioOnly: try c.decodeIfPresent(Bool.self, forKey: .isAudioOnly) ?? false,
            sourceStart: try c.decodeIfPresent(Double.self, forKey: .sourceStart) ?? 0,
            sourceDuration: try c.decodeIfPresent(Double.self, forKey: .sourceDuration) ?? 0,
            speed: try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1,
            timelineStart: try c.decodeIfPresent(Double.self, forKey: .timelineStart) ?? 0,
            isMuted: try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
            volume: try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1,
            fadeInDuration: try c.decodeIfPresent(Double.self, forKey: .fadeInDuration) ?? 0,
            fadeOutDuration: try c.decodeIfPresent(Double.self, forKey: .fadeOutDuration) ?? 0,
            linkGroup: try c.decodeIfPresent(UUID.self, forKey: .linkGroup),
            transitionAfter: try c.decodeIfPresent(ClipTransition.self, forKey: .transitionAfter) ?? .none,
            transitionDuration: try c.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? 0.5,
            videoFadeInDuration: try c.decodeIfPresent(Double.self, forKey: .videoFadeInDuration) ?? 0,
            videoFadeOutDuration: try c.decodeIfPresent(Double.self, forKey: .videoFadeOutDuration) ?? 0,
            placement: try c.decodeIfPresent(ClipPlacement.self, forKey: .placement),
            rotationDegrees: try c.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0,
            opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
            flippedHorizontally: try c.decodeIfPresent(Bool.self, forKey: .flippedHorizontally) ?? false,
            flippedVertically: try c.decodeIfPresent(Bool.self, forKey: .flippedVertically) ?? false,
            crop: try c.decodeIfPresent(ClipCrop.self, forKey: .crop),
            animation: try c.decodeIfPresent(ClipAnimation.self, forKey: .animation),
            info: try c.decodeIfPresent(MediaInfo.self, forKey: .info),
            audioAssetDuration: try c.decodeIfPresent(Double.self, forKey: .audioAssetDuration),
            stillImageURL: try c.decodeIfPresent(URL.self, forKey: .stillImageURL),
            remoteKey: try c.decodeIfPresent(String.self, forKey: .remoteKey)
        )
        // `needsStillConversion` 是导入过程中的临时状态，不存盘：打开工程时
        // 静帧视频是现查缓存现补的（见 VideoEditProjectFile.restoreStillClips）。
        markers = try c.decodeIfPresent([ClipMarker].self, forKey: .markers) ?? []
        // 缺键 = 没隐藏。老工程（v15 及更早）根本没有这个概念，回退 false
        // 就是它们当时的渲染结果 —— 升级不改变谁已经做好的片子。
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        // v19 起才有。缺键 = 没画过曲线（整段就是 `volume`），与老版本的渲染一致。
        // 读进来先消毒（NaN、越界的 dB），规则见 `VolumeCurve.sanitized`。
        volumeCurve = VolumeCurve.sanitized(
            try c.decodeIfPresent(KeyframeTrack.self, forKey: .volumeCurve) ?? KeyframeTrack()
        )
        // v20 起才有。认不出的场景（更新的版本加的）整个不认、当作没有（`SoundScene` 的解码）。
        soundScene = (try? c.decodeIfPresent(SoundScene.self, forKey: .soundScene)) ?? nil
        // v38. Missing = no cut; non-finite or out of range is cleaned (VoiceBand.sanitized).
        voiceBandDB = VoiceBand.sanitized(try c.decodeIfPresent(Double.self, forKey: .voiceBandDB) ?? 0)
        // v39. Missing = nothing saved (inferred); a role this build doesn't know reads as nothing saved (ClipSoundRole).
        soundRole = (try? c.decodeIfPresent(ClipSoundRole.self, forKey: .soundRole)) ?? nil
        // v29 起才有。缺键 = 用的就是原片。认不出的记录整个不认（只有原片路径是必需的，其余缺了走默认）。
        upscale = (try? c.decodeIfPresent(ClipUpscaleRecord.self, forKey: .upscale)) ?? nil
        webMotion = try c.decodeIfPresent(WebMotionClipRecord.self, forKey: .webMotion)
        isScreenRecording = try c.decodeIfPresent(Bool.self, forKey: .isScreenRecording) ?? false
        // v14 及更早：画面渐变只有时长、没有"效果"这个概念。合并成一个槽之后，
        // 这些段就是 In/Out = Fade —— 不认回来的话，老工程一打开，调好的淡入淡出
        // 会因为 `kind == .none` 当场失效（不变量见 `ClipPresetAnimation.isEmpty`）。
        if let stored = try c.decodeIfPresent(ClipPresetAnimation.self, forKey: .presetAnimation) {
            presetAnimation = stored
        } else {
            presetAnimation = ClipPresetAnimation(
                entrance: videoFadeInDuration > 0 ? .fade : .none,
                exit: videoFadeOutDuration > 0 ? .fade : .none,
                intensity: ClipPresetAnimation.default.intensity
            )
        }
        presetAnimation.clampToValidRange()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceURL, forKey: .sourceURL)
        try c.encode(isAudioOnly, forKey: .isAudioOnly)
        try c.encode(sourceStart, forKey: .sourceStart)
        try c.encode(sourceDuration, forKey: .sourceDuration)
        try c.encode(speed, forKey: .speed)
        try c.encode(timelineStart, forKey: .timelineStart)
        try c.encode(isMuted, forKey: .isMuted)
        try c.encode(volume, forKey: .volume)
        // 没设渐变的段不写这两个键：绝大多数段是 0，写出来只会把工程文件撑大。
        // 缺键按 0 解码，跟「关」完全同义，所以按需写是安全的。
        if fadeInDuration > 0 { try c.encode(fadeInDuration, forKey: .fadeInDuration) }
        if fadeOutDuration > 0 { try c.encode(fadeOutDuration, forKey: .fadeOutDuration) }
        // 同声音渐变：没隐藏的段不写这个键（绝大多数段都是），缺键按 false
        // 解码，与「没隐藏」完全同义。写了它的工程才算 v16 数据。
        if isHidden { try c.encode(isHidden, forKey: .isHidden) }
        try c.encodeIfPresent(linkGroup, forKey: .linkGroup)
        try c.encode(transitionAfter, forKey: .transitionAfter)
        try c.encode(transitionDuration, forKey: .transitionDuration)
        // 同声音渐变：没设的段不写键，缺键按 0 解码，与「关」完全同义。
        if videoFadeInDuration > 0 { try c.encode(videoFadeInDuration, forKey: .videoFadeInDuration) }
        if videoFadeOutDuration > 0 { try c.encode(videoFadeOutDuration, forKey: .videoFadeOutDuration) }
        try c.encodeIfPresent(placement, forKey: .placement)
        try c.encode(rotationDegrees, forKey: .rotationDegrees)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(flippedHorizontally, forKey: .flippedHorizontally)
        try c.encode(flippedVertically, forKey: .flippedVertically)
        try c.encodeIfPresent(crop, forKey: .crop)
        try c.encodeIfPresent(isAnimated ? animation : nil, forKey: .animation)
        try c.encodeIfPresent(info, forKey: .info)
        try c.encodeIfPresent(audioAssetDuration, forKey: .audioAssetDuration)
        try c.encodeIfPresent(stillImageURL, forKey: .stillImageURL)
        // 本地导入的素材没有这个键（判据与格式版本闸门 `requiresFormatVersion18` 同源）。
        try c.encodeIfPresent(remoteKey, forKey: .remoteKey)
        // 没有标记的段不写这个键：绝大多数工程一枚标记都没有，键写出来只是把
        // 每段的 JSON 撑大一行。
        if !markers.isEmpty { try c.encode(markers, forKey: .markers) }
        // 没设入/出场效果的段不写这个键（判据是 `isEmpty`，与格式版本闸门
        // `requiresFormatVersion15` 同源）：强度是跟着效果走的，没效果时它的值
        // 不影响任何一帧画面，写出来只会把每段的 JSON 撑大一行。
        if !presetAnimation.isEmpty { try c.encode(presetAnimation, forKey: .presetAnimation) }
        // 没画过曲线的段不写这个键（判据与格式版本闸门 `requiresFormatVersion19` 同源）。
        if !volumeCurve.isEmpty { try c.encode(volumeCurve, forKey: .volumeCurve) }
        // 没挂场景的段不写这个键（判据与格式版本闸门 `requiresFormatVersion20` 同源）。
        try c.encodeIfPresent(soundScene, forKey: .soundScene)
        // No voice-band cut, no key (the same test as the format gate `requiresFormatVersion38`).
        if voiceBandDB != 0 { try c.encode(voiceBandDB, forKey: .voiceBandDB) }
        // No saved role, no key (the same test as the format gate `requiresFormatVersion39`).
        try c.encodeIfPresent(soundRole, forKey: .soundRole)
        // 没换过源的段不写这个键（判据与格式版本闸门 `requiresFormatVersion29` 同源）。
        try c.encodeIfPresent(upscale, forKey: .upscale)
        try c.encodeIfPresent(webMotion, forKey: .webMotion)
        if isScreenRecording { try c.encode(true, forKey: .isScreenRecording) }
    }
}

