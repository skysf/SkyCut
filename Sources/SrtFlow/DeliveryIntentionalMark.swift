import CryptoKit
import Foundation

// Project-persistent review decisions. Matching uses source anchors and bounded tolerance;
// report construction and the MCP mutation adapter live in AIInspectionReview.
struct DeliveryIntentionalMark: Codable, Hashable, Sendable {
    var anchor: DeliveryFindingAnchor
    var reason: String
    var key: String { anchor.key }
}

struct DeliveryFindingAnchor: Codable, Hashable, Sendable {
    var kind: String
    var items: [UUID]
    var reference: UUID?
    var from: Double
    var to: Double
    var tolerance: Double
    var context: String

    var key: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return Self.digest((try? encoder.encode(self)) ?? Data())
    }

    func matches(_ other: Self) -> Bool {
        let slack = min(tolerance, other.tolerance) + 1e-9
        return kind == other.kind && items == other.items && reference == other.reference && context == other.context
            && abs(from - other.from) <= slack && abs(to - other.to) <= slack
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
