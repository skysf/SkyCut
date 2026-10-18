import SwiftUI

// MARK: - 导出面板底栏上「这次导出怎么样了」那几行
//
// 管什么：这个工程的导出 —— 进度条、报错、做好的文件（在访达里显示）、成片的响度和限幅提醒
// （docs/architecture/export-audio-mixdown.md 第二节第 3 条）；导出器在导**别的工程**时只写一行「谁在导、导到多少」。
// 不管什么：开始 / 停止导出（面板底栏的按钮）；导出本身（`VideoEditExporter`）。
//
// 导出器全 App 一个，几个工程窗口都看着它：进度、成片、报错只给发起导出的那个工程看（`exporter.belongs(to:)`），
// 不然 p1 的面板里会显示 p3 的 AI 导出、导完还挂着 p3 的成片（docs/bugfixes/2026-10-18-export-progress-shown-in-every-project-window.md）。

struct VideoEditExportStatus: View {
    let project: VideoEditProject
    @ObservedObject var exporter: VideoEditExporter

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if exporter.belongs(to: project) {
            if exporter.isExporting {
                ProgressView(value: exporter.progress) {
                    Text(String(format: L10n("Exporting… %@"), MediaFormatting.percent(exporter.progress)))
                        .font(.caption)
                }
            }
            if let error = exporter.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            if let finished = exporter.finishedURL {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(finished.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Show in Finder") { revealInFinder(finished) }
                        .instantHelp("Reveal the exported file in Finder")
                        .controlSize(.small)
                }
                if let levels = exporter.finishedAudioLevels {
                    audioLevelsRows(levels)
                }
            }
        } else if exporter.isExporting, let owner = exporter.owner {
            // 导出器一次只导一条：别的工程在导，这里的「导出」是灰的，说清楚在等谁。
            Text(String(format: L10n("“%1$@” is exporting… %2$@. This project can export when it is done."),
                        owner.name, MediaFormatting.percent(exporter.progress)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 总是一行「响度 · 峰值」；限幅器压过的再加一句橙字：压了多久多深，压得超过 3 dB 就建议把主音量降下来。
    @ViewBuilder
    private func audioLevelsRows(_ levels: ExportAudioMixdown.Levels) -> some View {
        let peak = String(format: "%.1f", levels.outputPeakDBFS)
        Text(levels.loudnessLUFS.map { String(format: L10n("Loudness %@ LUFS · Peak %@ dBFS"), String(format: "%.1f", $0), peak) }
             ?? String(format: L10n("Peak %@ dBFS"), peak))
            .font(.caption)
            .foregroundStyle(.secondary)
        if levels.isLimited {
            let seconds = String(format: "%.2f", levels.limitedSeconds), depth = String(format: "%.1f", levels.maxReductionDB)
            Text(levels.needsAttention
                 ? String(format: L10n("The sound went over -1 dBFS for %@ s and was pushed down by up to %@ dB. Lowering the master volume by %@ dB would be cleaner."),
                          seconds, depth, String(format: "%.1f", levels.suggestedReductionDB))
                 : String(format: L10n("The sound went over -1 dBFS for %@ s and was pushed down by up to %@ dB."), seconds, depth))
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
