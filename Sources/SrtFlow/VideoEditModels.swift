import Foundation
import SrtFlowCore

// MARK: - 剪辑

/// 时间线上的一段素材。
///
/// 时间有两套：`sourceStart`/`sourceDuration` 是素材自己的时间（裁掉头尾就是改
/// 它们），`timelineStart` 是这段落在时间线上的位置。变速只改换算关系：
/// 时间线上的长度 = 源长度 ÷ 速度。
struct EditClip: Identifiable, Hashable, Sendable {
    let id: UUID
    var sourceURL: URL
    /// 素材本身是视频还是纯音频（决定画不画到画面上）。
    var isAudioOnly: Bool

    var sourceStart: Double
    var sourceDuration: Double
    var speed: Double
    var timelineStart: Double

    var isMuted: Bool
    var volume: Double
    /// 声音的渐入/渐出时长，单位是**时间线秒**（变速之后）。0 = 关。
    /// 生效值要走 `audioFades` 夹紧，规则见 VideoEditAudioFade.swift。
    var fadeInDuration: Double
    var fadeOutDuration: Double
    /// 同组的剪辑（分离出的音频）在「链接」开着时一起移动、分割、删除。
    var linkGroup: UUID?

    /// 这段和**下一段**之间的转场，只对主轨有意义。
    var transitionAfter: ClipTransition
    var transitionDuration: Double

    /// 画面的渐入/渐出时长，单位是**时间线秒**（变速之后）。0 = 关。
    /// 生效值要走 `videoFades` 夹紧，规则见 VideoEditVideoFade.swift。
    var videoFadeInDuration: Double
    var videoFadeOutDuration: Double

    /// 用户在预览里摆过的自由位置/尺寸；nil = 默认布局（等比铺满居中）。
    var placement: ClipPlacement?

    // Inspector Transform 区的四项静态变换。都有「无操作」默认值，
    // 全默认时预览/导出走原来的轻量路径。
    /// 顺时针旋转角（度），绕摆放框中心。
    var rotationDegrees: Double
    /// 画面不透明度 0…1。
    var opacity: Double
    var flippedHorizontally: Bool
    var flippedVertically: Bool
    /// 四边裁切；nil = 不裁。
    var crop: ClipCrop?
    /// 关键帧动画（位置/缩放/旋转/不透明度）；nil = 无。类型与取值见
    /// VideoEditAnimation.swift。
    var animation: ClipAnimation?
    /// 预设的入场 / 出场动画（Inspector 的 Animation 区）。**时长不在这里**，
    /// 它和画面渐变共用 `videoFadeInDuration/OutDuration`；类型与仲裁见
    /// VideoEditClipAnimation.swift，逐帧求值见 VideoEditClipAnimator.swift。
    ///
    /// 不进 `init`（同 `markers`）：绝大多数段没设动画，摊进按成员构造器只会让
    /// 每个调用点都要多写一行。
    var presetAnimation: ClipPresetAnimation = .default

    /// 用户打在这段素材上的标记。锚在源时间上，只影响编辑期的显示，不进合成
    /// 和导出。类型与读写见 VideoEditClipMarker.swift。
    var markers: [ClipMarker] = []

    /// 这一段**单独**隐藏（快捷键 V）。画面和声音都不进预览、不进成片 —— 与整轨
    /// 隐藏同一个心智，只是单位从一条轨变成一段素材。
    ///
    /// 隐藏的段在时间线上**仍然可选、可拖、可裁**（只是灰显 + 一枚斜杠眼睛）。
    /// 整轨隐藏那边是「灰显且不可编辑」，这里刻意不同：按完 V 就再也点不中它的话，
    /// 用户只能靠撤销把它找回来。
    ///
    /// 与 `EditLane.isHidden` / `mainHidden` **互不覆盖**：轨隐藏了，段上的这个
    /// 标记原样留着；轨放出来，之前单独藏起来的段还是藏着。
    ///
    /// 不进 `init`（同 `markers` / `presetAnimation`）：绝大多数段没隐藏，摊进
    /// 按成员构造器只会让每个调用点都多写一行。合同见
    /// docs/architecture/clip-visibility.md。
    var isHidden = false
    /// Native screen-capture provenance: static screens are expected.
    var isScreenRecording = false

