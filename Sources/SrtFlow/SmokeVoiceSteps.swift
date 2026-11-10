import Combine
import SwiftUI

// MARK: - 冒烟驱动：设置里的声音库（新建声音、设计声音、删声音）
//
// 管什么：进程内驱动够不着的那几样，由 `voice` 这一步替它们做**同一件事**：
// - 「新建声音…」「设计声音…」「新建」「设计」这类按钮背后是 NSButton，点了卡在跟踪循环里（gui-smoke-testing.md 第 12 条）：
//   这里发一声，由那一节 / 那张 sheet 自己调按钮调的那个函数（摆出同一张 sheet、`submit()`、按「设计」的那一句、确认框里的「删除」）；
// - 输入框要 key 窗口才收字（第 10 条）、「选择文件…」是系统的打开面板：往那张 sheet 自己的那一份模型里填字、用文件、勾授权 ——
//   和输入框、打开面板、勾选框写进去的一模一样。
// 其余全照真的走：参考录音、语言检测、授权那句、报价、交、任务、列表都是界面那一份；每一步把模型此刻的样子写进日志。
// 只在冒烟进程里响（SmokeDriver.isRequested）；正式包里没人发，订阅的那几个修饰器什么都不做。
// 不管什么：步骤表的格式（SmokeScript）、执行顺序（SmokeDriver）、声音库本身（VoiceLibraryStore / NewVoiceModel / DesignVoiceModel）。
//
//   {"do": "show", "panel": "settings"}，再 {"do": "show", "panel": "settings:editing"}   摆出设置、切到「剪辑与声音」（SmokeUISteps）
//   {"do": "voice", "kind": "list"}                            日志写声音库此刻的样子（阶段、我的声音、在设计的、提示）
//   {"do": "voice", "kind": "new"} / {"kind": "design"}       摆出「新建声音」/「设计声音」那张 sheet
//   {"do": "voice", "kind": "name", "text": "T2 Voice"}       名字（哪张开着填哪张）
//   {"do": "voice", "kind": "file", "path": "/abs/a.wav"}     「选一个文件」：用这个文件，等参考录音做好、语言检测完
//   {"do": "voice", "kind": "language", "text": "zh"}         改录音的语言
//   {"do": "voice", "kind": "agree", "text": "true"}          授权那一勾
//   {"do": "voice", "kind": "submit"}                          按「新建」：等交完（日志写 sheet 收没收起、挂着的 sheet）
//   {"do": "voice", "kind": "close"}                           和点「取消」一样把开着的 sheet 收起来
//   {"do": "voice", "kind": "prompt", "text": "…"} / {"kind": "sample", "text": "…"}   设计的描述 / 试读句
//   {"do": "voice", "kind": "quote", "timeout": 60}            等报价回来，日志写哪家的模型、多少积分
//   {"do": "voice", "kind": "order", "text": "22.5"}           按「设计」—— 报价不是这个数就不按（花钱之前停下）
//   {"do": "voice", "kind": "wait", "text": "T2 Voice", "timeout": 300}   等列表里出现这个名字（设计做完）
//   {"do": "voice", "kind": "delete", "text": "T2 Voice"}     点那一行的垃圾桶（弹出「删除『X』？」）
//   {"do": "voice", "kind": "confirm"}                         在「删除『X』？」里按「删除」：等它从列表里消失

@MainActor
final class SmokeVoiceHub {
    static let shared = SmokeVoiceHub()
    /// 发给声音库那一节和开着的 sheet：`new` / `design` / `delete:<id>` / `confirm` / `close` / `submit` / `order`。
    let request = PassthroughSubject<String, Never>()
    /// 开着的那张 sheet 背后的那一份（sheet 出现时登记、收起时清掉）。
    weak var newVoice: NewVoiceModel?
    weak var design: DesignVoiceModel?
}

extension View {
    /// 声音库那一节：冒烟的 `new` / `design` / `delete:<id>` / `confirm` 落到这一节自己的状态上（和点那几个按钮一样）。
    func smokeVoiceLibrary(store: VoiceLibraryStore, sheet: Binding<VoiceLibrarySheet?>, deleting: Binding<SkyStudioVoice?>,
                           confirmDelete: @escaping () -> Void) -> some View {
        modifier(SmokeVoiceLibraryModifier(store: store, sheet: sheet, deleting: deleting, confirmDelete: confirmDelete))
    }

    /// 「新建声音」那张：登记它的模型；`submit` 调按钮的那个函数。
    func smokeVoiceSheet(newVoice: NewVoiceModel, submit: @escaping () -> Void) -> some View {
        modifier(SmokeVoiceSheetModifier(register: { SmokeVoiceHub.shared.newVoice = newVoice },
                                         unregister: { if SmokeVoiceHub.shared.newVoice === newVoice { SmokeVoiceHub.shared.newVoice = nil } },
                                         command: "submit", action: submit))
    }

