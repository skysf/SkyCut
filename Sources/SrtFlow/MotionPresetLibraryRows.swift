import SwiftUI

// The shared library's ordered rows, independent of its bounded scrolling container. Native cards keep their original action.
struct MotionPresetLibraryRows: View {
    let project: VideoEditProject
    let entries: [MotionPresetLibrary.Entry]
    var onPick: () -> Void = {}

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let firstOfficial = entries.first { if case .official = $0 { return true }; return false }?.id
        let firstProject = entries.first { if case .web = $0 { return true }; return false }?.id
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { entry in
                switch entry {
                case .native(let kind):
                    MotionPresetCard(kind: kind) {
                        MotionPresetActions.add(kind, to: project)
                        onPick()
                    }
                case .official(let template):
                    if entry.id == firstOfficial {
                        Divider().padding(.top, 4)
                        Text("Official Templates").font(.subheadline.weight(.semibold))
                    }
                    OfficialWebMotionPresetCard(project: project, template: template, onPick: onPick)
                case .web(_, let record, let movie):
                    if entry.id == firstProject {
                        Divider().padding(.top, 4)
                        Text("Project Templates").font(.subheadline.weight(.semibold))
                        Text("Rendered motions; change their words and style in the inspector.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    WebMotionPresetCard(project: project, entryID: entry.id, record: record, movie: movie, onPick: onPick)
                }
            }
        }
    }
}