    /// 画在这段声音上的音量曲线（值是 **dB**，点锚在源时间上，同关键帧）。
    ///
    /// 空 = 整段就是 `volume` 这一个值；有点时**曲线取代 `volume`**。取值、编辑与
    /// 两条管线共用的折线表都在 VideoEditVolumeCurve.swift，合同见
    /// docs/architecture/audio-volume-curve.md。不进 `init`（同 `markers`）。
    var volumeCurve = KeyframeTrack()

    /// 声音场景（喇叭 / 室内 / 室外）；nil = 没有。模型见 VideoEditSoundScene.swift，合同见
    /// docs/architecture/sound-scenes.md。不进 `init`（同 `markers`）。
    var soundScene: SoundScene?
    /// Its own voice band (300 Hz–3 kHz) lowered this many dB, −30…0, 0 = off (`VoiceBand`; sound-scenes.md section 5).
    var voiceBandDB = 0.0
    /// What its sound is, saved (v39); nil = inferred from where it came from (VideoEditClipSoundRole.swift).
    var soundRole: ClipSoundRole?

    /// 这段的素材是 upscale 出来的文件时，记着原片在哪、新文件的 0 秒对应原片的第几秒、用的哪个档位
    /// （换回原片、再次 upscale 都靠它；合同见 VideoEditClipUpscale.swift）。不进 `init`（同 `markers`）。
    var upscale: ClipUpscaleRecord?

    /// Stored page and parameters; sourceURL is its disposable rendered movie, never imported media.
    var webMotion: WebMotionClipRecord?

