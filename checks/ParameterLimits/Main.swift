import AppKit
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 完整 App 验证：失败请求零修改，单项 / 批量同一限制，转换与探测真实重试，成功反馈与最终工程相符。
@main enum ParameterLimitAppChecks {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.parameterlimitscheck"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("Isolated bundle required") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_PARAMETER_CHECK_DIR"]!).resolvingSymlinksInPath()
        let ffmpeg = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]!)
        var count = 0, failures = 0
        func require(_ condition: Bool, _ message: String) {
            count += 1
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        do {
            MediaToolchain.shared.resolveIfNeeded()
            for _ in 0..<100 where MediaToolchain.shared.runtime == nil { try await Task.sleep(nanoseconds: 100_000_000) }
            guard MediaToolchain.shared.runtime != nil else { throw AIToolError("Native video engine is required; never skip conversion checks") }
            var info = try await MediaProbe.probe(url: root.appendingPathComponent("source.mp4"), ffmpeg: ffmpeg).get()
            info.keyframeInterval = 0
            let f = try ParameterFixture(folder: root.appendingPathComponent("project"), source: root.appendingPathComponent("source.mp4"), info: info)
            defer { _ = OpenProjects.shared.close(f.project) }
            for fields: [String: JSONValue] in [["speed": 9], ["source_out": 10], ["crop": ["left": 0.5]], ["scale": 8], ["x": -3], ["y": 4], ["start": -1]] {
                let rebuild = f.rebuild
                do {
                    var fields = fields
                    fields["opacity"] = 0.25
                    _ = try await f.edit(fields)
                    require(false, "invalid request must fail: \(fields)")
                } catch let error as AIToolError {
                    require(error.details["status"] == "invalid_parameter" && error.details["suggested"] != nil,
                            "invalid request returns range and suggestion")
                }
                if f.project.state != f.before || f.project.effectiveUndoManager!.canUndo || f.rebuild != rebuild {
                    print("FAILED ATOMIC: \(fields), equal=\(f.project.state == f.before), undo=\(f.project.effectiveUndoManager!.canUndo), rebuild=\(rebuild)->\(f.rebuild)")
                }
                require(f.project.state == f.before && !f.project.effectiveUndoManager!.canUndo && f.rebuild == rebuild,
                        "invalid request leaves no partial opacity, undo or preview rebuild")
            }
            print("PASS: invalid multi-parameter edits leave the real project untouched")
            for fields: [String: JSONValue] in [["speed": .number(TimelineTrim.clipSpeedRange.lowerBound)],
                                               ["speed": .number(TimelineTrim.clipSpeedRange.upperBound)], ["speed": 1.5],
                                               ["source_out": .number(TimelineTrim.clipMinimumDuration)], ["source_out": 1.5],
                                               ["crop": ["top": .number(ClipCrop.maximumManualInset)]], ["crop": ["right": 0.1]],
                                               ["scale": .number(MCPFramingLimits.scale.lowerBound)], ["scale": .number(MCPFramingLimits.scale.upperBound)], ["scale": 1.5]] {
                f.reset()
                let rebuild = f.rebuild
                let result = try await f.edit(fields)
                let clip = f.project.state.clip(with: f.id)!
                require(result.changedProject && f.rebuild == rebuild + 1, "normal / boundary request commits and schedules once")
                if let speed = fields["speed"] { require(result.payload["applied"]?["speed"] == speed && clip.speed == speed.doubleValue, "speed feedback equals actual timeline") }
                f.project.effectiveUndoManager!.undo()
                require(f.project.state == f.before && !f.project.effectiveUndoManager!.canUndo, "one undo restores boundary edit")
            }
            f.reset()
            let gain = try await f.edit(["volume_db": 8.1, "fade_in": 2, "fade_out": 2])
            let clip = f.project.state.clip(with: f.id)!
            require(gain.payload["requested"]?["volume_db"] == 8.1, "gain request retained")
            require(gain.payload["applied"]?["volume_db"]?.doubleValue == clip.volumeLineDecibels(atTimeline: 0)
                    && clip.volume == 2, "gain limit read back from real model without rounding")
            require(gain.payload["applied"]?["fade_in"]?.doubleValue == clip.audioFades.fadeIn
                    && (gain.payload["adjustments"]?.arrayValue?.count ?? 0) == 3, "effective fades and gain adjustments reported")
            f.reset()
            let id = JSONValue.string(AIShortIDs(state: f.project.state).short(f.id))
            let rebuild = f.rebuild
            do {
                _ = try await AIBatchEditTools.planClips(AIToolArguments(["clips": [["clip_id": id, "start": 2], ["clip_id": id, "speed": 9]]]), f.project)
                require(false, "invalid last batch item must reject")
            } catch let error as AIToolError {
                require(error.details["status"] == "invalid_parameter" && error.details["index"] == 1 && error.details["allowed"] != nil,
                        "batch uses the same typed range error and retains index")
            }
            require(f.project.state == f.before && !f.project.effectiveUndoManager!.canUndo && f.rebuild == rebuild, "bad batch commits zero times")
            let plan = try await AIBatchEditTools.planClips(AIToolArguments(["clips": [["clip_id": id, "volume_db": 8.1], ["clip_id": id, "opacity": 2]]]), f.project)
            let batch = try AIBatchEditTools.applyClips(plan, f.project)
            require(f.rebuild == rebuild + 1 && batch.payload["clips"]?.arrayValue?.count == 2, "valid batch commits once")
            require(batch.payload["clips"]?.arrayValue?.first?["applied"]?["volume_db"]?.doubleValue == AudioGain.maximumDB,
                    "single and batch gain feedback agree")
            f.project.effectiveUndoManager!.undo()
            require(f.project.state == f.before && !f.project.effectiveUndoManager!.canUndo, "one undo restores entire batch")
            print("PASS: shared single / batch limits and actual gain/fade feedback")

            // 缺元数据必须真实探测；失败后没有把探到的 info 或别的参数留进时间线。
            var unknown = f.before
            unknown.mainClips[0].info = nil
            f.reset(unknown)
            do { _ = try await f.edit(["fit": "fit", "source_out": 10]); require(false, "bad window after successful probe must fail") }
            catch let error as AIToolError { require(error.details["status"] == "invalid_parameter", "probe success still validates whole edit") }
            if f.project.state != unknown || f.project.effectiveUndoManager!.canUndo {
                print("PROBE ATOMIC: equal=\(f.project.state == unknown), undo=\(f.project.effectiveUndoManager!.canUndo), info=\(f.project.state.mainClips[0].info != nil)")
            }
            require(f.project.state == unknown && !f.project.effectiveUndoManager!.canUndo, "metadata is staged with edit, never applied alone")
            let probed = try await f.edit(["fit": "fit"])
            require(probed.changedProject && f.project.state.mainClips[0].info != nil, "missing dimensions can be loaded by production probe and edited")
            f.reset()

            // 真正的同步关键帧入口：新路径未进缓存，第一次返回在途；等探测完成后按同参数重试。
            let keyFile = root.appendingPathComponent("keyframe.mp4")
            try FileManager.default.copyItem(at: root.appendingPathComponent("source.mp4"), to: keyFile)
            var keyState = f.before
            keyState.mainClips[0].sourceURL = keyFile
            keyState.mainClips[0].info = nil
            f.reset(keyState)
            let keyArgs = f.arguments(["relative": true, "scale": [["time": 0, "value": 0.001], ["time": 1, "value": 10]]])
            do { _ = try AITimelineTools.setKeyframes(keyArgs, f.project); require(false, "unloaded metadata starts a real probe") }
            catch let error as AIToolError { require(error.details["status"] == "media_loading" && error.details["retryable"] == true, "keyframe loading is retryable") }
            require(f.project.state == keyState && !f.project.effectiveUndoManager!.canUndo, "keyframe loading does not edit project")
            _ = await f.project.mediaProbes.probeVideo(keyFile)
            let keyResult = try AITimelineTools.setKeyframes(keyArgs, f.project)
            require(keyResult.payload["applied"]?["scale"]?.arrayValue?.last?["value"]?.doubleValue == MCPFramingLimits.keyframeScale.upperBound,
                    "retry consumes real cached dimensions and reports native keyframe clamp")
            f.project.effectiveUndoManager!.undo()
            require(f.project.state == keyState, "keyframe metadata adoption and animation undo together")

            var missing = f.before
            missing.mainClips[0].sourceURL = root.appendingPathComponent("missing.mp4")
            missing.mainClips[0].info = nil
            f.reset(missing)
            do { _ = try await f.edit(["fit": "fit"]); require(false, "missing source fails") }
            catch let error as AIToolError { require(error.details["status"] == "media_unavailable" && error.details["retryable"] == false, "missing source is not endless loading") }
            let brokenFile = root.appendingPathComponent("unsupported.mp4")
            try Data("unsupported media, not a real clip".utf8).write(to: brokenFile)
            var unsupported = missing
            unsupported.mainClips[0].sourceURL = brokenFile
            f.reset(unsupported)
            do { _ = try await f.edit(["fit": "fit"]); require(false, "failed real probe must fail edit") }
            catch let error as AIToolError {
                require(error.details["status"] == "media_unavailable" && error.details["reason"] == "metadata_probe_failed"
                        && error.details["retryable"] == false, "completed probe failure differs from in-flight probe")
            }
            require(f.project.state == unsupported && !f.project.effectiveUndoManager!.canUndo, "probe failure leaves project untouched")

            // 图片刚落轨还在转：先返回 loading，源窗口无需尺寸可以编辑，实际转换后相同取景可重试成功。
            var imageState = f.before
            imageState.mainClips[0].sourceURL = root.appendingPathComponent("image.png")
            imageState.mainClips[0].stillImageURL = root.appendingPathComponent("image.png")
            imageState.mainClips[0].info = nil
            imageState.mainClips[0].needsStillConversion = true
            f.reset(imageState)
            do { _ = try await f.edit(["fit": "fit", "start": 2]); require(false, "pending image framing waits") }
            catch let error as AIToolError {
                require(error.details["status"] == "media_loading" && error.details["retryable"] == true && error.details["retry_after_ms"] != nil,
                        "pending image returns explicit retry status")
            }
            require(f.project.state == imageState && !f.project.effectiveUndoManager!.canUndo, "pending image does not partly move clip")
            do { _ = try await f.edit(["source_out": .number(StillImageClipFactory.stillDuration + 1)]); require(false, "long image must not truncate") }
            catch let error as AIToolError { require(error.details["status"] == "invalid_parameter", "image loop limit rejected") }
            let longest = try await f.edit(["source_out": .number(StillImageClipFactory.stillDuration)])
            require(longest.payload["applied"]?["source_out"]?.doubleValue == StillImageClipFactory.stillDuration, "valid duration can edit pending image without dimensions")
            f.reset(imageState)
            await f.project.convertStillClip(f.id, from: root.appendingPathComponent("image.png"), generation: f.project.documentGeneration)
            require(f.project.state.clip(with: f.id)?.needsStillConversion == false && f.project.state.clip(with: f.id)?.info != nil, "real still conversion supplies dimensions")
            let converted = f.project.state
            f.project.effectiveUndoManager!.removeAllActions()
            let retry = try await f.edit(["fit": "fit", "start": 2])
            require(!retry.isError && f.project.state.clip(with: f.id)?.timelineStart == 2, "identical framing succeeds after conversion")
            f.project.effectiveUndoManager!.undo()
            require(f.project.state == converted, "converted-image edit undoes once")
            print("PASS: real pending image / video probe / unavailable media / metadata rollback")
        } catch {
            failures += 1
            print("FAIL: production parameter check threw \(error)")
        }
        print("Parameter limits: \(count) assertions, \(failures) failures")
        UserDefaults.standard.removePersistentDomain(forName: domain)
        exit(failures == 0 ? 0 : 1)
    }
}
