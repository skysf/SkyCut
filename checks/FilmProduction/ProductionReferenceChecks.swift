import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// native PNG 证据和已准备引用的纯值闭环；这里只用非空属性 fixture，不上传、不解码。
func runProductionReferenceChecks() throws {
    let first = try SourceFrameFixture(), last = try SourceFrameFixture()
    defer { first.remove(); last.remove() }
    let firstAsset = URL(string: "https://assets.example/originals/account/first.png")!
    let lastAsset = URL(string: "https://assets.example/originals/account/last.png")!
    let anchors: [FilmProductionState.SourceAnchor] = [
        .init(role: .first, sourceEdge: .lastUsed, fromShotID: "previous", assetURL: firstAsset,
              sourceFrame: try first.evidence(atEnd: true).encodedData(), fingerprint: "first-test-fingerprint"),
        .init(role: .last, sourceEdge: .lastUsed, fromShotID: "current", assetURL: lastAsset,
              sourceFrame: try last.evidence(atEnd: true).encodedData(), fingerprint: "last-test-fingerprint")
    ]
    let firstSource: JSONValue = ["role": "first_frame", "type": "image", "file": first.pngID]
    let lastSource: JSONValue = ["role": "last_frame", "type": "image", "file": last.pngID]
    let matching: JSONValue = .array([firstSource, lastSource])
    let result = try AIFilmProductionReferences.validate(anchors, sources: matching)
    check(result == .array([
        ["role": "first_frame", "file": first.pngID, "asset_url": .string(firstAsset.absoluteString)],
        ["role": "last_frame", "file": last.pngID, "asset_url": .string(lastAsset.absoluteString)]
    ]), "both exact prepared originals retain independent input roles and asset URLs")
    rejected("other original PNG cannot stand in for an anchor") {
        _ = try AIFilmProductionReferences.validate(anchors, sources: .array([changed(firstSource, ["file"], last.pngID), lastSource]))
    }
    rejected("a correct PNG with the wrong input role is rejected") {
        _ = try AIFilmProductionReferences.validate(anchors, sources: .array([changed(firstSource, ["role"], "reference_image"), lastSource]))
    }
    rejected("duplicate prepared first-frame roles are ambiguous") {
        _ = try AIFilmProductionReferences.validate(anchors, sources: .array([firstSource, firstSource, lastSource]))
    }
    rejected("a changed prepared PNG modification time invalidates the identity") {
        let modified = first.pngID["modified"]!.doubleValue! + 1
        _ = try AIFilmProductionReferences.validate(anchors, sources: .array([changed(firstSource, ["file", "modified"], .number(modified)), lastSource]))
    }
    rejected("prepared video cannot satisfy a native PNG anchor") {
        _ = try AIFilmProductionReferences.validate(anchors, sources: .array([changed(firstSource, ["type"], "video"), lastSource]))
    }
    rejected("a missing prepared last frame is rejected") {
        _ = try AIFilmProductionReferences.validate(anchors, sources: .array([firstSource]))
    }
    rejected("actual prepared sources must be an array") {
        _ = try AIFilmProductionReferences.validate(anchors, sources: .object([:]))
    }
    var corrupt = anchors
    corrupt[0].sourceFrame = try changed(first.evidence(atEnd: true), ["recipe_pin"], "private").encodedData()
    rejected("unknown stored native metadata cannot escape through reference binding") {
        _ = try AIFilmProductionReferences.validate(corrupt, sources: matching)
    }
}