    /// 探测到的源信息（时长、尺寸、有没有音轨）。纯音频素材是 nil。
    var info: MediaInfo?
    /// 纯音频素材的总时长（MediaProbe 只管视频，音频单独记）。
    var audioAssetDuration: Double?
    /// 静态图片素材：`sourceURL` 指向生成的循环视频，这里留着原图路径当名字用。
    var stillImageURL: URL?
    /// 这段素材来自音频库的哪一条（manifest 的 `id`）。
    ///
    /// 本地导入的素材是 nil。非 nil 时它是**重链接的第一层线索**：缓存被清掉、
    /// 换了机器、工程发给别人 —— 都能按这个 id 从 R2 重新拉回来，用户根本看不到
    /// 「素材丢失」。见 docs/architecture/video-edit-project-file.md。
    var remoteKey: String?
    /// 图片刚拖进来、静帧视频还在后台转：块先上轨可编辑，预览暂时跳过它。
    var needsStillConversion = false
    /// 转场余料不够时，渲染要把**首帧 / 尾帧定格**多久（时间线秒）。
    ///
    /// **只在渲染副本里非零**：唯一的写入方是 `TimelineState.expandingTransitionHandles`
    /// （两条渲染管线入口处调的那一份），用户的工程里恒为 0、不进工程文件。
    /// 渲染副本里 `sourceStart` / `sourceDuration` 已经把定格那两截也算进去了
    /// （所以 `timelineDuration` 照旧是整段长度），真正要从素材里取的那一段见
    /// `renderSourceStart` / `renderSourceDuration`。2026-09-23 用户拍板：余料不够
    /// 就定格补足，见 VideoEditTransitionHandles.swift 的 `transitionExtension`。
    var renderHoldHead = 0.0
    var renderHoldTail = 0.0

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        isAudioOnly: Bool = false,
        sourceStart: Double = 0,
        sourceDuration: Double,
        speed: Double = 1,
        timelineStart: Double = 0,
        isMuted: Bool = false,
        volume: Double = 1,
        fadeInDuration: Double = 0,
        fadeOutDuration: Double = 0,
        linkGroup: UUID? = nil,
        transitionAfter: ClipTransition = .none,
        transitionDuration: Double = 0.5,
        videoFadeInDuration: Double = 0,
        videoFadeOutDuration: Double = 0,
        placement: ClipPlacement? = nil,
        rotationDegrees: Double = 0,
        opacity: Double = 1,
        flippedHorizontally: Bool = false,
        flippedVertically: Bool = false,
        crop: ClipCrop? = nil,
        animation: ClipAnimation? = nil,
        info: MediaInfo? = nil,
        audioAssetDuration: Double? = nil,
        stillImageURL: URL? = nil,
        remoteKey: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.isAudioOnly = isAudioOnly
        self.sourceStart = sourceStart
        self.sourceDuration = sourceDuration
        self.speed = speed
        self.timelineStart = timelineStart
        self.isMuted = isMuted
        self.volume = volume
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
        self.linkGroup = linkGroup
        self.transitionAfter = transitionAfter
        self.transitionDuration = transitionDuration
        self.videoFadeInDuration = videoFadeInDuration
        self.videoFadeOutDuration = videoFadeOutDuration
        self.placement = placement
        self.rotationDegrees = rotationDegrees
        self.opacity = opacity
        self.flippedHorizontally = flippedHorizontally
        self.flippedVertically = flippedVertically
        self.crop = crop
        self.animation = animation
        self.info = info
        self.audioAssetDuration = audioAssetDuration
        self.stillImageURL = stillImageURL
        self.remoteKey = remoteKey
    }

    var name: String {
        webMotion?.name ?? (stillImageURL ?? sourceURL).deletingPathExtension().lastPathComponent
    }

    var isStillImage: Bool { stillImageURL != nil }

    /// 素材文件的总长度（还能往两头拉出多少，取决于它）。
    var assetDuration: Double { info?.duration ?? audioAssetDuration ?? sourceDuration }

    var hasAudio: Bool { isAudioOnly || (info?.hasAudio ?? false) }

    var timelineDuration: Double { sourceDuration / max(0.05, speed) }
    var timelineEnd: Double { timelineStart + timelineDuration }

    /// 真正要从素材里取的那一段（素材秒）：去掉首尾定格那两截
    /// （`renderHoldHead` / `renderHoldTail`，只在渲染副本里非零）。
    var renderSourceStart: Double { sourceStart + renderHoldHead * max(0.05, speed) }
    var renderSourceDuration: Double {
        sourceDuration - (renderHoldHead + renderHoldTail) * max(0.05, speed)
    }

    func contains(time: Double) -> Bool {
        time > timelineStart + 0.001 && time < timelineEnd - 0.001
    }

    /// 画面上有任何非默认的变换吗（导出走覆盖分支、检查器显示复原用）。
    ///
    /// 画面渐变也算：它要在 rgba 上做 alpha 斜坡，只有变换链那条路会先
    /// `format=rgba`，轻量路径挂不上 `fade`（见 VideoEditVideoFade.swift）。
    ///
    /// **预设入/出场动画不必单列**：要逐帧的效果一律走预渲染，根本到不了这条
    /// 判据；而它的时长就是 `videoFade*`，`hasVideoFade` 已经把它覆盖住了。
    var hasVisualTransform: Bool {
        placement != nil || abs(rotationDegrees) > 0.01 || opacity < 0.999
            || flippedHorizontally || flippedVertically || !(crop?.isEmpty ?? true)
            || isAnimated || hasVideoFade
    }

    /// 这段的画面把整个画布**盖满且完全不透明**吗。
    ///
    /// 叠化的「后段垫底、前段淡出」路径只有在接缝两侧都满足这个条件时才逐像素
    /// 精确等于 xfade dissolve —— 判定条件必须是它，不能拿 `hasVisualTransform`
    /// 凑数：仅翻转（甚至放大出画布的摆放）照样满幅不透明，走近似路径纯属
    /// 误伤（白闪变暗）。旋转保守地一律当不满幅；带关键帧动画或预设入/出场
    /// 动画的段同样保守走近似路径（逐时刻判定不值得）。
    func coversCanvasOpaquely(canvas: CGSize) -> Bool {
        guard opacity >= 0.999, abs(rotationDegrees) <= 0.01, !isAnimated,
              !hasVideoFade, !needsPerFrameAnimation, sourceAlpha == .opaque else { return false }
        let frame = resolvedPlacement(canvas: canvas).frame(in: canvas)
        return frame.minX <= 0.5 && frame.minY <= 0.5
            && frame.maxX >= canvas.width - 0.5 && frame.maxY >= canvas.height - 0.5
    }

    /// 素材是带透明的静帧（透明 PNG 转出来的预乘 ProRes 4444，`StillAlphaNaming`）：带关键帧时 matte 用它自己的那份遮罩。
    var isAlphaStill: Bool { stillImageURL != nil && StillAlphaNaming.isAlphaStill(sourceURL) }

    /// 画面带不带透明、存的是预乘还是直通 —— **静帧和视频一个判断**：透明静帧是自己转的预乘 ProRes（ffmpeg 不写标记），
    /// 别的静帧不透明，视频看文件里的标记（`MediaInfo.alpha`）。预览垫黑底、盖不满画布、换预乘副本、导出怎么叠、
    /// 预渲染的遮罩都只问它（docs/architecture/freeze-frame.md 第 4a3 节）。
    var sourceAlpha: SourceAlpha {
        if isAlphaStill { return .premultiplied }
        return stillImageURL == nil ? info?.alpha ?? .opaque : .opaque
    }
}

