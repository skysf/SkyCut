import Foundation
import SrtFlowMCPKit

// MARK: - upscale_clip 的词：模型 / 目标 / 范围的名字 ↔ App 的类型（纯值）
//
// 管什么：AI 传来的 `tier` / `target` / `range` 认成 Sky Studio 的模型名 / `UpscaleTarget` / `UpscaleRangeChoice`，以及反过来写回结果里。
// 词表在小程序那份清单里（MCPVocabulary.upscaleTiers / upscaleTargets / upscaleRanges），自检逐项对账（checks/MCP/UpscaleToolChecks.swift）。
// 模型本身（有没有、能升到哪几档、上限）照 Sky Studio 的 /models（UpscaleTier）：词表里有、服务器那边没有的，调用时说清楚。
// 不管什么：工具本身（AIUpscaleTool）。

enum AIUpscaleNames {
    /// 没点名模型时用的（面板的默认也是它）。
    static var defaultTierID: String { UpscaleTier.defaultID }

    /// 「1080p」「1440p」「2160p」：按短边叫（4K 写成 2160p，和导出的档位一个口径；Sky Studio 那边叫 1080p / 2K / 4K）。
    static func target(_ name: String) -> UpscaleTarget? {
        UpscaleTarget.allCases.first { self.name(of: $0) == name }
    }

    static func name(of target: UpscaleTarget) -> String { "\(target.shortSide)p" }

    /// 「clip」这一段 / 「longest」工程里最长的那处 / 「file」整个文件。
    static func range(_ name: String) -> UpscaleRangeChoice? {
        switch name {
        case "clip": return .thisClip
        case "longest": return .longestUse
        case "file": return .wholeFile
        default: return nil
        }
    }

    static func name(of range: UpscaleRangeChoice) -> String {
        switch range {
        case .thisClip: return "clip"
        case .longestUse: return "longest"
        case .wholeFile: return "file"
        }
    }
}
