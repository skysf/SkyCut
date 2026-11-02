import CoreGraphics
import Foundation

// 精确区域只扩展既有 crop 数值；存盘、复制、分割和撤销快照均沿用原有 Codable。
func checkSourceRegions(_ root: URL) throws {
    let folder = root.appendingPathComponent("regions")
    let media = folder.appendingPathComponent("screen.mp4")
    makeFile(media)
    let file = folder.appendingPathComponent("region.skycut")
    var state = TimelineState()
    var clip = EditClip(sourceURL: media, sourceDuration: 2, timelineStart: 0)
    clip.crop = ClipCrop(keeping: CGRect(x: 0.91, y: 0.92, width: 0.09, height: 0.08))
    state.mainClips = [clip]
    check(state.requiresFormatVersion33, "超过旧裁切边界必须登记 v33")
    check(!TimelineState().requiresFormatVersion33, "没有精确区域不是 v33-only 数据")
    try VideoEditProjectIO.save(state, to: file)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    checkEqual(raw["formatVersion"] as? Int, 33, "reader / writer 必须升到 v33，旧版不得夹坏精确区域")
    let loaded = try VideoEditProjectIO.load(from: file)
    checkEqual(loaded.timeline.mainClips[0].crop, clip.crop, "四边大于 45% 的裁切存盘读回逐值不变")
    checkEqual(loaded.timeline.mainClips[0].id, clip.id, "精确区域不改片段身份")
    let old = folder.appendingPathComponent("old.skycut")
    try Data(#"{"formatVersion":32,"timeline":{"mainClips":[]},"media":[]}"#.utf8).write(to: old)
    checkEqual(try VideoEditProjectIO.load(from: old).timeline.mainClips.count, 0, "v32 及更早的工程照常可开")
    let crop = try JSONDecoder().decode(ClipCrop.self, from: Data(#"{"top":0.1,"leading":0.2}"#.utf8))
    checkEqual(crop, ClipCrop(top: 0.1, leading: 0.2), "旧四边裁切缺键继续用零值")
    let broken = try JSONDecoder().decode(ClipCrop.self, from: Data(#"{"leading":0.9,"trailing":0.9}"#.utf8))
    checkEqual(broken, ClipCrop(leading: 0.9, trailing: 0.9), "旧损坏数据仍用宽容夹紧，不出现负矩形")
    state.mainClips[0].crop = ClipCrop(leading: 0.0001)
    check(state.requiresFormatVersion33, "源像素级的小边界也属于 v33 精确语义")
    try VideoEditProjectIO.save(state, to: file)
    checkEqual(try VideoEditProjectIO.load(from: file).timeline.mainClips[0].crop, state.mainClips[0].crop, "v33 不把小裁切误判为空")
    var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    legacy["formatVersion"] = 32
    try JSONSerialization.data(withJSONObject: legacy).write(to: old)
    checkEqual(try VideoEditProjectIO.load(from: old).timeline.mainClips[0].crop, nil, "v32 以前忽略的小边界迁移成无裁切，升级不改成片")
}