// MARK: - 时间线整体状态

/// 一份完整的时间线。撤销/重做就是整个换掉它，所以全部是值类型。
struct TimelineState: Hashable, Sendable {
    /// 主视频轨。数组顺序就是时间顺序；磁吸开着时位置由 `packMain` 排。
    var mainClips: [EditClip] = []
    /// 主轨的整轨隐藏（预览成黑场，导出跳过）。
    var mainHidden = false
    /// 主轨磁吸开没开。**跟着工程走**（2026-10-02 用户拍板，同剪映每个草稿各记各的）：进撤销栈、存进工程文件；老工程没这个键 = 关
    /// （打开工程永远不改工程），新建工程用上次拨的值。什么时候排 V1 见 `MainMagnet`。旧版丢掉这个键只丢开关、成片一帧不变，不开新版本。
    var mainMagnet = false
    /// 主轨的推子（主轨不是 `EditLane`，没地方放，同 `mainHidden`）。线性 0…2。
    var mainVolume = 1.0
    /// 总输出推子：所有轨混完之后再乘一次。线性 0…2。
    /// 推子两兄弟的合同见 docs/architecture/audio-mixer.md。
    var masterVolume = 1.0
    /// 上层视频轨（可以有多条，叠放顺序：靠后的画在上面）。
    /// 与主轨**对等** —— 内容一样铺满画面，只有叠放次序的差别。
    var overlayTracks: [EditLane] = []
    /// 音频轨（背景音乐、分离出的人声等）。
    var audioTracks: [EditLane] = []

    var subtitle: SubtitleDocumentModel?
    /// **原文**字幕轨的眼睛（与 mainHidden 同语义：预览不渲染、导出不烧录；
    /// 独立字幕文件导出不受影响 —— 那是对数据的显式操作，不是可见性）。
    var subtitleHidden = false
    /// **译文**字幕轨的眼睛。一个语言一条轨，各自一只眼睛：
    /// 两只都开=双语、只开一只=那一条、都关=不显示（也不烧录）。
    /// 译文轨不存在时这个值没有意义（UI 也不渲染那一行）。
    ///
    /// v7 字段：它决定成片里有没有译文，旧版丢掉它会改变导出画面。
    /// 读 v6 及更早的工程时**回退成 true** —— 那些版本的默认预览/烧录是
    /// 「只有原文」，升级不该把谁的成片悄悄变成双语（迁移在
    /// `VideoEditProjectIO.load`）。
    var translationHidden = false
    /// 原文字幕（以及叠在它下面的译文）在画面上的布局（预览拖框的产物，SrtFlowCore/SubtitleLayout）。
    /// nil = 全局烧录样式原样；预览和烧录共用同一份（`subtitleScreenBlocks`）。
    var subtitleLayout: SubtitleLayout?
    /// 译文字幕自己的布局（v23）。nil = 叠在原文下面、和原文排成一块；有值 = 各摆各的。
    var translationLayout: SubtitleLayout?
    /// 这个工程自己的字幕样式（v25，方案第 54 条：AI 改样式只改这一份）。nil = 跟全 App 的（烧录页记住的那套），
    /// 用的时候都问 `subtitleStyle(appWide:)`。
    var projectSubtitleStyle: BurnInStyle?
    /// 逐词高亮（v25，方案第 38 条）：正在说的那个词换色、放大。nil = 不高亮。只有带词时间的句子亮（SubtitleCueWords.swift）。
    var subtitleHighlight: SubtitleWordHighlight?
    /// 生成的字幕一条最多几行：1 或 2（`SubtitleSegmentationConfig.lineCountRange`）。**默认单行**（2026-10-16 用户定：默认都是单行，
    /// 除非用户在生成面板上调成两行、或者 AI 的 `max_lines=2` 要两行）。跟着工程走（进撤销栈、存进工程文件、缺键 = 1），
    /// 生成字幕和配音的字幕都按它切；已生成的不追溯重排。旧版丢掉这个键只丢开关、已有的字幕一行不变，不开新版本（同 `mainMagnet`）。
    var subtitleMaxLines = 1
    var subtitleURL: URL?
    /// 原文字幕的伴随状态（译文轨/cueMeta/生成参数）。原文永远在 `subtitle`；
    /// 这是 v4-only 字段（见 VideoEditFormatVersion.swift 的登记清单）。
    var subtitleCompanion: SubtitleCompanion?
    /// 画面上的形状标注。
    var shapes: [ShapeAnnotation] = []
    /// 画面上的文字标注。数组顺序就是叠放次序（靠后的画在上面）。
    /// 整体压在形状之上、字幕之下，见 docs/architecture/text-overlays.md。
    var textOverlays: [TextOverlay] = []
    /// 时间轴上的调色段。作用于自己那段时间里的**全部画面**（主轨 + 上层轨），
    /// 不染形状/文字/字幕。叠加顺序由 `FilterClip.layer` 决定，
    /// 见 docs/architecture/filters.md。
    /// 这是 v17-only 字段（见 VideoEditFormatVersion.swift 的登记清单）。
    var filters: [FilterClip] = []
    /// 标尺上的标记：锚在时间线的绝对时刻，不跟任何块走。读写见 VideoEditClipMarker.swift。v28 字段，按需写键。
    var rulerMarkers: [ClipMarker] = []
    /// 输出画面比例（预览和导出共用）。
    var canvasRatio: CanvasRatio = .auto
    /// 工程帧率：预览合成、两条导出管线、预渲染、关键帧容差的唯一事实来源。
    /// 这是 v5-only 字段（见 VideoEditFormatVersion.swift 的登记清单）。
    var frameRate: ProjectFrameRate = .fallback
    /// 公开故事/观察/声音计划，和剪辑共用撤销与普通自动保存；老工程缺键即 nil。
    var production: FilmProductionState?
    /// Reviewed delivery findings, preserved with the project and undo history.
    var deliveryIntentions: [DeliveryIntentionalMark] = []
    /// Explicit project ending, in timeline seconds. Zero follows the content; later content can extend beyond it.
    var minimumDuration = 0.0
    /// The editing style this film was cut with (v40, SS5 plan 5.5): a Sky Studio style keeps its version here. Nil until AI follows one.
    var editingStyle: EditingStyleRecord?

