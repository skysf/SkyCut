import SwiftUI
import SrtFlowCore

// MARK: - 文字检查器：「动画」区最上面的「预设」
//
// 管什么：选中一段字时「动画」那一块最上面的两行（2026-11-16 用户定的位置）：「预设」下拉 —— 换一套动效，字不变；
// 选「无」= 拆成普通的字和形状；这段字在一套里时多一行「落点」—— 改它整套一起挪（打字 / 箭头一步撤销，横着拖松手收一步）。
// 动作都在 MotionPresetActions（AI 的 set_text 走同一份规则 MotionPresetGroups）。
// 不管什么：入场 / 出场 / 强调那几行（VideoEditInspector+TextAnimation.swift）、每一块自己的样式。
// 一行不比检查器那条窄栏宽：标题 52pt + 能收缩的下拉（docs/architecture/inspector-layout.md）。

struct MotionPresetInspectorRow: View {
    let project: VideoEditProject
    let overlayID: UUID

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let members = MotionPresetGroups.members(ofText: overlayID, in: project.state)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Preset").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                Picker("", selection: presetBinding(members?.kind)) {
                    Text("None").tag(MotionPresetKind?.none)
                    ForEach(MotionPresetKind.allCases) { kind in
                        Text(LocalizedStringKey(kind.title)).tag(MotionPresetKind?.some(kind))
                    }
                }
                .labelsHidden()
                .instantHelp("A ready-made animated title: swap it here and the words stay")
            }
            if let members {
                HStack(spacing: 6) {
                    Text("Hit at").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    InspectorScrubbableNumberField(
                        // `value` 是离散通道（打字、步进箭头 → 一步撤销），横向拖动走下面三个回调（同动画时长那一格）。
                        value: hitBinding(members.hit),
                        range: 0...86_400,
                        fractionDigits: 2,
                        width: 64,
                        onScrubBegin: { project.beginLiveEdit() },
                        onScrubChanged: { MotionPresetActions.liveHit($0, ofText: overlayID, project: project) },
                        onScrubEnd: { project.endLiveEdit(rebuildsPreview: false) },
                        onScrubCancel: { project.cancelLiveEdit() }
                    )
                    Text("s").font(.caption2).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .instantHelp("When the preset lands; changing it moves every piece together")
                Text("Each piece is an ordinary text or shape you can change. Moving or retyping the title brings the rest along.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 离散写入：下拉选一套 = 一步撤销。
    private func presetBinding(_ current: MotionPresetKind?) -> Binding<MotionPresetKind?> {
        Binding(
            get: { current },
            set: { MotionPresetActions.apply($0, toText: overlayID, project: project) }
        )
    }

    /// 离散写入：打字、步进箭头 = 一步撤销。
    private func hitBinding(_ current: Double) -> Binding<Double> {
        Binding(
            get: { MotionPresetGroups.members(ofText: overlayID, in: project.state)?.hit ?? current },
            set: { MotionPresetActions.setHit($0, ofText: overlayID, project: project) }
        )
    }
}
