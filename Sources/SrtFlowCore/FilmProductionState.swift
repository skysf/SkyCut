import Foundation

// 工程内的公开制作记录；只管存盘值，不解释 film、不存配方/pin/付款状态。
// film/render Data 只能由 App 的严格公开 DTO 适配器生产，读出使用前必须重新校验。
public struct FilmProductionState: Codable, Hashable, Sendable {
    public var revision: Int
    public var story: String
    public var shots: [Shot]
    public var soundCues: [SoundCue]

    public init(revision: Int, story: String, shots: [Shot], soundCues: [SoundCue]) {
        self.revision = revision; self.story = story; self.shots = shots; self.soundCues = soundCues
    }

    public struct Shot: Codable, Hashable, Sendable {
        public var film: Data
        public var render: Data
        public var outputClipID: UUID?
        public var boundSourceFingerprint: String?
        public var review: OutputReview?
        public var anchors: [SourceAnchor]

        public init(film: Data, render: Data, outputClipID: UUID? = nil,
                    boundSourceFingerprint: String? = nil, review: OutputReview? = nil, anchors: [SourceAnchor] = []) {
            self.film = film; self.render = render; self.outputClipID = outputClipID
            self.boundSourceFingerprint = boundSourceFingerprint; self.review = review; self.anchors = anchors
        }
    }

    public struct OutputReview: Codable, Hashable, Sendable {
        public var sourceTimes: [Double]
        public var notes: String
        public var actionSamples: [ActionSamples]
        public var sourceFingerprint: String
        public var previous: SeamReview?
        public var next: SeamReview?

        public init(sourceTimes: [Double], notes: String, actionSamples: [ActionSamples] = [], sourceFingerprint: String,
                    previous: SeamReview? = nil, next: SeamReview? = nil) {
            self.sourceTimes = sourceTimes; self.notes = notes; self.actionSamples = actionSamples
            self.sourceFingerprint = sourceFingerprint
            self.previous = previous; self.next = next
        }
    }

    /// 调用方实际看过每个新增动作转折前后的采样；是声明，不是自动动作识别。
    public struct ActionSamples: Codable, Hashable, Sendable {
        public var actionID: String
        public var sourceTimes: [Double]
        public var notes: String
        public init(actionID: String, sourceTimes: [Double], notes: String) {
            self.actionID = actionID; self.sourceTimes = sourceTimes; self.notes = notes
        }
    }

    public struct SeamReview: Codable, Hashable, Sendable {
        public var timelineTimes: [Double]
        public var notes: String
        public var fingerprint: String
        public init(timelineTimes: [Double], notes: String, fingerprint: String) {
            self.timelineTimes = timelineTimes; self.notes = notes; self.fingerprint = fingerprint
        }
    }

    public struct SourceAnchor: Codable, Hashable, Sendable {
        public enum Role: String, Codable, Hashable, Sendable { case first, last }
        public enum SourceEdge: String, Codable, Hashable, Sendable {
            case firstUsed = "first_used", lastUsed = "last_used"
        }
        public var role: Role
        public var sourceEdge: SourceEdge
        public var fromShotID: String
        public var assetURL: URL
        /// freeze_frame 的严格公开 metadata，保留 CMTime 原始整数/标度，不从 Double 重建 actualTime。
        public var sourceFrame: Data
        public var fingerprint: String
        public init(role: Role, sourceEdge: SourceEdge, fromShotID: String, assetURL: URL, sourceFrame: Data, fingerprint: String) {
            self.role = role; self.sourceEdge = sourceEdge; self.fromShotID = fromShotID; self.assetURL = assetURL
            self.sourceFrame = sourceFrame; self.fingerprint = fingerprint
        }
    }

    public struct SoundCue: Codable, Hashable, Sendable {
        public enum Layer: String, Codable, Hashable, Sendable { case music, environment, foley, silence }
        public var id: String
        public var shotIDs: [String]
        public var layer: Layer
        public var purpose: String
        public var at: Double
        public var duration: Double
        public var actionID: String?
        public var audioClipID: UUID?
        public var silenceReason: String?
        public var recoveryAt: Double?
        public var alignment: Alignment?
        public init(id: String, shotIDs: [String], layer: Layer, purpose: String, at: Double, duration: Double,
                    actionID: String? = nil, audioClipID: UUID? = nil, silenceReason: String? = nil,
                    recoveryAt: Double? = nil, alignment: Alignment? = nil) {
            self.id = id; self.shotIDs = shotIDs; self.layer = layer; self.purpose = purpose
            self.at = at; self.duration = duration; self.actionID = actionID; self.audioClipID = audioClipID
            self.silenceReason = silenceReason; self.recoveryAt = recoveryAt; self.alignment = alignment
        }
    }

    public struct Alignment: Codable, Hashable, Sendable {
        public var fingerprint: String
        public var measuredNote: String?
        public var listenedNote: String?
        public init(fingerprint: String, measuredNote: String? = nil, listenedNote: String? = nil) {
            self.fingerprint = fingerprint; self.measuredNote = measuredNote; self.listenedNote = listenedNote
        }
    }
}