    /// Nothing the person made is in it: the one answer to "is this project empty?" (closing an untitled one asks only when
    /// it isn't; the start screen, Play and Export follow it too). Ruler markers and their notes, a translation track, review
    /// reasons and a pinned Sky Studio style version count; settings, switches and a style's source alone don't — the list
    /// and why: docs/architecture/video-edit-project-file.md §5 "What an empty project is".
    var isEmpty: Bool {
        mainClips.isEmpty && overlayTracks.allSatisfy(\.clips.isEmpty) && audioTracks.allSatisfy(\.clips.isEmpty)
            && subtitle == nil && subtitleCompanion?.translation == nil && shapes.isEmpty && textOverlays.isEmpty
            && filters.isEmpty && rulerMarkers.isEmpty && deliveryIntentions.isEmpty && editingStyle?.isPinned != true
            && production == nil && minimumDuration == 0
    }

    /// Content end, extended by the explicit ending when one is set.
    var duration: Double { TimelineDuration.end(self) }

    mutating func updateShape(_ id: UUID, _ change: (inout ShapeAnnotation) -> Void) {
        guard let index = shapes.firstIndex(where: { $0.id == id }) else { return }
        change(&shapes[index])
        // 正方形永远保持正方形。
        if shapes[index].kind.keepsSquare { shapes[index].height = shapes[index].width }
    }

    mutating func updateTextOverlay(_ id: UUID, _ change: (inout TextOverlay) -> Void) {
        guard let index = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        change(&textOverlays[index])
        // 收口放在这里而不是各个调用点：画面拖拽、检查器、就地编辑三条路
        // 都要落到同一份夹紧上，分开写迟早分叉。
        textOverlays[index].clampToValidRange()
    }

    // MARK: 主轨排列

    /// 磁吸：主轨各段首尾相接，有转场的地方按转场时长叠进去。
    mutating func packMain() {
        for (index, start) in Self.packedStarts(mainClips).enumerated() {
            mainClips[index].timelineStart = start
        }
    }

