import Foundation
import SrtFlowCore

// 一条上层视频轨或音频轨（`EditLane`）。2026-10-16 从 VideoEditModels.swift 拆出来（那个文件只许降不许涨）。
//
// 管什么：轨的身份、段、整轨隐藏、颜色号、轨道头推子，以及它怎么存盘（缺键的默认值）。
// 不管什么：主轨（`TimelineState.mainClips`，主轨不是 EditLane）、轨道的增删和颜色补号（TimelineState）。

/// 一条上层视频轨或音频轨：有身份（行的增删不串号）、可整轨隐藏、有自己的颜色。
struct EditLane: Identifiable, Hashable, Sendable {
    let id: UUID
    var clips: [EditClip]
    /// 隐藏的轨：灰显不可编辑，预览和导出都当它不存在。
    var isHidden: Bool
    /// 这条轨在时间线上的颜色号（见 TrackPalette）。
    ///
    /// nil = 还没补号：新 append 出来的轨、以及 2026-09-17 之前存的老工程。
    /// `assignMissingTrackColors()` 会在读盘和每次状态提交后补上，补过就不再动
    /// —— 颜色必须绑轨道身份，绑行号的话删掉中间一条轨会让下面所有轨换色。
    var colorIndex: Int?
    /// 轨道头推子：整条轨的音量（线性幅度 0…2，1 = 0 dB），乘在每段自己的
    /// 音量 / 曲线之上。见 docs/architecture/audio-mixer.md。
    var volume: Double

    init(
        id: UUID = UUID(), clips: [EditClip] = [], isHidden: Bool = false,
        colorIndex: Int? = nil, volume: Double = 1
    ) {
        self.id = id
        self.clips = clips
        self.isHidden = isHidden
        self.colorIndex = colorIndex
        self.volume = volume
    }
}

extension EditLane: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, clips, isHidden, colorIndex, volume
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            clips: try c.decodeIfPresent([EditClip].self, forKey: .clips) ?? [],
            isHidden: try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false,
            colorIndex: try c.decodeIfPresent(Int.self, forKey: .colorIndex),
            // v19 起才有。缺键 = 推子在 0 dB，就是老版本的声音。
            volume: AudioGain.clampedLinear(try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(clips, forKey: .clips)
        try c.encode(isHidden, forKey: .isHidden)
        try c.encodeIfPresent(colorIndex, forKey: .colorIndex)
        // 推子没动过（0 dB）不写键，与 `requiresFormatVersion19` 同源。
        if volume != 1 { try c.encode(volume, forKey: .volume) }
    }
}
