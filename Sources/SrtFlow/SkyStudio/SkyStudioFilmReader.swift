import Foundation
import SrtFlowMCPKit

// 公开 film 的唯一严格解析入口：拒绝未知键、缺上下文、重复动作及无声明的跨缝变化。
// 只核对用户声明；不猜服务端私有支持范围、不证明画面连续，也不解释不透明 pin。
enum SkyStudioFilmReader {
    typealias Film = SkyStudioFilm

    static func read(_ json: JSONValue) throws -> Film {
        let f = try object(json, keys: ["intent", "category", "footage", "context", "shot", "previous", "next", "sound"], at: "film")
        guard f["intent"] == "original_film", f["category"] == "science_fiction", f["footage"] == "none" else {
            throw error("film", "Only original_film / science_fiction / none is supported.")
        }
        let shot = try readShot(f["shot"])
        let sound = try readSound(f["sound"])
        let context = try readContext(f["context"], at: "film.context")
        let previous = try readNeighbor(f["previous"], side: "previous", needed: shot.index > 0, shot: shot, sound: sound)
        let next = try readNeighbor(f["next"], side: "next", needed: shot.index < shot.total - 1, shot: shot, sound: sound)
        if let previous, let next, previous.shotID == next.shotID {
            throw error("film", "Neighbor shot ids must be distinct.")
        }
        return Film(context: context, shot: shot, previous: previous, next: next, sound: sound)
    }

    static func readContext(_ value: JSONValue?, at path: String) throws -> Film.Context {
        let o = try object(value, keys: ["environment", "light_source", "shot_task"], at: path)
        guard let environment = o["environment"]?.stringValue.flatMap(Film.Context.Environment.init(rawValue:)),
              let light = o["light_source"]?.stringValue.flatMap(Film.Context.LightSource.init(rawValue:)),
              let task = o["shot_task"]?.stringValue.flatMap(Film.Context.ShotTask.init(rawValue:)) else {
            throw error(path, "Declare environment, light_source and shot_task explicitly using their supported values.")
        }
        return .init(environment: environment, lightSource: light, shotTask: task)
    }

    private static func readShot(_ value: JSONValue?) throws -> Film.Shot {
        let p = "film.shot"
        let o = try object(value, keys: ["id", "index", "total", "revision", "entry", "exit", "actions"], at: p)
        let id = try text(o["id"], at: p + ".id")
        let total = try integer(o["total"], range: 1...100, at: p + ".total")
        let index = try integer(o["index"], range: 0...(total - 1), at: p + ".index")
        let revision = try integer(o["revision"], range: 1...10000, at: p + ".revision")
        let entry = try readState(o["entry"], at: p + ".entry")
        let exit = try readState(o["exit"], at: p + ".exit")
        let actions = try actionIDs(o["actions"], at: p + ".actions")
        guard Set(actions).isDisjoint(with: entry.completedActions),
              Set(entry.completedActions + actions) == Set(exit.completedActions) else {
            throw error(p + ".actions", "Actions must be new; exit.completed_actions must equal entry.completed_actions plus actions.")
        }
        return .init(id: id, index: index, total: total, revision: revision, entry: entry, exit: exit, actions: actions)
    }

    private static func readState(_ value: JSONValue?, at p: String) throws -> Film.State {
        let names = ["actor_position", "grip", "prop_location", "action_phase", "spatial_relation", "gaze", "screen_direction", "lighting"]
        let o = try object(value, keys: names + ["hand", "completed_actions"], at: p)
        let values = try Dictionary(uniqueKeysWithValues: names.map { ($0, try text(o[$0], at: p + "." + $0)) })
        guard let hand = o["hand"]?.stringValue.flatMap(Film.State.Hand.init(rawValue:)) else {
            throw error(p + ".hand", "Use left, right, both or none.")
        }
        return .init(actorPosition: values["actor_position"]!, hand: hand, grip: values["grip"]!,
                     propLocation: values["prop_location"]!, actionPhase: values["action_phase"]!,
                     spatialRelation: values["spatial_relation"]!, gaze: values["gaze"]!,
                     screenDirection: values["screen_direction"]!, lighting: values["lighting"]!,
                     completedActions: try actionIDs(o["completed_actions"], at: p + ".completed_actions").sorted())
    }

