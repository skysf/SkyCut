import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 3. listen mix=true 的参数和结果：层怎么分、越界给合法建议、逐帧的数放得下才给、结果里该有的都在、清单的定义对得上。

/// V1（主轨自己的声音）、V2（上层轨）、A1、A2 出声；A3 整轨藏起来（有这条轨、不在混音里）。60 秒。
private func fourTrackState() -> TimelineState {
    let tone = sineWAV("plan-tone.wav", frequency: 440, amplitude: 0.1, seconds: 60)
    var state = baseState()
    state.mainClips = [pictureClip(tone, at: 0, duration: 60)]
    state.overlayTracks = [EditLane(clips: [pictureClip(tone, at: 0, duration: 60)])]
    var hidden = EditLane(clips: [audioClip(tone, at: 0, duration: 60)])
    hidden.isHidden = true
    state.audioTracks = [EditLane(clips: [audioClip(tone, at: 0, duration: 60)]), EditLane(clips: [audioClip(tone, at: 0, duration: 60)]), hidden]
    return state
}

private func plan(_ state: TimelineState, _ arguments: JSONValue, from: Double? = nil, to: Double? = nil) -> Result<AIListenMixPlan, AIToolError> {
    let config = AudioEngineConfig.make(from: state, measuringSceneCompensation: false)
    do {
        return .success(try AIListenMixPlan.make(AIToolArguments(arguments), state: state, config: config, from: from, to: to,
                                                 silenceDB: -45, minSilence: 0.5))
    } catch let error as AIToolError {
        return .failure(error)
    } catch {
        return .failure(AIToolError("\(error)"))
    }
}

private func layerNames(_ result: Result<AIListenMixPlan, AIToolError>) -> [String] {
    (try? result.get())?.layers.map(\.name) ?? []
}

private func message(_ result: Result<AIListenMixPlan, AIToolError>) -> String {
    if case .failure(let error) = result { return error.message }
    return ""
}

func checkPlan() {
    group("3a. 层怎么分、越界怎么说")
    let state = fourTrackState()
    let defaults = plan(state, ["mix": true])
    check(layerNames(defaults) == ["V1", "V2", "A1", "A2"], "不给 layers：每条出声的轨一层，主轨叫 V1（得到 \(layerNames(defaults))）")
    let restPlan = plan(state, ["mix": true, "layers": ["a1", "rest"]])
    check(layerNames(restPlan) == ["A1", "rest"] && (try? restPlan.get())?.layers.last?.tracks == [0, 1, 3],
          "A1 + rest：rest 是其余出声的轨（得到 \(String(describing: (try? restPlan.get())?.layers.map(\.tracks))))")
    let joined = plan(state, ["mix": true, "layers": ["main + v2", "A2"]])
    check(layerNames(joined) == ["V1+V2", "A2"] && (try? joined.get())?.layers.first?.tracks == [0, 1],
          "main 当 V1、+ 连起来的是一层（得到 \(layerNames(joined))）")
    check(message(plan(state, ["mix": true, "layers": ["A3"]])).contains("makes no sound"),
          "藏起来的 A3：说它不在混音里（\(message(plan(state, ["mix": true, "layers": ["A3"]]))))")
    check(message(plan(state, ["mix": true, "layers": ["A9"]])).contains("There is no track A9"), "没有的轨：说没有，列出在混音里的")
    check(message(plan(state, ["mix": true, "layers": ["A1", "A1+A2"]])).contains("more than one layer"), "同一条轨进了两层：拒绝")
    check(message(plan(state, ["mix": true, "layers": ["rest", "rest"]])).contains("rest stands alone"), "rest 写了两次：拒绝")
    check(message(plan(state, ["mix": true, "layers": ["A1+rest"]])).contains("rest stands alone"), "rest 和别的轨连在一起：拒绝")
    check(message(plan(state, ["mix": true, "layers": ["V1", "V2", "A1", "A2", "rest"]])).contains("rest has nothing left"),
          "全点名了还写 rest：说 rest 是空的")
    let thirteen: JSONValue = .array((0..<13).map { _ in "A1" })
    check(message(plan(state, ["mix": true, "layers": thirteen])).contains("at most \(AIListenMixPlan.maxLayers)"), "超过 12 层：拒绝")
    // 范围：按工程帧率落在帧上；from 过了结尾给合法的值。
    let window = plan(state, ["mix": true], from: 70.0 / 7, to: 76.0 / 7)
    check((try? window.get())?.frames == 240 ..< 261, "10.000–10.857 秒：第 240..<261 帧（得到 \(String(describing: (try? window.get())?.frames)))")
    if case .failure(let error) = plan(state, ["mix": true], from: 61) {
        check(error.details["status"]?.stringValue == "invalid_parameter" && error.details["parameter"]?.stringValue == "from"
              && error.details["suggested"]?.doubleValue == 59.958,
              "from 过了结尾：invalid_parameter，建议最后一帧的帧头 59.958（\(error.details))")
    } else { check(false, "from 过了结尾没有拒绝") }
    // 逐帧的数：4 层每帧 24 个，2400 个放得下 100 帧（4.167 秒）；放不下就拒绝、建议一个放得下的 to。
    if case .failure(let error) = plan(state, ["mix": true, "frames": true], from: 10, to: 20) {
        check(error.details["parameter"]?.stringValue == "to" && error.details["suggested"]?.doubleValue == 14.166,
              "frames=true 放不下：建议 to = 14.166（\(error.details["suggested"] ?? .null)）")
        check(error.message.contains("name fewer layers"), "还说可以少要几层")
    } else { check(false, "frames=true 要 10 秒没有拒绝") }
    let fits = plan(state, ["mix": true, "frames": true, "layers": ["A1"]], from: 10, to: 20)
    check((try? fits.get())?.perFrame == true, "只要一层（每帧 9 个）：10 秒 240 帧放得下（\(message(fits))）")
    // 只有 mix 才认 layers / frames 的话在 AIListenTool 里；清单的定义：三个参数都在、layers 最多 12 条（和计划同一个数）。
    let schema = MCPToolName.listen.definition.inputSchema
    check(["mix", "layers", "frames"].allSatisfy { schema["properties"]?[$0] != nil }, "listen 的清单里有 mix、layers、frames")
    check(schema["properties"]?["layers"]?["maxItems"]?.intValue == AIListenMixPlan.maxLayers,
          "清单里 layers 最多 \(AIListenMixPlan.maxLayers) 条，和计划的上限同一个数")
}

