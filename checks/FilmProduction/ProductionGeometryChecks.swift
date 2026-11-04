import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 按需制作回读的精确源几何：只测实际模型/JSON 值，不能把请求时间说成 native actualTime。
func runProductionGeometryChecks(root: URL) throws {
    var state = TimelineState()
    state.frameRate = .fps24
    var clip = EditClip(sourceURL: root.appendingPathComponent("not-opened.mp4"),
                        sourceDuration: 1.234567891, timelineStart: 2.0009001)
    clip.sourceStart = 0.123456789
    clip.speed = 1.37
    let geometry = AIFilmProductionSummary.sourceGeometry(clip, state: state)
    let value = try JSONDecoder().decode(JSONValue.self, from: geometry.encodedData())
    check(value == geometry, "exact source geometry survives public JSON roundtrip")
    check(value["source_in"] == .number(clip.sourceStart) && value["source_duration"] == .number(clip.sourceDuration),
          "fractional source start/duration are not rounded for scratch reproduction")
    check(value["speed"] == .number(clip.speed) && value["timeline_start"] == .number(clip.timelineStart),
          "fractional speed and absolute placement retain their source time mapping")
    let original = AIFilmProductionReadiness.window(clip, state: state)
    let rebuilt = AIFilmProductionSamples.UsedWindow(sourceStart: value["source_in"]!.doubleValue!,
        sourceDuration: value["source_duration"]!.doubleValue!, speed: value["speed"]!.doubleValue!,
        timelineStart: value["timeline_start"]!.doubleValue!, fps: Int(value["fps"]!.doubleValue!))
    check(value["first_project_time"] == original.projectBounds.map { .number($0.lowerBound) }
          && value["last_project_time"] == original.projectBounds.map { .number($0.upperBound) },
          "readback first/last use the same absolute project-grid helper")
    check(rebuilt.projectBounds == original.projectBounds
          && rebuilt.sourceTime(rebuilt.projectBounds!.upperBound) == original.sourceTime(original.projectBounds!.upperBound),
          "fractional speed source time reconstructs exactly from public geometry")
    clip.sourceStart = 0.5
    clip.sourceDuration = 1.0.nextDown
    let ulp = AIFilmProductionSummary.sourceGeometry(clip, state: state)
    check(ulp["source_duration"] == .number(1.0.nextDown)
          && ulp["source_out"]!.doubleValue! - ulp["source_in"]!.doubleValue! != clip.sourceDuration,
          "one-ULP stored duration is preserved even when in/out cannot reconstruct it exactly")
    clip.timelineStart = 0.001
    clip.sourceDuration = 0.001
    let short = AIFilmProductionSummary.sourceGeometry(clip, state: state)
    check(short["first_project_time"] == .null && short["last_project_time"] == .null,
          "a used window without a project-grid position does not invent an anchor request")
    clip.stillImageURL = root.appendingPathComponent("not-opened.png")
    check(AIFilmProductionSummary.sourceGeometry(clip, state: state) == .null,
          "native video anchor guidance is absent for a still image")
}
