import SwiftUI

// MARK: - Upscale 面板（sheet）
//
// 管什么：选范围（这一段 / 工程里最长的那处 / 整个文件）、目标分辨率、模型，看 Sky Studio 的报价（积分），点「开始」起任务。
// 面板本身就是花钱的确认（upscale 方案第 10 条）：超过每日积分上限只标红不拦；没有 Sky Studio 的 Key、报价没回来、这一段送不了才拦。
// 模型和价从 Sky Studio 来（UpscaleOffers：/models、/quote），别的数从 UpscalePanelModel 来；起的任务进 UpscaleActivity（做完弹对比窗口，不自动替换）。
// 本地化：sheet 不继承应用内语言，调用处套 `.appLanguage()`（checks/presented-views-app-language.sh）。
// 不管什么：任务本身（UpscaleJob）、换源（VideoEditProject+Upscale）。

struct UpscalePanel: View {
    let project: VideoEditProject
    let model: UpscalePanelModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var spend = SkyStudioSpendStore.shared
    @StateObject private var offers = UpscaleOffers()
    @State private var choice: UpscaleRangeChoice
    @State private var target: UpscaleTarget
    @State private var tierID: String?

    init(project: VideoEditProject, model: UpscalePanelModel) {
        self.project = project
        self.model = model
        _choice = State(initialValue: model.defaultChoice)
        _target = State(initialValue: model.defaultTarget)
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let rows = model.rows(tiers: offers.tiers, choice: choice, target: target)
        let selected = rows.first { $0.id == tierID } ?? rows.first
        VStack(alignment: .leading, spacing: 14) {
            header
            rangeSection(selected?.tier)
            targetSection
            tierSection(rows: rows, seconds: model.range(for: choice, tier: selected?.tier).duration)
            footer(selected: selected)
        }
        .padding(20)
        .frame(width: 720)
        .task {
            await offers.load()
            if tierID == nil { tierID = UpscalePanelModel.defaultTier(in: offers.tiers, target: target)?.id }
            askForQuotes()
        }
        .onChange(of: choice) { _, _ in askForQuotes() }
        .onChange(of: target) { _, _ in askForQuotes() }
    }

