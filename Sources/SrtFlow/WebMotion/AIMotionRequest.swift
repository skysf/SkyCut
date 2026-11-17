import Foundation
import SrtFlowMCPKit

// Reads one set_motion call into a validated source and placement. Approval, rendering and timeline mutation happen later.
@MainActor
struct AIMotionRequest {
    var record: WebMotionClipRecord
    var replacing: UUID?
    var at: Double?
    var hitAt: Double?
    var target: TrackDropTarget?
    var needsPageApproval: Bool
    var expectedClip: EditClip?

    init(_ args: AIToolArguments, state: TimelineState, playhead: Double) throws {
        let replacing = try args.string("clip_id").map { try AIShortIDs(state: state).resolve($0) }
        let current = replacing.flatMap { state.clip(with: $0) }
        if replacing != nil, current?.webMotion == nil { throw AIToolError("clip_id must be a web-motion clip.") }
        let page = try args.string("page")
        let template = try args.string("template")
        guard page == nil || template == nil else { throw AIToolError("Pass template or page, not both.") }
        var source = try template.map { try MotionPresetLibrary.template($0, in: state) } ?? current?.webMotion
        if let page {
            let canvas = TimelineRenderSize.size(for: state)
            source = WebMotionClipRecord(page: page, width: Int(canvas.width), height: Int(canvas.height), fps: state.frameRate.fps)
        }
        guard var record = source else { throw AIToolError("Pass template, page, or an existing web-motion clip_id.") }
        if let template { record.templateID = template }
        if let name = try args.string("name") { record.name = name }
        guard !record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIToolError("name must not be empty.") }
        var values = try WebMotionParameters.readObject(record.parametersJSON)
        if args.has("parameters") {
            guard let changes = args.raw["parameters"]?.objectValue else { throw AIToolError("parameters must be an object.") }
            values.merge(changes) { _, value in value }
        }
        record.parametersJSON = try WebMotionParameters.canonical(values)
        record.duration = try args.double("duration") ?? values["duration"]?.doubleValue ?? record.duration
        record.hitTime = try args.double("hit") ?? values["hit"]?.doubleValue ?? record.hitTime
        if let fields = try args.array("fields") { record.parameterFields = try fields.map(Self.field) }
        else if record.parameterFields.isEmpty { record.parameterFields = WebMotionParameters.inferredFields(values) }
        if let fonts = try args.stringArray("fonts") {
            record.fonts = fonts
        }
        record = try WebMotionParameters.normalized(record)
        try WebMotionValidation.validate(record)
        var at = try args.double("at")
        let hitAt = try args.double("hit_at")
        if at == nil, hitAt == nil, current == nil { at = max(0, playhead) }
        _ = try WebMotionActions.startTime(record, before: current, at: at, hitAt: hitAt)
        let target = try args.string("track").map { try AITrackName.target($0, in: state) }
        if let target { try WebMotionActions.requireUpperTrack(target) }
        // A successfully stored page has already passed its one approval. Parameter changes and template reuse need no new one.
        self.record = record
        self.replacing = replacing
        self.expectedClip = current
        self.at = at
        self.hitAt = hitAt
        self.target = target
        self.needsPageApproval = page.map { html in !state.allClips.contains(where: { $0.webMotion?.page == html }) } ?? false
    }

    private static func field(_ value: JSONValue) throws -> WebMotionParameterField {
        let args = AIToolArguments(value)
        guard value.objectValue != nil,
              let kind = try args.choice("type", from: ["text", "font", "color", "number"]).flatMap(WebMotionParameterField.Kind.init(rawValue:)) else {
            throw AIToolError("Each field needs type: text, font, color, or number.")
        }
        return .init(key: try args.requiredString("key"), label: try args.requiredString("label"), kind: kind,
                     minimum: try args.double("minimum"), maximum: try args.double("maximum"))
    }
}