    /// 「设计声音」那张：登记它的模型；`order` 调「设计」按钮的那个函数。
    func smokeVoiceSheet(design: DesignVoiceModel, order: @escaping () -> Void) -> some View {
        modifier(SmokeVoiceSheetModifier(register: { SmokeVoiceHub.shared.design = design },
                                         unregister: { if SmokeVoiceHub.shared.design === design { SmokeVoiceHub.shared.design = nil } },
                                         command: "order", action: order))
    }
}

private struct SmokeVoiceLibraryModifier: ViewModifier {
    let store: VoiceLibraryStore
    let sheet: Binding<VoiceLibrarySheet?>
    let deleting: Binding<SkyStudioVoice?>
    let confirmDelete: () -> Void

    func body(content: Content) -> some View {
        let _ = PerfCounters.body(Self.self)
        content.onReceive(SmokeVoiceHub.shared.request) { request in
            guard SmokeDriver.isRequested else { return }
            switch request {
            case "new": sheet.wrappedValue = .new
            case "design": sheet.wrappedValue = .design
            case "confirm": confirmDelete()
            case "close": sheet.wrappedValue = nil
            default:
                guard request.hasPrefix("delete:") else { return }
                let id = String(request.dropFirst("delete:".count))
                deleting.wrappedValue = store.voices.first { $0.id == id }
            }
        }
    }
}

private struct SmokeVoiceSheetModifier: ViewModifier {
    let register: () -> Void
    let unregister: () -> Void
    let command: String
    let action: () -> Void

    func body(content: Content) -> some View {
        let _ = PerfCounters.body(Self.self)
        content
            .onAppear { if SmokeDriver.isRequested { register() } }
            .onDisappear { unregister() }
            .onReceive(SmokeVoiceHub.shared.request) { request in
                if SmokeDriver.isRequested, request == command { action() }
            }
    }
}

@MainActor
enum SmokeVoiceSteps {
    private static var hub: SmokeVoiceHub { .shared }
    private static var store: VoiceLibraryStore { .shared }

    static func run(_ step: SmokeStep) async throws -> String {
        let text = step.text ?? ""
        switch step.kind {
        case "list":
            return describe()
        case "new", "design":
            hub.request.send(step.kind!)
            try await until("「\(step.kind!)」那张 sheet 出来", seconds: 10) { step.kind == "new" ? hub.newVoice != nil : hub.design != nil }
            return "摆出 \(step.kind!)"
        case "name":
            if let model = hub.newVoice { model.name = text } else if let model = hub.design { model.name = text } else { throw closed() }
            return "名字：\(text)"
        case "file":
            guard let model = hub.newVoice else { throw closed() }
            guard case .file(let path) = step.path else { throw SmokeScriptError("voice file 要写 \"path\": \"/绝对路径\"") }
            model.source = .file
            model.use(file: URL(fileURLWithPath: path))
            try await until("参考录音做好、语言检测完", seconds: step.timeout ?? 120) {
                switch model.sample {
                case .ready: return !model.detectingLanguage
                case .failed: return true
                case .none, .preparing: return false
                }
            }
            return describe(model)
        case "language":
            guard let model = hub.newVoice else { throw closed() }
            model.choose(language: text.isEmpty ? nil : text)
            return describe(model)
        case "agree":
            guard let model = hub.newVoice else { throw closed() }
            model.setAgreed(text != "false")
            return describe(model)
        case "submit":
            guard let model = hub.newVoice else { throw closed() }
            let name = model.name
            hub.request.send("submit")
            // 交完 = 不在交了，而且 sheet 收起了 / 出错了 / 列表里有了这个名字（收没收起另说，日志里写）。
            try await until("「新建」交完", seconds: step.timeout ?? 180) {
                !model.submitting && (hub.newVoice == nil || model.problem != nil || store.voices.contains { $0.name == name })
            }
            try await Task.sleep(for: .seconds(1))
            return "交完：sheet \(hub.newVoice == nil ? "收起了" : "还开着")（挂着的 sheet \(attachedSheets())）"
                + (model.problem.map { "，出错：\($0)" } ?? "") + "；" + describe()
        case "close":
            // 和点「取消」一样把 sheet 收起来（那一节的状态清掉）。
            hub.request.send("close")
            try await until("sheet 收起", seconds: 10) { hub.newVoice == nil && hub.design == nil }
            return "收起了 sheet（挂着的 sheet \(attachedSheets())）"
        case "prompt", "sample":
            guard let model = hub.design else { throw closed() }
            if step.kind == "prompt" { model.prompt = text } else { model.sampleText = text }
            return "\(step.kind!)：\(text.count) 个字"
        case "quote":
            guard let model = hub.design else { throw closed() }
            try await until("报价回来", seconds: step.timeout ?? 60) {
                switch model.offer {
                case .ready, .failed: return true
                case .none, .loading: return false
                }
            }
            return describe(model)
        case "order":
            guard let model = hub.design else { throw closed() }
            guard let quote = model.quote else { throw SmokeScriptError("voice order：还没有报价（\(describe(model))）") }
            if let expected = Double(text), abs(quote.credits - expected) > 0.001 {
                throw SmokeScriptError("voice order：报价 \(quote.credits) 积分，不是写好的 \(expected)：不按（花钱之前停下）")
            }
            hub.request.send("order")
            try await until("「设计」按下去", seconds: step.timeout ?? 30) { hub.design == nil || model.problem != nil || model.ordered }
            try await Task.sleep(for: .seconds(1))
            return "按了：已下单 \(model.ordered)，sheet \(hub.design == nil ? "收起了" : "还开着")（挂着的 sheet \(attachedSheets())）"
                + (model.problem.map { "，出错：\($0)" } ?? "") + "；" + describe()
        case "wait":
            try await until("列表里出现「\(text)」", seconds: step.timeout ?? 300) {
                store.voices.contains { $0.name == text } || (store.notice?.contains(text) ?? false)
            }
            return describe()
        case "delete":
            guard let voice = store.voices.first(where: { $0.name == text }) else { throw SmokeScriptError("voice delete：列表里没有「\(text)」") }
            hub.request.send("delete:" + voice.id)
            try await Task.sleep(for: .milliseconds(800))
            return "点了「\(text)」（\(voice.id)）的垃圾桶"
        case "confirm":
            let before = Set(store.voices.map(\.id))
            hub.request.send("confirm")
            try await until("删完", seconds: step.timeout ?? 60) {
                store.working.isEmpty && (Set(store.voices.map(\.id)) != before || store.notice != nil)
            }
            return describe()
        default:
            throw SmokeScriptError("voice 的 kind 不认识：\(step.kind ?? "nil")")
        }
    }