func checkReport() {
    group("3b. 写给 AI 的结果：摘要都在，逐帧的数长度对、条数在上限之内")
    let state = fourTrackState()
    guard case .success(let mixPlan) = plan(state, ["mix": true, "frames": true, "layers": ["A1", "rest"]], from: 2, to: 4)
    else { check(false, "计划没做成"); return }
    let config = AudioEngineConfig.make(from: state)
    guard let result = try? MixMeasurement.measure(.init(config: config, layers: mixPlan.layers, grid: mixPlan.grid, frames: mixPlan.frames))
    else { check(false, "没量出来"); return }
    let report = AIListenMixReport.json(result, plan: mixPlan)
    let mix = report["mix"]?.objectValue ?? [:]
    for key in ["from", "to", "frame_rate", "loudness_lufs", "max_momentary", "level_db", "peak_db", "peak_at", "loudest_at", "over",
                "output_peak_db", "curve"] {
        check(mix[key] != nil, "mix 里有 \(key)")
    }
    let layers = report["layers"]?.arrayValue ?? []
    check(layers.count == 2 && layers.first?["name"]?.stringValue == "A1", "两层：A1、rest")
    for key in ["level_db", "loudness_lufs", "peak_db", "loudest_at", "bands_db"] {
        check(layers.allSatisfy { $0[key] != nil }, "每层都有 \(key)")
    }
    let bands = layers.first?["bands_db"]?.objectValue ?? [:]
    check(Set(bands.keys) == ["low", "low_mid", "high_mid", "high"], "频段四个名字：low、low_mid、high_mid、high")
    check((bands["low_mid"]?.doubleValue ?? -99) > (bands["high"]?.doubleValue ?? 0) + 30, "440 Hz 落在 300–800 那一段")
    let frames = report["frames"]?.objectValue ?? [:]
    let count = 48
    check(frames["count"]?.intValue == count, "逐帧：2 秒 48 帧")
    var values = 0
    for key in ["db", "peak_db", "momentary_lufs", "reduction_db"] {
        let array = frames["mix"]?[key]?.arrayValue ?? []
        check(array.count == count, "逐帧的 mix.\(key) 正好 48 个")
        values += array.count
    }
    for name in ["A1", "rest"] {
        for key in ["db", "low", "low_mid", "high_mid", "high"] {
            let array = frames["layers"]?[name]?[key]?.arrayValue ?? []
            check(array.count == count, "逐帧的 \(name).\(key) 正好 48 个")
            values += array.count
        }
    }
    check(values <= AIListenMixPlan.maxFrameValues, "逐帧一共 \(values) 个数，在上限 \(AIListenMixPlan.maxFrameValues) 之内")
    let size = JSONValue.object(report).encodedString().utf8.count
    check(size < 12_000, "两层、2 秒带逐帧的结果 \(size) 字节，AI 一次读得完")
    print("   结果大小：两层 2 秒带逐帧 \(size) 字节")
}