    private static func readSound(_ value: JSONValue?) throws -> Film.Sound {
        let p = "film.sound"
        let o = try object(value, keys: ["bed_id", "music", "environment", "foley"], at: p)
        return .init(bedID: try text(o["bed_id"], at: p + ".bed_id"), music: try text(o["music"], at: p + ".music"),
                     environment: try text(o["environment"], at: p + ".environment"), foley: try text(o["foley"], at: p + ".foley"))
    }

    private static func readNeighbor(
        _ value: JSONValue?, side: String, needed: Bool, shot: Film.Shot, sound: Film.Sound
    ) throws -> Film.Neighbor? {
        let p = "film." + side
        guard needed else {
            guard value == nil || value == .null else { throw error(p, "There is no neighbor at this end of the film.") }
            return nil
        }
        let boundary = side == "previous" ? "exit" : "entry"
        let o = try object(value, keys: ["shot_id", "render", "sound_bed_id", "cut", boundary], at: p)
        let id = try text(o["shot_id"], at: p + ".shot_id")
        guard id != shot.id else { throw error(p + ".shot_id", "A neighbor cannot be the current shot.") }
        let bed = try text(o["sound_bed_id"], at: p + ".sound_bed_id")
        let state = try readState(o[boundary], at: p + "." + boundary)
        let render = try readRender(o["render"], at: p + ".render")
        let cut = try readCut(o["cut"], at: p + ".cut", from: side == "previous" ? state : shot.exit,
                              to: side == "previous" ? shot.entry : state,
                              fromBed: side == "previous" ? bed : sound.bedID, toBed: side == "previous" ? sound.bedID : bed)
        return .init(shotID: id, render: render, soundBedID: bed, cut: cut, state: state)
    }

    private static func readRender(_ value: JSONValue?, at p: String) throws -> Film.Render {
        let o = try object(value, keys: ["kind", "model", "prompt", "params", "inputs", "context"], at: p)
        guard let kind = o["kind"]?.stringValue.flatMap(Film.Render.Kind.init(rawValue:)) else {
            throw error(p + ".kind", "Official shots accept image, text_to_video or image_to_video.")
        }
        let params = try freeObject(o["params"], at: p + ".params")
        let inputs = try freeObject(o["inputs"], at: p + ".inputs")
        try SkyStudioFilmInputs.validate(inputs, kind: kind.rawValue, params: params, at: p + ".inputs")
        return .init(kind: kind, model: try text(o["model"], at: p + ".model", maximum: 160),
                     prompt: try prompt(o["prompt"], at: p + ".prompt"), params: params, inputs: inputs,
                     context: try readContext(o["context"], at: p + ".context"))
    }

