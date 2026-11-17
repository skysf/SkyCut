import CryptoKit
import Foundation

// A new AI-written page asks once in request-approval mode. The token is bound to the complete call and document identity.
@MainActor
enum AIMotionApproval {
    static func check(_ args: AIToolArguments, request: AIMotionRequest, project: VideoEditProject,
                      access: AIAccessStore = .shared) throws -> AIToolResult? {
        let token = try args.string("confirm_token")
        guard request.needsPageApproval, access.mode == .ask else { return nil }
        var values = args.raw.objectValue ?? [:]
        values["confirm_token"] = nil
        values["document_generation"] = .number(Double(project.documentGeneration))
        values["resolved_parameters"] = .string(request.record.parametersJSON)
        values["resolved_at"] = request.at.map { .number($0) } ?? .null
        let data = Data(try WebMotionParameters.canonical(values).utf8)
        let action = "web-motion:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let redemption = AIConfirmations.shared.redeem(token, for: action)
        guard redemption != .accepted else { return nil }
        return AIConfirmations.shared.ask(
            "Allow this AI-written motion page to run in SkyCut's isolated renderer on this Mac? Network and file access stay blocked. "
                + "It will render \(request.record.duration) s of video for \(project.projectName). No page has run and no clip has changed yet.",
            action: action, refused: redemption.refusal)
    }
}
