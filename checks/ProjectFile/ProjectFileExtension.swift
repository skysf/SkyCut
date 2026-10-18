import Foundation
import SrtFlowCore

// 第 47 组：工程文件的后缀（2026-10-18 改名 SkyCut）。新存的用 `.skycut`，改名之前的 `.srtflowproj` 照样认；
// 认不认得一个文件是工程只问 `VideoEditProjectFile.isProjectFile`（docs/architecture/product-name.md）。
// 内容和格式版本不变，只是换了后缀：同一份工程存成 .skycut 读回来一模一样。编法见 scripts/check-project-file.sh。

func checkProjectFileExtension(root: URL) throws {
    checkEqual(VideoEditProjectFile.fileExtension, "skycut", "新存的工程用 .skycut")
    for name in ["Trip.skycut", "Trip.SKYCUT", "Trip.srtflowproj", "Trip.SrtFlowProj"] {
        check(VideoEditProjectFile.isProjectFile(URL(fileURLWithPath: "/tmp/\(name)")), "\(name) 认作工程（不分大小写）")
    }
    for name in ["Trip.json", "Trip.skycut.mp4", "skycut", "Trip.mp4"] {
        check(!VideoEditProjectFile.isProjectFile(URL(fileURLWithPath: "/tmp/\(name)")), "\(name) 不是工程")
    }

    let folder = root.appendingPathComponent("extension")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var state = TimelineState()
    state.subtitleMaxLines = 2
    let current = folder.appendingPathComponent("p.\(VideoEditProjectFile.fileExtension)")
    let legacy = folder.appendingPathComponent("p.\(VideoEditProjectFile.legacyFileExtension)")
    try VideoEditProjectIO.save(state, to: current)
    try VideoEditProjectIO.save(state, to: legacy)
    checkEqual(try VideoEditProjectIO.load(from: current).timeline.subtitleMaxLines, 2, ".skycut 存了读得回来")
    checkEqual(try VideoEditProjectIO.load(from: legacy).timeline.subtitleMaxLines, 2, ".srtflowproj 照样读得回来")
    let currentJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: current)) as? [String: Any]
    let legacyJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: legacy)) as? [String: Any]
    checkEqual(currentJSON?["formatVersion"] as? Int, legacyJSON?["formatVersion"] as? Int, "换后缀不换格式版本")
}