    /// 此刻挂在哪个窗口上的 sheet（窗口标题 → sheet 的类）。
    private static func attachedSheets() -> [String] {
        NSApp.windows.compactMap { window in window.attachedSheet.map { "\(window.title.isEmpty ? "#\(window.windowNumber)" : window.title) → \(type(of: $0))" } }
    }

    private static func closed() -> SmokeScriptError { SmokeScriptError("voice：没有开着的「新建声音」/「设计声音」sheet") }

    private static func until(_ what: String, seconds: Double, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            guard Date() < deadline else { throw SmokeScriptError("voice：\(Int(seconds)) 秒还没等到\(what)") }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// 声音库此刻的样子：阶段、授权那句的版本、我的声音（名字、id、来源、语言和有没有 MiniMax 版）、在设计的、提示。
    private static func describe() -> String {
        let voices = store.voices.map { voice in
            "\(voice.name)（\(voice.id)，\(voice.source)：" + voice.languages.map { "\($0.language)\($0.minimax ? "+minimax" : "")" }.joined(separator: "/") + "）"
        }
        return "声音库 \(store.phase)，授权那句 \(store.consentStatement?.version ?? "nil")，我的声音 \(voices)，在设计 \(store.designing)"
            + (store.notice.map { "，提示：\($0)" } ?? "")
    }

    private static func describe(_ model: NewVoiceModel) -> String {
        let sample: String
        switch model.sample {
        case .none: sample = "还没有"
        case .preparing: sample = "在做"
        case .failed(let message): sample = "做不成：\(message)"
        case .ready(let made):
            sample = String(format: "%.2f–%.2f 秒（文件 %.2f 秒，有效人声 %.2f 秒%@）", made.sourceStart, made.sourceEnd, made.fileSeconds,
                            made.voicedSeconds, made.autoSelected ? "，自动挑的" : "")
        }
        return "新建声音：名字「\(model.name)」，录音 \(model.fileName ?? "nil")，参考 \(sample)，语言 \(model.language ?? "nil")，"
            + "勾了授权 \(model.agreed)，还差 \(String(describing: model.blocker))" + (model.problem.map { "，出错：\($0)" } ?? "")
    }

    private static func describe(_ model: DesignVoiceModel) -> String {
        switch model.offer {
        case .none: return "设计声音：还没填够"
        case .loading: return "设计声音：在问价"
        case .failed(let message): return "设计声音：报不了价：\(message)"
        case .ready(let quote):
            return "设计声音：报价 \(quote.credits) 积分（约 \(quote.creditsExpected.map { "\($0)" } ?? "?")），模型 \(quote.model ?? "nil")，"
                + "结算 \(quote.settlement ?? "nil")，已下单 \(model.ordered)"
        }
    }
}

/// 冒烟截图的另一条路：App 自己把窗口（连标题栏）画成 PNG。外面拍不了（没有录屏权限）时用（SRTFLOW_SMOKE_SELF_SNAPSHOT）。
@MainActor
enum SmokeSelfSnapshot {
    static func write(_ window: NSWindow, to picture: URL) -> Bool {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: picture)) != nil
    }
}