    /// 这组块首尾相接（转场按 xfade 的收紧规则叠掉）后各自的起点。
    ///
    /// **磁吸排列和拖动中的主轨插入指示线共用这一份**。指示线必须在「插入之后的
    /// 最终数组」上调它 —— 插进来的短块会改变相邻关系，能叠掉的量跟着变
    /// （45% 是按**两边**任一段收紧的），拿插入前的数组算出来的缝会说谎。
    static func packedStarts(_ clips: [EditClip]) -> [Double] {
        var starts: [Double] = []
        starts.reserveCapacity(clips.count)
        var cursor = 0.0
        for index in clips.indices {
            starts.append(cursor)
            cursor += clips[index].timelineDuration - transitionOverlap(in: clips, afterIndex: index)
        }
        return starts
    }

    /// The overlap settled in a render copy; on touching user clips this answers the native fade-suppression test.
    ///
    /// Packing uses the static overload below. Rendering must not apply that percentage to expanded clips again,
    /// otherwise a longer centred dissolve is shortened a second time and the exported timeline can grow.
    func transitionOverlap(afterMainIndex index: Int) -> Double {
        TransitionDurationLimit.overlap(in: mainClips, after: index)
    }

    /// 同上，但对任意一组「排成主轨」的块算 —— 拖动中的插入位置预览
    /// （`TimelineSnap.mainInsertion`）要在**去掉被拖块**的数组上重算一遍游标。
    /// 公式只有这一份：预览和 `packMain` 用同一个，才不会指示线在这、落点在那。
    static func transitionOverlap(in clips: [EditClip], afterIndex index: Int) -> Double {
        guard index >= 0, index + 1 < clips.count else { return 0 }
        let clip = clips[index]
        guard clip.transitionAfter != .none else { return 0 }
        return min(
            clip.transitionDuration,
            clip.timelineDuration * 0.45,
            clips[index + 1].timelineDuration * 0.45
        )
    }

    // MARK: 查找

    /// 所有轨的所有剪辑。
    var allClips: [EditClip] {
        mainClips + overlayTracks.flatMap(\.clips) + audioTracks.flatMap(\.clips)
    }

    func clip(with id: UUID) -> EditClip? {
        allClips.first { $0.id == id }
    }

    /// 这个剪辑在哪条轨上。
    func location(of id: UUID) -> ClipLocation? {
        if let index = mainClips.firstIndex(where: { $0.id == id }) {
            return ClipLocation(track: .main, clipIndex: index)
        }
        for (trackIndex, lane) in overlayTracks.enumerated() {
            if let index = lane.clips.firstIndex(where: { $0.id == id }) {
                return ClipLocation(track: .overlay(trackIndex), clipIndex: index)
            }
        }
        for (trackIndex, lane) in audioTracks.enumerated() {
            if let index = lane.clips.firstIndex(where: { $0.id == id }) {
                return ClipLocation(track: .audio(trackIndex), clipIndex: index)
            }
        }
        return nil
    }

    /// 这条轨隐藏了吗。
    func isLaneHidden(_ slot: TrackSlot) -> Bool {
        switch slot {
        case .main: return mainHidden
        case .overlay(let index):
            return overlayTracks.indices.contains(index) && overlayTracks[index].isHidden
        case .audio(let index):
            return audioTracks.indices.contains(index) && audioTracks[index].isHidden
        }
    }

    /// 链接组里的所有成员（含它自己）。
    func linkedClipIDs(of id: UUID) -> Set<UUID> {
        guard let clip = clip(with: id), let group = clip.linkGroup else { return [id] }
        return Set(allClips.filter { $0.linkGroup == group }.map(\.id)).union([id])
    }

    // MARK: 通用读写

    subscript(track track: TrackSlot) -> [EditClip] {
        get {
            switch track {
            case .main: return mainClips
            case .overlay(let index): return overlayTracks.indices.contains(index) ? overlayTracks[index].clips : []
            case .audio(let index): return audioTracks.indices.contains(index) ? audioTracks[index].clips : []
            }
        }
        set {
            switch track {
            case .main: mainClips = newValue
            case .overlay(let index): if overlayTracks.indices.contains(index) { overlayTracks[index].clips = newValue }
            case .audio(let index): if audioTracks.indices.contains(index) { audioTracks[index].clips = newValue }
            }
        }
    }

