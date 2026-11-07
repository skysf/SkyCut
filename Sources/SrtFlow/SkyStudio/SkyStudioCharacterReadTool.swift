import Foundation
import SrtFlowMCPKit

// 两个免费只读工具：账户的角色页和最新详情。没有上传、预算预留或时间线操作。
@MainActor
enum SkyStudioCharacterReadTool {
    static func read(_ tool: MCPToolName, _ args: AIToolArguments) async throws -> AIToolResult {
        let key = try await SkyStudioOfficialGenerateTool.readKey()
        let stamp = SkyStudioCharacterAccess.stamp(key)
        do {
            var result: JSONValue
            if tool == .getCharacter {
                result = ["character": try await SkyStudioCharacterCache.shared.character(args.requiredString("character_id"), key: key).json]
            } else {
                result = try await SkyStudioCharacterCache.shared.page(limit: args.int("limit") ?? 50, cursor: args.string("cursor"),
                    status: args.choice("status", from: SkyStudioCharacter.statuses) ?? "ready", key: key).json
                if try args.bool("capabilities") == true {
                    var fields = result.objectValue!
                    fields["capabilities"] = try await SkyStudioCharacterCache.shared.capabilities(key: key).json
                    result = .object(fields)
                }
            }
            guard SkyStudioCharacterAccess.stamp(key) == stamp else { throw SkyStudioCharacterError.changed }
            return .ok(result)
        } catch { throw SkyStudioCharacterError.tool(error) }
    }
}
