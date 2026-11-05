import Foundation
import SrtFlowMCPKit

// MARK: - 照授权拦：AI 的工具让不让用、导出带不带水印，被挡住时跟 AI 怎么说（纯值）
//
// 管什么：收费方案第 5 刀第二步的规矩。
// - 此刻的授权（SkyCutLicense）不让用 MCP：AI 的工具一个都不做，只有 get_status 照常回（AI 靠它看授权、跟用户说清楚）；
// - 导出带不带水印听服务器的 `watermark`（免费版、体验期带，正式版不带，都是服务器说了算）；
// - 回给 AI 的几句话（英文）：没做、为什么、请用户做什么；导出带了水印时为什么、怎么去掉；get_status 里的 `skycut_plan`。
// **照授权拦 2026-10-28 起默认打开**（`enforcedByDefault`）。合进来时先关着：Sky Studio 的接口上线、用户在后台给自己开了正式版之前
// 谁都问不到授权，一打开连用户自己的 AI 剪辑也挡住了。10-28 接口上线、用户的账号开了正式版、测试版对着真服务器走完回归之后打开。
// 测试开关只能打开、不能用它关掉；默认开着之后它不起作用，留着给哪天又得先关上时用：
//   defaults write com.srtflow.SrtFlow.beta skystudio.testGates -bool true（正式版把 .beta 去掉）
// 不管什么：授权怎么算（SkyCutLicense）、去问 / 等问完（SkyStudioAccount）、拦在哪（AIToolRouter、VideoEditExporter + WatermarkPolicy、
// 导出面板的 ExportWatermarkNotice、export_video、get_status）。

enum SkyCutGates {
    /// 照授权拦生不生效：2026-10-28 起打开（接口上线、用户给自己开了正式版、真服务器回归走完；checks/SkyStudio/GateChecks.swift 钉着）。
    static let enforcedByDefault = true
    /// 测试开关的 UserDefaults 键（只能打开；默认开着之后不起作用）。
    static let testingKey = "skystudio.testGates"

    static func enforced(_ defaults: UserDefaults = .standard) -> Bool {
        enforcedByDefault || defaults.bool(forKey: testingKey)
    }

    /// AI 调这个工具让不让做。get_status 永远让：没开通时 AI 靠它看授权、跟用户说清楚。
    static func aiAllows(_ tool: MCPToolName, license: SkyCutLicense, enforced: Bool) -> Bool {
        !enforced || tool == .getStatus || license.mcp
    }

    /// 导出要不要因为授权带水印（测试开关另算，在 WatermarkPolicy）。
    static func watermark(license: SkyCutLicense, enforced: Bool) -> Bool {
        enforced && license.watermark
    }

    // MARK: 跟 AI 说的话（英文）

    /// 下一步：台数满了先管理 Mac；其余和界面一样用购买地址 / 邮箱。只说英文。
    static func activatePro(license: SkyCutLicense) -> String {
        if license.isMachineLimited {
            let usage: String
            if let limit = license.machineLimit, limit > 0 {
                usage = "This account is already using SkyCut on \(limit) \(limit == 1 ? "Mac" : "Macs")."
            } else {
                usage = "This account has reached its Mac limit."
            }
            let action = license.manageMachinesURL.map {
                "Ask the user to open \($0.absoluteString) and remove a Mac in Sky Studio to use this account here."
            } ?? "Ask the user to email \(SkyStudioLinks.supportEmail) to use this account on this Mac."
            return usage + " This Mac is using the free plan. " + action
        }
        let explanation = license.unrecognizedPlanMessage.map { $0 + " " } ?? ""
        if let url = license.proActivationURL {
            return explanation + "To activate SkyCut Pro, ask the user to open \(url.absoluteString) and buy Pro for their Sky Studio account."
        }
        return explanation + "To activate SkyCut Pro, the user emails \(SkyStudioLinks.supportEmail) with the email address of their Sky Studio account."
    }

    /// 导出带了水印时告诉 AI：AI 用 look 看成片会看到它，要能跟用户说清楚为什么、怎么去掉。
    static func watermarkNote(license: SkyCutLicense) -> String {
        "This video carries the Sky Studio watermark (the logo moves between the corners and the center every "
            + "4 seconds). " + activatePro(license: license)
    }

    /// AI 被挡住时回的话：没做、为什么、请用户做什么。
    static func aiRefusal(license: SkyCutLicense, problem: SkyStudioProblem?, now: Date) -> String {
        var sentences = ["Not done: SkyCut's AI tools need SkyCut Pro or a SkyCut trial, and \(reason(license))."]
        if let snag = snag(problem) { sentences.append(snag) }
        sentences.append(nextStep(license, problem: problem))
        sentences.append("Nothing was changed; get_status shows the plan.")
        return sentences.joined(separator: " ")
    }

