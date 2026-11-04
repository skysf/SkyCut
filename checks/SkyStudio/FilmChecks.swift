import Foundation
import SrtFlowMCPKit

// 公开合同的合成故事，不含真实配方、研究来源或用户素材；验证 JSON/Codable 入口和连续性声明。
let filmCheckContext: JSONValue = ["environment": "interior", "light_source": "practical", "shot_task": "read_action"]
let filmCheckState: JSONValue = [
    "actor_position": "beside table", "hand": "right", "grip": "holding lantern", "prop_location": "right hand",
    "action_phase": "paused", "spatial_relation": "table ahead", "gaze": "at switch", "screen_direction": "right",
    "lighting": "single lamp", "completed_actions": ["arrive"]
]

func filmCheckJSON(middle: Bool = false) -> JSONValue {
    let render: JSONValue = ["kind": "image", "model": "synthetic-image", "prompt": "An original empty room.", "context": filmCheckContext]
    var o: [String: JSONValue] = [
        "intent": "original_film", "category": "science_fiction", "footage": "none", "context": filmCheckContext,
        "shot": ["id": "shot-b", "index": middle ? 1 : 0, "total": middle ? 3 : 1, "revision": 1,
                 "entry": filmCheckState, "exit": filmCheckState, "actions": []],
        "sound": ["bed_id": "room-air", "music": "restrained pulse", "environment": "continuous ventilation", "foley": "none while still"]
    ]
    if middle {
        o["previous"] = ["shot_id": "shot-a", "render": render, "sound_bed_id": "room-air", "cut": ["type": "continuous"], "exit": filmCheckState]
        o["next"] = ["shot_id": "shot-c", "render": render, "sound_bed_id": "room-air", "cut": ["type": "continuous"], "entry": filmCheckState]
    }
    return .object(o)
}

func filmChanging(_ json: JSONValue, _ path: [String], to value: JSONValue?) -> JSONValue {
    guard let first = path.first, var object = json.objectValue else { return json }
    if path.count == 1 { object[first] = value }
    else if let child = object[first] { object[first] = filmChanging(child, Array(path.dropFirst()), to: value) }
    return .object(object)
}

func filmRefuses(_ json: JSONValue, _ label: String) {
    check((try? SkyStudioFilm(json: json)) == nil, label)
    if let data = try? json.encodedData() {
        check((try? JSONDecoder().decode(SkyStudioFilm.self, from: data)) == nil, label + " through Codable")
    }
}

func runFilmChecks() {
    let plain = filmCheckJSON()
    let middle = filmCheckJSON(middle: true)
    guard let film = try? SkyStudioFilm(json: middle) else { check(false, "complete public middle-shot context parses"); return }
    checkEqual(film.shot.revision, 1, "revision one still carries both neighbors")
    checkEqual(film.previous?.state.hand, .right, "typed hand state")
    checkEqual(film.shot.entry.completedActions, ["arrive"], "completed actions preserved")
    checkEqual(try? JSONDecoder().decode(SkyStudioFilm.self, from: JSONEncoder().encode(film)), film, "durable public film round trip")
    check(film.json["recipe_pin"] == nil && film.json["profile"] == nil, "public state has no private or quote fields")

    for path in [["context"], ["context", "light_source"], ["previous", "render", "context"], ["next"], ["previous"]] {
        filmRefuses(filmChanging(middle, path, to: nil), "missing required " + path.joined(separator: "."))
    }
    for (path, value) in [
        (["category"], JSONValue.string("animation")), (["footage"], "research"), (["context", "environment"], "underwater"),
        (["context", "private_profile"], "secret"), (["shot", "entry", "finger_position"], "up"),
        (["next", "render", "recipe"], "hidden"), (["shot", "index"], 0.5), (["shot", "total"], 101),
        (["shot", "revision"], 0), (["previous", "shot_id"], "shot-b"), (["next", "shot_id"], "shot-a"),
        (["sound", "foley"], " "), (["shot", "entry", "hand"], "either"), (["shot", "actions"], ["arrive"]),
        (["shot", "exit", "completed_actions"], []), (["shot", "entry", "completed_actions"], ["Arrive"]),
        (["shot", "entry", "completed_actions"], ["arrive", "arrive"]), (["next", "sound_bed_id"], "new-bed"),
        (["next", "entry", "hand"], "left"), (["next", "cut", "reset_fields"], [])
    ] { filmRefuses(filmChanging(middle, path, to: value), "reject invalid " + path.joined(separator: ".")) }
    filmRefuses(filmChanging(plain, ["previous"], to: middle["previous"]), "no extra previous at first shot")
    filmRefuses(filmChanging(middle, ["shot", "entry", "lighting"], to: .string(String(repeating: "🪐", count: 41))), "80 UTF-16 state limit")
    let longPrompt = "  " + String(repeating: "🪐", count: 4000) + "\n"
    check((try? SkyStudioFilm(json: filmChanging(middle, ["next", "render", "prompt"], to: .string(longPrompt)))) != nil,
          "neighbor prompt trims then counts Unicode scalars, independently of state UTF-16 limits")
    filmRefuses(filmChanging(middle, ["next", "render", "prompt"], to: .string(String(repeating: "🪐", count: 4001))), "overlong neighbor prompt rejected")

    var advanced = filmChanging(plain, ["shot", "actions"], to: ["switch_on"])
    advanced = filmChanging(advanced, ["shot", "exit", "completed_actions"], to: ["arrive", "switch_on"])
    check((try? SkyStudioFilm(json: advanced)) != nil, "new completed action advances history exactly once")
    for environment in ["interior", "exterior", "space"] {
        check((try? SkyStudioFilm(json: filmChanging(plain, ["context", "environment"], to: .string(environment)))) != nil,
              "client accepts public context without embedding private scope: " + environment)
    }
    runIntentionalFilmCutChecks(middle)
    runFilmInputChecks()
}