    private static func readCut(
        _ value: JSONValue?, at p: String, from: Film.State, to: Film.State, fromBed: String, toBed: String
    ) throws -> Film.Cut {
        let o = try object(value, keys: ["type", "reason", "reset_fields", "offscreen_actions"], at: p)
        if o["type"] == "continuous" {
            guard o.count == 1, from == to, fromBed == toBed else {
                throw error(p, "A continuous cut must preserve every boundary state and sound bed; reset flags are not allowed.")
            }
            return .continuous
        }
        guard let kind = o["type"]?.stringValue.flatMap(Film.Cut.Kind.init(rawValue:)),
              let rawFields = o["reset_fields"]?.arrayValue else {
            throw error(p, "Declare a supported cut type, reason and exact reset_fields.")
        }
        let reason = try text(o["reason"], at: p + ".reason", maximum: 160)
        guard reason.utf16.count >= 8 else { throw error(p + ".reason", "Explain the intentional cut in 8–160 characters.") }
        let fields = rawFields.compactMap { $0.stringValue.flatMap(Film.ResetField.init(rawValue:)) }
        guard fields.count == rawFields.count, Set(fields).count == fields.count,
              Set(fields).isSubset(of: allowedFields(kind)) else { throw error(p + ".reset_fields", "Invalid or repeated reset field for this cut.") }
        var changed = Set(from.physical.keys.filter { from.physical[$0] != to.physical[$0] })
        if fromBed != toBed { changed.insert("sound_bed") }
        guard Set(fields.map(\.rawValue)) == changed else { throw error(p + ".reset_fields", "List exactly the changed boundary fields.") }
        let actions = try actionIDs(o["offscreen_actions"] ?? [], at: p + ".offscreen_actions")
        guard Set(actions).isDisjoint(with: from.completedActions),
              Set(from.completedActions + actions) == Set(to.completedActions) else {
            throw error(p + ".offscreen_actions", "Preserve completed actions and explicitly name every new offscreen action.")
        }
        return .intentional(kind: kind, reason: reason, resetFields: fields.sorted { $0.rawValue < $1.rawValue }, offscreenActions: actions)
    }

    private static func allowedFields(_ kind: Film.Cut.Kind) -> Set<Film.ResetField> {
        switch kind {
        case .timeJump: return [.actorPosition, .hand, .grip, .propLocation, .actionPhase, .gaze, .lighting, .soundBed]
        case .locationChange: return [.actorPosition, .spatialRelation, .gaze, .screenDirection, .lighting, .soundBed]
        case .timeLocationJump, .montage: return Set(Film.ResetField.allCases)
        }
    }

    static func object(_ value: JSONValue?, keys: [String], at path: String) throws -> [String: JSONValue] {
        guard let o = value?.objectValue else { throw error(path, "A complete object is required.") }
        let unknown = Set(o.keys).subtracting(keys).sorted()
        guard unknown.isEmpty else { throw error(path, "Unknown fields: " + unknown.joined(separator: ", ") + ".") }
        return o
    }

    private static func freeObject(_ value: JSONValue?, at path: String) throws -> [String: JSONValue] {
        guard let value else { return [:] }
        guard let object = value.objectValue else { throw error(path, "Expected an object.") }
        return object
    }

    static func text(_ value: JSONValue?, at path: String, maximum: Int = 80) throws -> String {
        guard let s = value?.stringValue, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.utf16.count <= maximum else {
            throw error(path, "A nonempty string of at most \(maximum) UTF-16 characters is required.")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 生成提示词沿用服务端计数：先 trim，再数 Unicode 标量；状态短句的 UTF-16 上限不能套到这里。
    private static func prompt(_ value: JSONValue?, at path: String) throws -> String {
        guard let raw = value?.stringValue else { throw error(path, "A nonempty generation prompt is required.") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 4000 else {
            throw error(path, "A generation prompt must have 1–4000 Unicode characters after trimming.")
        }
        return text
    }

    private static func integer(_ value: JSONValue?, range: ClosedRange<Int>, at path: String) throws -> Int {
        guard let n = value?.doubleValue, n.isFinite, n.rounded() == n, n >= Double(range.lowerBound), n <= Double(range.upperBound) else {
            throw error(path, "An integer in \(range.lowerBound)...\(range.upperBound) is required.")
        }
        return Int(n)
    }

    private static func actionIDs(_ value: JSONValue?, at path: String) throws -> [String] {
        guard let raw = value?.arrayValue, raw.count <= 24 else { throw error(path, "Expected up to 24 unique action ids.") }
        let ids = raw.compactMap(\.stringValue)
        guard ids.count == raw.count, Set(ids).count == ids.count,
              ids.allSatisfy({ $0.range(of: #"\A[a-z0-9_-]{1,48}\z"#, options: .regularExpression) != nil }) else {
            throw error(path, "Action ids must be unique and match [a-z0-9_-]{1,48}.")
        }
        return ids
    }

    static func error(_ path: String, _ message: String) -> SkyStudioFilmError { .init(field: path, message: message) }
}
