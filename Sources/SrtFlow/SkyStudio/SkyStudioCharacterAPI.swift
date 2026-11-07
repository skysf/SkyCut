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
    func characterCapabilities(key: String) async throws -> SkyStudioCharacterCapabilities {
        try SkyStudioCharacterCapabilities(json: JSONValue.decode(try await send(request("characters/capabilities", key: key))))
    }

    func mutateCharacter(_ mutation: SkyStudioCharacterMutation, key: String) async throws -> JSONValue {
        var path = try SkyStudioCharacterPath.detail(mutation.id)
        if let role = mutation.role {
            guard SkyStudioCharacter.roles.contains(role) else { throw AIToolError("Unknown character role.") }
            path += "/images/" + role
        }
        let value = try JSONValue.decode(try await send(request(path, key: key, method: mutation.method, body: mutation.body.jsonData)))
        if mutation.method == "DELETE" {
            guard value["deleted"] == true, value["character_id"]?.stringValue == mutation.id else { throw SkyStudioFailure.badAnswer(status: 200) }
        } else {
            let character = try SkyStudioCharacter(json: value["character"] ?? .null)
            guard character.id == mutation.id else { throw SkyStudioFailure.badAnswer(status: 200) }
        }
        return value
    }
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

private extension Dictionary where Key == String, Value == JSONValue {
    var jsonData: Data { get throws { try JSONValue.object(self).encodedData() } }
}