private func runIntentionalFilmCutChecks(_ middle: JSONValue) {
    var jump = filmChanging(middle, ["next", "entry", "actor_position"], to: "at hatch")
    jump = filmChanging(jump, ["next", "entry", "completed_actions"], to: ["arrive", "walk_to_hatch"])
    jump = filmChanging(jump, ["next", "cut"], to: ["type": "time_jump", "reason": "The walk finishes offscreen.",
                                                   "reset_fields": ["actor_position"], "offscreen_actions": ["walk_to_hatch"]])
    check((try? SkyStudioFilm(json: jump)) != nil, "explicit time jump preserves history and exactly names reset fields")
    filmRefuses(filmChanging(jump, ["next", "cut", "reset_fields"], to: ["actor_position", "hand"]), "unchanged reset fields rejected")
    filmRefuses(filmChanging(jump, ["next", "cut", "offscreen_actions"], to: []), "offscreen action cannot be omitted")
    filmRefuses(filmChanging(jump, ["next", "cut", "reason"], to: "cut"), "short intentional-cut reason rejected")
    filmRefuses(filmChanging(jump, ["next", "entry", "completed_actions"], to: ["walk_to_hatch"]), "jump cannot erase completed actions")
    var wrong = filmChanging(jump, ["next", "entry", "screen_direction"], to: "left")
    wrong = filmChanging(wrong, ["next", "cut", "reset_fields"], to: ["actor_position", "screen_direction"])
    filmRefuses(wrong, "time jump cannot reset screen direction")
    wrong = filmChanging(wrong, ["next", "cut", "type"], to: "location_change")
    check((try? SkyStudioFilm(json: wrong)) != nil, "location change may explicitly reset screen direction")
    wrong = filmChanging(wrong, ["next", "entry", "hand"], to: "left")
    wrong = filmChanging(wrong, ["next", "cut", "reset_fields"], to: ["actor_position", "screen_direction", "hand"])
    filmRefuses(wrong, "location change cannot excuse changing hands")
    wrong = filmChanging(wrong, ["next", "cut", "type"], to: "time_location_jump")
    check((try? SkyStudioFilm(json: wrong)) != nil, "time and location jump permits only its explicitly changed fields")
}

private func runFilmInputChecks() {
    let url: JSONValue = "https://assets.example/originals/test-account/first.png"
    let renderPath = ["previous", "render"]
    let middle = filmChanging(filmCheckJSON(middle: true), renderPath + ["inputs"], to: ["image_url": url])
    check((try? SkyStudioFilm(json: middle)) != nil, "durable original image URL is structurally valid; server still verifies owner")
    for bad: JSONValue in ["https://assets.example/generated/a.png", "https://assets.example/originals/test-account/a.png?x=1",
                           "https://assets.example/originals/test-account/a.png#x", "https://key@assets.example/originals/test-account/a.png",
                           "https://assets.example/originals/test-account/%2e%2e/a.png"] {
        filmRefuses(filmChanging(middle, renderPath + ["inputs", "image_url"], to: bad), "invalid durable input rejected")
    }
    for name in ["video_url", "audio_url", "document_url", "web_url"] {
        filmRefuses(filmChanging(middle, renderPath + ["inputs", name], to: url), "official input rejects " + name)
    }
    for type in ["video", "audio", "document"] {
        filmRefuses(filmChanging(middle, renderPath + ["inputs", "references"], to: [["type": .string(type), "url": url]]), "non-image neighbor reference rejected")
    }
    filmRefuses(filmChanging(middle, renderPath + ["params"], to: ["reference_image_count": 2]), "count must match actual neighbor assets")
}
