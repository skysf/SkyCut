import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - 动效预设：界面上的几个动作
//
// 管什么：加字的「动效预设」一栏点了哪一套（`add`：放在播放头、选中标题、浮出就地编辑）、检查器「动画」区的「预设」换了哪一套
// （`apply`：字不变；选「无」= 拆成普通的字和形状）、「落点」改了（`setHit` / `liveHit`：整套一起挪）。每个动作一次 `perform` =
// 一步撤销；拖着改落点走 `liveApply`，松手由数值框收成一步。规则都在 MotionPresetGroups（AI 的 set_text 走同一份）。
// 不管什么：预设长什么样、怎么摆（MotionPresetDesign / MotionPresetLayout）、界面本身（MotionPresetPanel、MotionPresetInspectorRow）。

@MainActor
enum MotionPresetActions {
    /// 从面板加的那一套先用的字（跟着界面语言）。字是占位：放上去就浮出就地编辑，打字直接换掉（输入框起手全选）。
    /// 不用空字：框要按字量出来，空字量不出大小。
    static func placeholder(_ kind: MotionPresetKind, hit: Double) -> MotionPresetSpec {
        switch kind {
        case .frameReveal:
            var spec = MotionPresetSpec(kind: kind, title: L10n("YOUR NAME"), hit: hit)
            spec.small = L10n("FROM")
            return spec
        case .focusPull:
            var spec = MotionPresetSpec(kind: kind, title: L10n("YOUR NAME"), hit: hit)
            spec.small = L10n("PRESENTS")
            spec.smallBelow = true
            return spec
        case .titleCounter:
            var spec = MotionPresetSpec(kind: kind, title: L10n("TITLE"), hit: hit)
            spec.number = placeholderNumber
            return spec
        }
    }

    /// 标题 + 数字先用的数：0 滚到 1,000。
    static var placeholderNumber: NumberRoll {
        var roll = MotionPresetGroups.counterRoll(from: nil)
        roll.to = 1_000
        return roll
    }

    /// 加字的「动效预设」一栏：在播放头放一套，选中标题、浮出就地编辑（同加一段字）。
    static func add(_ kind: MotionPresetKind, to project: VideoEditProject) {
        let spec = placeholder(kind, hit: max(0, project.clock.time))
        let built = MotionPresetGroups.build(spec, canvas: TimelineRenderSize.size(for: project.state))
        project.perform(rebuildsPreview: false) { MotionPresetGroups.place(built, in: &$0) }
        guard let title = built.anchorText else { return }
        project.selectedTextIDs = [title.id]
        project.textEditingRequest = title.id
    }

    /// 检查器的「预设」：换成另一套（字、落点、位置不变），nil = 拆成普通的字和形状（每一块原样留着）。
    static func apply(_ kind: MotionPresetKind?, toText id: UUID, project: VideoEditProject) {
        let current = MotionPresetGroups.members(ofText: id, in: project.state)
        guard let kind else {
            if let current { project.perform(rebuildsPreview: false) { MotionPresetGroups.detach(current.group, in: &$0) } }
            return
        }
        guard current?.kind != kind else { return }
        var title: UUID?
        project.perform(rebuildsPreview: false) { state in
            title = MotionPresetGroups.reapply(kind, toText: id, in: &state) { spec in
                // 一段数字元件变成标题 + 数字：它当那个数字，标题先用占位（变成另两套时它自己就是标题，MotionPresetGroups.build）；
                // 换成标题 + 数字而没有数字的，先用占位的数。
                if spec.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, kind == .titleCounter || spec.number == nil {
                    spec.title = L10n("TITLE")
                }
                if kind == .titleCounter, spec.number == nil { spec.number = placeholderNumber }
            }?.anchorText?.id
        }
        if let title { project.selectedTextIDs = [title] }
    }

    /// 「落点」打字 / 步进箭头：整套挪过去，一步撤销。
    static func setHit(_ time: Double, ofText id: UUID, project: VideoEditProject) {
        guard let group = MotionPresetGroups.members(ofText: id, in: project.state)?.group else { return }
        project.perform(rebuildsPreview: false) { MotionPresetGroups.move(group, toHit: time, in: &$0) }
    }

    /// 「落点」横着拖：每一拍从手势开始时的快照重放（`liveApply`），松手由数值框 `endLiveEdit` 收成一步。
    static func liveHit(_ time: Double, ofText id: UUID, project: VideoEditProject) {
        guard let group = MotionPresetGroups.members(ofText: id, in: project.state)?.group else { return }
        project.liveApply { MotionPresetGroups.move(group, toHit: time, in: &$0) }
    }
}