    mutating func update(_ id: UUID, _ change: (inout EditClip) -> Void) {
        guard let location = location(of: id) else { return }
        var clips = self[track: location.track]
        change(&clips[location.clipIndex])
        self[track: location.track] = clips
    }

    mutating func remove(_ id: UUID) {
        guard let location = location(of: id) else { return }
        var clips = self[track: location.track]
        clips.remove(at: location.clipIndex)
        self[track: location.track] = clips
        pruneEmptyTracks()
    }

    /// 清掉空出来的上层视频轨/音频轨，别让界面上留一排空槽。
    mutating func pruneEmptyTracks() {
        overlayTracks.removeAll { $0.clips.isEmpty }
        audioTracks.removeAll { $0.clips.isEmpty }
    }

    /// 把剪辑放进某类自由轨：塞进第一条放得下的（隐藏的不塞），
    /// 都放不下就新开一条。返回落进了哪条轨（the rule is `EditLane.place`）。
    mutating func place(_ clip: EditClip, intoAudio: Bool) -> Int {
        intoAudio ? EditLane.place(clip, in: &audioTracks) : EditLane.place(clip, in: &overlayTracks)
    }
}

// MARK: - 存盘（.srtflowproj）
//
// 工程文件是长期格式，读旧文件不能因为「多了/少了一个字段」就整份打不开，
// 所以这里全部手写宽容解码：缺的字段取默认值，不认识的枚举值退回兜底项。
// 有默认值的新字段可以随便加，老工程照样能开。