    private func askForQuotes() {
        for row in model.rows(tiers: offers.tiers, choice: choice, target: target) where row.refusal == nil {
            _ = offers.quote(row.quote)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Upscale Clip").font(.title3).fontWeight(.semibold)
            let info = model.originalInfo
            Text(verbatim: "\(model.clipName) · \(info.resolutionLabel) · \(Int(info.frameRate.rounded())) fps · \(MediaFormatting.duration(info.duration))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func rangeSection(_ tier: UpscaleTier?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What to upscale").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            if let longer = model.longerElsewhere {
                Label(
                    String(format: L10n("This file is also used by another clip in this project (%@). Upscaling the longest range covers both places."),
                           seconds(longer.duration)),
                    systemImage: "info.circle"
                )
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
            rangeRow(.thisClip, tier: tier, title: L10n("This clip only"),
                     detail: model.thisUse.map { String(format: L10n("%@ used, plus %@ of handles on each side"), seconds($0.duration), seconds(UpscaleRange.handle)) } ?? "")
            if model.uses.count > 1 {
                rangeRow(.longestUse, tier: tier, title: L10n("Longest use in this project (recommended)"),
                         detail: UpscaleRange.longestUse(model.uses).map { String(format: L10n("%@ used by another clip, plus handles; covers this clip too"), seconds($0.duration)) } ?? "")
            }
            rangeRow(.wholeFile, tier: tier, title: L10n("Whole file"), detail: L10n("Every use now and any future trim"))
            if let limit = tier?.maxSourceSeconds {
                Text(String(format: L10n("Sky Studio upscales at most %@ s at a time, handles included."), String(Int(limit.rounded(.down)))))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func rangeRow(_ option: UpscaleRangeChoice, tier: UpscaleTier?, title: String, detail: String) -> some View {
        let seconds = model.range(for: option, tier: tier).duration
        return Button {
            choice = option
        } label: {
            HStack(spacing: 10) {
                Image(systemName: choice == option ? "largecircle.fill.circle" : "circle")
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "%.1f s", seconds)).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Target resolution").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            Picker("Target resolution", selection: $target) {
                ForEach(UpscaleTarget.allCases, id: \.self) { candidate in
                    Text(verbatim: candidate.label).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(target.shortSide <= model.canvasShortSide ? L10n("Matches the canvas.") : L10n("Larger than the canvas: raise the canvas size too, or the export will scale it back down."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func tierSection(rows: [UpscaleTierRow], seconds: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Model").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: L10n("Sky Studio credits for %@ of video"), String(format: "%.1f s", seconds)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch offers.catalog {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Asking Sky Studio for its upscale models…").font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let detail):
                Text(String(format: L10n("Could not get the upscale models from Sky Studio: %@"), detail))
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            case .ready:
                ForEach(rows) { row in
                    tierRow(row)
                }
            }
        }
    }

    private func tierRow(_ row: UpscaleTierRow) -> some View {
        let quote = offers.known(row.quote)
        let ready: SkyStudioQuote? = { if case .ready(let answer)? = quote { return answer } else { return nil } }()
        let size = UpscalePanelModel.outputSize(ready, fallback: row.estimatedSize)
        let blurb = UpscaleTier.blurb(for: row.id)
        return Button {
            if row.refusal == nil { tierID = row.id }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tierID == row.id ? "largecircle.fill.circle" : "circle")
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.tier.title).fontWeight(.medium)
                    if row.refusal == nil, case .failed(let detail)? = quote {
                        // Sky Studio 不肯报价（超过这一档的最大倍数、源已经不比目标小……）：照它的原话说为什么（服务器写给人看的英文）。
                        Text(verbatim: detail).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(row.refusal?.localized ?? (blurb.isEmpty ? "" : L10n(blurb))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(verbatim: "\(Int(size.width))×\(Int(size.height))").font(.caption).foregroundStyle(.secondary)
                if let typical = ready?.typicalSeconds {
                    Text(String(format: L10n("about %d min"), CloudJobProgress.minutes(typical)))
                        .font(.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
                }
                price(row, quote: quote).frame(width: 96, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .opacity(row.refusal == nil ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func price(_ row: UpscaleTierRow, quote: UpscaleOffers.Quote?) -> some View {
        if row.refusal != nil {
            Text(verbatim: "—").foregroundStyle(.secondary)
        } else {
            switch quote {
            case .ready(let answer)?:
                Text(String(format: L10n("%@ credits"), SkyStudioCredits.text(answer.credits))).fontWeight(.semibold).monospacedDigit()
            case .failed?:
                Text(verbatim: "—").foregroundStyle(.secondary)
            case .loading?, nil:
                ProgressView().controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private func footer(selected: UpscaleTierRow?) -> some View {
        let spent = spend.spentToday()
        let quote: SkyStudioQuote? = selected.flatMap { row in
            if case .ready(let answer)? = offers.known(row.quote) { return answer } else { return nil }
        }
        let overLimit = spent + (quote?.credits ?? 0) > spend.dailyLimit + 0.0005
        Divider()
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let selected {
                    let size = UpscalePanelModel.outputSize(quote, fallback: selected.estimatedSize)
                    Text(String(format: L10n("Saves next to the original as %@"), model.fileName(size: size, tier: selected.tier)))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text(String(format: L10n("Spent today %@ of your %@-credit daily limit"), SkyStudioCredits.text(spent), SkyStudioCredits.text(spend.dailyLimit)))
                    .font(.caption).foregroundStyle(overLimit ? .red : .secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button(quote.map { String(format: L10n("Upscale · %@ credits"), SkyStudioCredits.text($0.credits)) } ?? L10n("Upscale")) {
                if let selected, let quote { start(selected: selected, quote: quote) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(quote == nil || selected?.refusal != nil)
        }
    }

    /// 面板上的秒数一律「6.0 s」这种写法（m:ss 对一两秒的余料不好读）。
    private func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }

    private func start(selected: UpscaleTierRow, quote: SkyStudioQuote) {
        let request = model.request(choice: choice, target: target, tier: selected.tier, quote: quote)
        let job = UpscaleJob(request: request, clipIDs: request.range.coveredClipIDs,
            owner: CloudTasksActivity.owner(of: project), title: model.clipName)
        UpscaleActivity.shared.add(job)
        dismiss()
    }
}
