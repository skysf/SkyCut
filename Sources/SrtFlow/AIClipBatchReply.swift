import Foundation
import SrtFlowMCPKit

// Projects detailed edit_clips results into ids plus exceptions when compact=true.
// Does not edit clips or compute applied values: notices come from the final single-edit summaries.
enum AIClipBatchReply {
    static func compact(_ summaries: [JSONValue], requests: [JSONValue]) -> [String: JSONValue] {
        let ids = summaries.map { $0["id"] ?? $0["changed"] ?? .null }
        let notices = summaries.enumerated().compactMap { index, summary -> JSONValue? in
            let request = requests.indices.contains(index) ? requests[index] : [:]
            var fields: [String: JSONValue] = [:]
            if let adjustments = summary["adjustments"]?.arrayValue, !adjustments.isEmpty {
                fields["adjustments"] = .array(adjustments)
            }
            for (key, value) in summary.objectValue ?? [:] {
                if key == "warning" || key == "warnings" || key.hasSuffix("_note") || key.contains("source_cuts") {
                    fields[key] = value
                }
            }
            if let bars = summary["black_bars"], bars != "none" { fields["black_bars"] = bars }
            if let subject = summary["subject"], subject.stringValue != nil || subject["note"] != nil
                || subject["text_cut"] != nil || subject["follows"] != nil { fields["subject"] = subject }
            if request["region"] != nil { fields["framing"] = summary["framing"] }
            if request["fit"]?.stringValue?.lowercased() == "fill", let picture = summary["picture"], picture["fills_frame"] == false {
                fields["picture"] = .object((picture.objectValue ?? [:]).filter {
                    ["fills_frame", "fill_scale", "fills_except"].contains($0.key)
                })
            }
            if request["track"] != nil { fields["track"] = summary["track"] }
            if request["file"] != nil {
                for key in ["file", "track", "start", "end", "source_in", "source_out"] { fields[key] = summary[key] }
            }
            guard !fields.isEmpty else { return nil }
            fields["id"] = ids[index]
            fields["index"] = .number(Double(index))
            return .object(fields)
        }
        var result: [String: JSONValue] = ["clips": .array(ids), "compact": true]
        if !notices.isEmpty { result["notices"] = .array(notices) }
        return result
    }
}