extension TimelineState: Codable {
    private enum CodingKeys: String, CodingKey {
        case minimumDuration
        case mainClips, mainHidden, overlayTracks, audioTracks
        case mainVolume, masterVolume
        case production, deliveryIntentions, editingStyle
        case subtitle, subtitleHidden, translationHidden
        case subtitleLayout, translationLayout, subtitleURL, subtitleCompanion, shapes, textOverlays, canvasRatio
        case frameRate, filters, projectSubtitleStyle, subtitleHighlight, rulerMarkers, mainMagnet, subtitleMaxLines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        minimumDuration = TimelineDuration.sanitized(try c.decodeIfPresent(Double.self, forKey: .minimumDuration) ?? 0)
        production = try c.decodeIfPresent(FilmProductionState.self, forKey: .production)
        deliveryIntentions = try c.decodeIfPresent([DeliveryIntentionalMark].self, forKey: .deliveryIntentions) ?? []
        editingStyle = try? c.decodeIfPresent(EditingStyleRecord.self, forKey: .editingStyle)   // v40; a record that does not read is dropped
        mainClips = try c.decodeIfPresent([EditClip].self, forKey: .mainClips) ?? []
        mainHidden = try c.decodeIfPresent(Bool.self, forKey: .mainHidden) ?? false
        mainMagnet = try c.decodeIfPresent(Bool.self, forKey: .mainMagnet) ?? false   // 2026-10-02 起才有：缺键 = 关
        // v19 起才有。缺键 = 推子在 0 dB（老版本根本没有推子）。
        mainVolume = AudioGain.clampedLinear(try c.decodeIfPresent(Double.self, forKey: .mainVolume) ?? 1)
        masterVolume = AudioGain.clampedLinear(try c.decodeIfPresent(Double.self, forKey: .masterVolume) ?? 1)
        overlayTracks = try c.decodeIfPresent([EditLane].self, forKey: .overlayTracks) ?? []
        audioTracks = try c.decodeIfPresent([EditLane].self, forKey: .audioTracks) ?? []
        subtitle = try c.decodeIfPresent(SubtitleDocumentModel.self, forKey: .subtitle)
        subtitleHidden = try c.decodeIfPresent(Bool.self, forKey: .subtitleHidden) ?? false
        translationHidden = try c.decodeIfPresent(Bool.self, forKey: .translationHidden) ?? false
        subtitleLayout = try c.decodeIfPresent(SubtitleLayout.self, forKey: .subtitleLayout)
        translationLayout = try c.decodeIfPresent(SubtitleLayout.self, forKey: .translationLayout)
        projectSubtitleStyle = try c.decodeIfPresent(BurnInStyle.self, forKey: .projectSubtitleStyle)
        subtitleHighlight = try c.decodeIfPresent(SubtitleWordHighlight.self, forKey: .subtitleHighlight)
        subtitleMaxLines = SubtitleSegmentationConfig.clampedLineCount(try c.decodeIfPresent(Int.self, forKey: .subtitleMaxLines) ?? 1)   // 2026-10-16 起才有：缺键 = 单行
        subtitleURL = try c.decodeIfPresent(URL.self, forKey: .subtitleURL)
        subtitleCompanion = try c.decodeIfPresent(SubtitleCompanion.self, forKey: .subtitleCompanion)
        shapes = try c.decodeIfPresent([ShapeAnnotation].self, forKey: .shapes) ?? []
        // v11 起才有。缺键 = 这个工程没有文字，不是出错。
        textOverlays = try c.decodeIfPresent([TextOverlay].self, forKey: .textOverlays) ?? []
        // v17 起才有。缺键 = 这个工程没有调色段，不是出错。
        filters = try c.decodeIfPresent([FilterClip].self, forKey: .filters) ?? []
        rulerMarkers = try c.decodeIfPresent([ClipMarker].self, forKey: .rulerMarkers) ?? []   // v28 起才有
        canvasRatio = try c.decodeIfPresent(CanvasRatio.self, forKey: .canvasRatio) ?? .auto
        // v1–v4 没有这个字段，缺失即回退 24（与 ProjectFrameRate.fallback 一致）。
        frameRate = try c.decodeIfPresent(ProjectFrameRate.self, forKey: .frameRate) ?? .fallback
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(production, forKey: .production)
        if minimumDuration > 0 { try c.encode(minimumDuration, forKey: .minimumDuration) }
        if !deliveryIntentions.isEmpty { try c.encode(deliveryIntentions, forKey: .deliveryIntentions) }
        try c.encodeIfPresent(editingStyle, forKey: .editingStyle)
        try c.encode(mainClips, forKey: .mainClips)
        try c.encode(mainHidden, forKey: .mainHidden)
        if mainMagnet { try c.encode(true, forKey: .mainMagnet) }   // 按需写键：磁吸关着的工程存一轮 diff 是空的
        // 推子没动过（0 dB）不写键，与 `requiresFormatVersion19` 同源。
        if mainVolume != 1 { try c.encode(mainVolume, forKey: .mainVolume) }
        if masterVolume != 1 { try c.encode(masterVolume, forKey: .masterVolume) }
        try c.encode(overlayTracks, forKey: .overlayTracks)
        try c.encode(audioTracks, forKey: .audioTracks)
        try c.encodeIfPresent(subtitle, forKey: .subtitle)
        try c.encode(subtitleHidden, forKey: .subtitleHidden)
        try c.encode(translationHidden, forKey: .translationHidden)
        try c.encodeIfPresent(subtitleLayout, forKey: .subtitleLayout)
        try c.encodeIfPresent(translationLayout, forKey: .translationLayout)
        try c.encodeIfPresent(projectSubtitleStyle, forKey: .projectSubtitleStyle)
        try c.encodeIfPresent(subtitleHighlight, forKey: .subtitleHighlight)
        if subtitleMaxLines != 1 { try c.encode(subtitleMaxLines, forKey: .subtitleMaxLines) }   // 按需写键：单行（默认）不落键
        try c.encodeIfPresent(subtitleURL, forKey: .subtitleURL)
        // 空 companion 不落盘：否则一个从未用过新功能的工程也会被抬进 v4。
        if subtitleCompanion?.hasPersistentData == true {
            try c.encodeIfPresent(subtitleCompanion, forKey: .subtitleCompanion)
        }
        try c.encode(shapes, forKey: .shapes)
        // 空数组不落盘：一个从没用过文字的工程不该因此被抬进 v11
        //（判据见 VideoEditFormatVersion.swift 的登记清单）。
        if !textOverlays.isEmpty { try c.encode(textOverlays, forKey: .textOverlays) }
        // 同上：没用过滤镜的工程不该被抬进 v17，旧版照样能开。
        if !filters.isEmpty { try c.encode(filters, forKey: .filters) }
        if !rulerMarkers.isEmpty { try c.encode(rulerMarkers, forKey: .rulerMarkers) }   // 同上：v28
        try c.encode(canvasRatio, forKey: .canvasRatio)
        // **无条件**写帧率：旧版把帧率硬编码成 30，省略这个键会让默认 24 的
        // 工程在旧版里按 30 渲染（见 VideoEditFormatVersion 的说明）。
        try c.encode(frameRate, forKey: .frameRate)
    }
}

