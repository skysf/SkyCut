import SwiftUI

// A project page in the same library as native presets. Add starts at the captured playhead; dragging captures a timeline drop.
struct WebMotionPresetCard: View {
    let project: VideoEditProject
    let entryID: String
    let record: WebMotionClipRecord
    let movie: URL
    var onPick: () -> Void = {}
    @State private var hovering = false
    @State private var model: WebMotionPresetModel

    init(project: VideoEditProject, entryID: String, record: WebMotionClipRecord, movie: URL, onPick: @escaping () -> Void = {}) {
        self.project = project
        self.entryID = entryID
        self.record = record
        self.movie = movie
        self.onPick = onPick
        _model = State(initialValue: WebMotionPresetModel(project: project))
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                let request = WebMotionPresetRequest(templateID: entryID, at: max(0, project.clock.time), project: project)
                Task { if await model.add(request) { onPick() } }
            } label: {
                HStack(spacing: 10) {
                    WebMotionMoviePreview(movie: movie, record: record, isPlaying: hovering && !model.isRendering)
                        .frame(width: MotionPresetPreview.size.width, height: MotionPresetPreview.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: record.name).font(.callout.weight(.medium))
                            .lineLimit(2)
                        Text("Starts at the playhead on an upper video track.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.isRendering {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.mini)
                                Text("Rendering motion…").font(.caption2)
                            }
                        } else {
                            Label("Add or drag to the timeline", systemImage: "plus")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? AppThemePalette.current.selectionFill : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(model.isRendering)
            .instantHelp("Add this motion at the playhead, or drag it to an upper video track")
            .onDrag {
                guard !model.isRendering else { return NSItemProvider() }
                return WebMotionPresetDrag.itemProvider(templateID: entryID, record: record, project: project)
            }
            .onHover { hovering = $0 }
            if let error = model.error {
                Text(verbatim: error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
