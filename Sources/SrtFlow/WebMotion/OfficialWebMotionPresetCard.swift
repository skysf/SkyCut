import SwiftUI

// An official page loads its small bundled source off the UI thread, then uses the ordinary web-card add/drag actions.
struct OfficialWebMotionPresetCard: View {
    let project: VideoEditProject
    let template: OfficialWebMotionTemplate
    var onPick: () -> Void = {}
    @State private var record: WebMotionClipRecord?
    @State private var error: String?
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 6) {
            if let record {
                WebMotionPresetCard(project: project, entryID: template.id, record: record,
                                    movie: template.previewURL, blurb: L10n(template.blurbKey), onPick: onPick)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.title2).foregroundStyle(.secondary)
                        .frame(width: MotionPresetPreview.size.width, height: MotionPresetPreview.size.height)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(template.titleKey)).font(.callout.weight(.medium))
                        if let error {
                            Text("This template could not be loaded.").font(.caption).foregroundStyle(.red)
                            Text(verbatim: error).font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
            }
        }
        .task(id: locale.identifier) {
            let template = self.template
            let loaded = await MediaReadQueue.run(on: MediaReadQueue.analysis) { Result { try template.record() } }
            guard !Task.isCancelled else { return }
            do {
                record = try loaded.get()
                error = nil
            } catch { self.error = WebMotionUIError.message(error) }
        }
    }
}
