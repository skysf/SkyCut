import Foundation
import SrtFlowMCPKit

// 官方原创镜头的公开声明：世界状态、动作、相邻镜头和声音计划。只存用户故事，绝不存配方或来源。
// JSON 入口（包括工程的 Codable）统一经 SkyStudioFilmReader 严格核对；实际视频验收由制作流程负责。
struct SkyStudioFilm: Hashable, Sendable, Codable {
    struct Context: Hashable, Sendable {
        enum Environment: String, Sendable { case interior, exterior, space }
        enum LightSource: String, Sendable { case practical, daylight, mixed, none }
        enum ShotTask: String, Sendable {
            case establishSpace = "establish_space", readAction = "read_action", readObject = "read_object"
            case readReaction = "read_reaction", showConsequence = "show_consequence"
        }
        var environment: Environment
        var lightSource: LightSource
        var shotTask: ShotTask

        var json: JSONValue {
            ["environment": .string(environment.rawValue), "light_source": .string(lightSource.rawValue),
             "shot_task": .string(shotTask.rawValue)]
        }
    }

    struct State: Hashable, Sendable {
        enum Hand: String, Sendable { case left, right, both, none }
        var actorPosition: String
        var hand: Hand
        var grip: String
        var propLocation: String
        var actionPhase: String
        var spatialRelation: String
        var gaze: String
        var screenDirection: String
        var lighting: String
        var completedActions: [String]

        var physical: [String: String] {
            ["actor_position": actorPosition, "hand": hand.rawValue, "grip": grip, "prop_location": propLocation,
             "action_phase": actionPhase, "spatial_relation": spatialRelation, "gaze": gaze,
             "screen_direction": screenDirection, "lighting": lighting]
        }
        var json: JSONValue {
            var value = physical.mapValues(JSONValue.string)
            value["completed_actions"] = .array(completedActions.map(JSONValue.string))
            return .object(value)
        }
    }

    enum ResetField: String, CaseIterable, Sendable {
        case actorPosition = "actor_position", hand, grip, propLocation = "prop_location"
        case actionPhase = "action_phase", spatialRelation = "spatial_relation", gaze
        case screenDirection = "screen_direction", lighting, soundBed = "sound_bed"
    }

    enum Cut: Hashable, Sendable {
        enum Kind: String, Sendable {
            case timeJump = "time_jump", locationChange = "location_change"
            case timeLocationJump = "time_location_jump", montage
        }
        case continuous
        case intentional(kind: Kind, reason: String, resetFields: [ResetField], offscreenActions: [String])

        var json: JSONValue {
            switch self {
            case .continuous: return ["type": "continuous"]
            case let .intentional(kind, reason, fields, actions):
                return ["type": .string(kind.rawValue), "reason": .string(reason),
                        "reset_fields": .array(fields.map { .string($0.rawValue) }),
                        "offscreen_actions": .array(actions.map(JSONValue.string))]
            }
        }
    }

    struct Render: Hashable, Sendable {
        enum Kind: String, Sendable { case image, textToVideo = "text_to_video", imageToVideo = "image_to_video" }
        var kind: Kind
        var model: String
        var prompt: String
        var params: [String: JSONValue]
        var inputs: [String: JSONValue]
        var context: Context

        var json: JSONValue {
            ["kind": .string(kind.rawValue), "model": .string(model), "prompt": .string(prompt),
             "params": .object(params), "inputs": .object(inputs), "context": context.json]
        }
    }

    struct Neighbor: Hashable, Sendable {
        var shotID: String
        var render: Render
        var soundBedID: String
        var cut: Cut
        /// previous 的 exit / next 的 entry；序列化时由所在侧决定键，不能把两侧混写。
        var state: State

        func json(side: String) -> JSONValue {
            ["shot_id": .string(shotID), "render": render.json, "sound_bed_id": .string(soundBedID),
             "cut": cut.json, side == "previous" ? "exit" : "entry": state.json]
        }
    }

    struct Shot: Hashable, Sendable {
        var id: String
        var index: Int
        var total: Int
        var revision: Int
        var entry: State
        var exit: State
        var actions: [String]

        var json: JSONValue {
            ["id": .string(id), "index": .number(Double(index)), "total": .number(Double(total)),
             "revision": .number(Double(revision)), "entry": entry.json, "exit": exit.json,
             "actions": .array(actions.map(JSONValue.string))]
        }
    }

    struct Sound: Hashable, Sendable {
        var bedID: String
        var music: String
        var environment: String
        var foley: String

        var json: JSONValue {
            ["bed_id": .string(bedID), "music": .string(music), "environment": .string(environment), "foley": .string(foley)]
        }
    }

    var context: Context
    var shot: Shot
    var previous: Neighbor?
    var next: Neighbor?
    var sound: Sound

    init(context: Context, shot: Shot, previous: Neighbor? = nil, next: Neighbor? = nil, sound: Sound) {
        self.context = context
        self.shot = shot
        self.previous = previous
        self.next = next
        self.sound = sound
    }

    init(json: JSONValue) throws { self = try SkyStudioFilmReader.read(json) }
    init(from decoder: Decoder) throws { try self.init(json: JSONValue(from: decoder)) }
    func encode(to encoder: Encoder) throws { try json.encode(to: encoder) }

    var json: JSONValue {
        var value: [String: JSONValue] = ["intent": "original_film", "category": "science_fiction", "footage": "none",
                                        "context": context.json, "shot": shot.json, "sound": sound.json]
        if let previous { value["previous"] = previous.json(side: "previous") }
        if let next { value["next"] = next.json(side: "next") }
        return .object(value)
    }
}

/// 本地输入错与服务器失败分开；不能把本地拒绝报成一次服务器请求。
struct SkyStudioFilmError: Error, LocalizedError, Hashable, Sendable {
    var field: String
    var message: String
    var errorDescription: String? { "\(field): \(message)" }
}