    /// get_status 里的 `skycut_plan`（照授权拦生效时才报；关着时什么都不拦，报了反倒让 AI 以为要开通）。
    static func statusJSON(license: SkyCutLicense, problem: SkyStudioProblem?, now: Date) -> JSONValue {
        var plan: [String: JSONValue] = [
            "plan": license.plan.map { .string($0.rawValue) } ?? .null,
            "source": .string(source(license.basis)),
            "ai_tools": .bool(license.mcp),
            "export_watermark": .bool(license.watermark)
        ]
        if let days = license.trialDaysLeft(now: now) { plan["trial_days_left"] = .number(Double(days)) }
        if license.plan == .pro, let until = license.paidUntil { plan["pro_until"] = .string(day(until)) }
        if let snag = snag(problem) { plan["problem"] = .string(snag) }
        if let message = license.unrecognizedPlanMessage { plan["plan_message"] = .string(message) }
        if !license.mcp {
            plan["next_step"] = .string(nextStep(license, problem: problem))
        } else if license.watermark {
            plan["next_step"] = .string("Exports carry the Sky Studio watermark until SkyCut Pro. " + activatePro(license: license))
        }
        if let notice = license.proNotice {
            let details = proNoticeJSON(notice)
            plan["pro_notice"] = .object(details)
            if plan["next_step"] == nil { plan["next_step"] = details["next_step"] }
        }
        return .object(plan)
    }

    // MARK: 几句话的零件

    /// 设置 / 导出同一份提醒，给 AI 的内容固定英文；只补说明，不参与 aiAllows / watermark。
    private static func proNoticeJSON(_ notice: SkyCutProNotice) -> [String: JSONValue] {
        var details: [String: JSONValue]
        let purpose: String
        switch notice.kind {
        case .expiring(let days):
            details = [
                "state": .string("expiring"), "days_left": .number(Double(days)),
                "message": .string("SkyCut Pro expires in \(days) \(days == 1 ? "day" : "days") and will not renew automatically.")
            ]
            purpose = "renew SkyCut Pro"
        case .paymentGrace(let until):
            let end = day(until)
            details = [
                "state": .string("payment_grace"), "until": .string(end),
                "message": .string("The renewal payment failed. SkyCut Pro is kept until \(end). Please update the payment method for the existing subscription.")
            ]
            purpose = "update the payment method for the existing subscription"
        }
        let action = notice.actionURL.map { "Ask the user to open \($0.absoluteString) to \(purpose)." }
            ?? "Ask the user to email \(SkyStudioLinks.supportEmail) to \(purpose)."
        details["next_step"] = .string(action)
        return details
    }

    /// 为什么不让用（接在「需要正式版或体验，而」后面）。
    private static func reason(_ license: SkyCutLicense) -> String {
        switch license.basis {
        case .noKey: return "no Sky Studio API key is set in SkyCut"
        case .notChecked: return "SkyCut has not been able to check the plan with Sky Studio yet"
        case .expired: return "SkyCut's last plan check with Sky Studio has run out"
        case .server:
            if license.isMachineLimited { return "this Mac is using the free plan" }
            guard license.plan == .free else { return "this Sky Studio account's SkyCut plan does not include AI editing" }
            return license.trialUnavailable == "machine_used"
                ? "this Sky Studio account is on the free plan: this Mac already had a SkyCut trial, so the account gets no trial on it"
                : "this Sky Studio account is on the free plan"
        }
    }

    /// 上一次问 Sky Studio 出了什么事（没出事、粘的不像 Key 都不说）。
    private static func snag(_ problem: SkyStudioProblem?) -> String? {
        switch problem {
        case .keyRejected(let message)?: return "Sky Studio did not accept the API key: \(message)"
        case .updateRequired(let message, _)?: return "Sky Studio needs a newer SkyCut: \(message)"
        case .unreachable?: return "SkyCut could not reach Sky Studio just now."
        case .needsKeychainPermission?: return "SkyCut needs the user's permission to read the API key from the macOS keychain."
        case .keychain?: return "The macOS keychain did not give SkyCut the API key."
        case .notAKey?, nil: return nil
        }
    }

    /// 请用户做什么。按钮的名字照设置里「Sky Studio」一节写（Allow…、Check Again）。
    private static func nextStep(_ license: SkyCutLicense, problem: SkyStudioProblem?) -> String {
        let activatePro = Self.activatePro(license: license)
        let pasteKey = "Ask the user to create an API key in Sky Studio (\(SkyStudioLinks.keysPage.absoluteString), or the avatar at the top "
            + "right → SkyCut) and paste it in SkyCut Settings → Sky Studio. "
        let machineAdvice = license.isMachineLimited ? " " + activatePro : ""
        switch problem {
        case .needsKeychainPermission?: return "Ask the user to open SkyCut Settings → Sky Studio and click Allow…, then try again." + machineAdvice
        case .updateRequired?: return "Ask the user to update SkyCut, then try again." + machineAdvice
        case .keyRejected?: return pasteKey + activatePro
        case .unreachable?, .keychain?, .notAKey?, nil: break
        }
        switch license.basis {
        case .noKey: return pasteKey + activatePro
        case .notChecked, .expired:
            return "Ask the user to check the internet connection and click Check Again in SkyCut Settings → Sky Studio, then try again."
        case .server: return activatePro
        }
    }

    private static func source(_ basis: SkyCutLicense.Basis) -> String {
        switch basis {
        case .server: return "sky_studio"
        case .noKey: return "no_key"
        case .notChecked: return "not_checked_yet"
        case .expired: return "check_expired"
        }
    }

    private static func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }
}
