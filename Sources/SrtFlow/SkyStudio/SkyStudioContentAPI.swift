import Foundation
import SrtFlowMCPKit

// MARK: - Sky Studio's content routes for SkyCut (`GET /content`, `GET /content/styles/{id}`)
//
// What this owns: the paths (only ids and versions SkyStudioContentRules accepts ever become part of an address) and reading
// the answers into SkyStudioContentManifest / SkyStudioStyleText. Authentication, version, machine and how errors read stay in
// SkyStudioAPI's `request` / `conditionalGet` (checks/sky-studio-wiring.sh). The manifest is asked with the ETag held (304 =
// still current); a style is asked by its version, an immutable answer kept on this Mac once its checksum is checked.
// Errors from the server stay `SkyStudioFailure` (403 `not_entitled`, 404 `not_found`, 503 `content_unavailable`), read by
// SkyStudioStyleLibrary into what the AI is told.
// Not this file: the copies on this Mac (SkyStudioContentCache), when to ask and who may read (SkyStudioStyleLibrary).

enum SkyStudioContentPath {
    static let manifest = "content"

    static func style(_ id: String) throws -> String {
        guard SkyStudioContentRules.isItemID(id) else { throw SkyStudioContentRequestProblem(message: "\(id) is not a Sky Studio style id.") }
        return "content/styles/" + id
    }
}

/// A request SkyCut refuses to send (an id or version of the wrong shape); the message is for the AI.
struct SkyStudioContentRequestProblem: Error, Equatable {
    let message: String
}

/// The manifest asked with the ETag held: still current (304), or a new one with its ETag.
enum SkyStudioManifestAnswer: Equatable, Sendable {
    case notModified
    case changed(SkyStudioContentManifest, etag: String?)
}

extension SkyStudioAPI {
    /// `GET /content`: the current release's manifest (titles, versions, checksums; no text). Any valid key may read it.
    func contentManifest(key: String, etag: String?) async throws -> SkyStudioManifestAnswer {
        let answer = try await conditionalGet(request(SkyStudioContentPath.manifest, key: key), etag: etag)
        guard let body = answer.body else { return .notModified }
        guard let json = try? JSONValue.decode(body), let manifest = SkyStudioContentManifest(json: json) else {
            throw SkyStudioFailure.badAnswer(status: 200)
        }
        return .changed(manifest, etag: answer.etag)
    }

    /// `GET /content/styles/{id}?version=`: one version of one style (needs `features.recipes`). `version` nil = the current
    /// release's. The answer must be that style and version and match its checksum, or it is a bad answer.
    func contentStyle(_ id: String, version: String?, key: String) async throws -> SkyStudioStyleText {
        var call = request(try SkyStudioContentPath.style(id), key: key)
        if let version {
            guard SkyStudioContentRules.isVersion(version) else {
                throw SkyStudioContentRequestProblem(message: "\(version) is not a style version (like 1.0).")
            }
            var components = URLComponents(url: call.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "version", value: version)]
            call.url = components.url
        }
        let answer = try await conditionalGet(call, etag: nil)
        guard let body = answer.body, let json = try? JSONValue.decode(body),
              let style = SkyStudioStyleText(json: json, id: id, version: version) else {
            throw SkyStudioFailure.badAnswer(status: 200)
        }
        return style
    }
}
