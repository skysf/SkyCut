import Foundation
import SrtFlowMCPKit

// 角色路径只收一节 UUID；网络、认证、上传仍使用唯一的 SkyStudioAPI。
enum SkyStudioCharacterPath {
    static func detail(_ id: String) throws -> String {
        guard UUID(uuidString: id) != nil else { throw AIToolError("Use a full character UUID.") }
        return "characters/" + id.lowercased()
    }
}

extension SkyStudioAPI {
    func characters(limit: Int = 50, cursor: String? = nil, status: String = "ready", key: String) async throws -> SkyStudioCharacterPage {
        guard (1...100).contains(limit), SkyStudioCharacter.statuses.contains(status), cursor == nil || UUID(uuidString: cursor!) != nil else {
            throw AIToolError("Character pages require limit 1–100, a returned UUID cursor and a supported status.")
        }
        var call = request("characters", key: key)
        var components = URLComponents(url: call.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "status", value: status)]
        if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        call.url = components.url
        let json = try JSONValue.decode(try await send(call))
        guard let list = json["characters"]?.arrayValue, list.count <= limit else { throw SkyStudioFailure.badAnswer(status: 200) }
        let next = json["next_cursor"]?.stringValue
        guard next == nil || UUID(uuidString: next!) != nil else { throw SkyStudioFailure.badAnswer(status: 200) }
        return try SkyStudioCharacterPage(characters: list.map(SkyStudioCharacter.init(json:)), nextCursor: next)
    }

    func character(_ id: String, key: String) async throws -> SkyStudioCharacter {
        let json = try JSONValue.decode(try await send(request(try SkyStudioCharacterPath.detail(id), key: key)))
        let value = try SkyStudioCharacter(json: json["character"] ?? .null)
        guard value.id.lowercased() == id.lowercased() else { throw SkyStudioFailure.badAnswer(status: 200) }
        return value
    }
}
