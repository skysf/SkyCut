import AppKit
import SwiftUI
import SrtFlowCore

// A web-motion clip's editable form. Fields are local drafts; only Re-render commits them, in one undo step.
struct WebMotionInspectorSection: View {
    let project: VideoEditProject
    let clip: EditClip
    @State private var model: WebMotionEditorModel
    @State private var pageError: String?
    @State private var isRevealing = false

    init(project: VideoEditProject, clip: EditClip) {
        self.project = project
        self.clip = clip
        _model = State(initialValue: WebMotionEditorModel(project: project, clip: clip))
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 10) {
            Text("Motion Template").font(.callout.weight(.medium))
            Text(verbatim: model.record.name).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Change the parameters, then re-render to update this clip.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.fields, id: \.key) { field in
                    WebMotionParameterRow(field: field, model: model)
                }
                WebMotionTimingFields(model: model)
            }
            .disabled(model.isRendering)

            ForEach(WebMotionEnvironment.warnings(for: model.record), id: \.self) { warning in
                Text(verbatim: warning).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isStale {
                Text("This motion changed. Reload its parameters before re-rendering.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reload Parameters") { model.reload() }
                    .controlSize(.small)
                    .disabled(model.isRendering)
                    .instantHelp("Discard this draft and load the clip's current parameters")
            }
            VStack(spacing: 6) {
                Button {
                    Task { _ = await model.render() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isRendering { ProgressView().controlSize(.mini) }
                        if model.isRendering { Text("Rendering motion…") } else { Text("Re-render") }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(model.isRendering || model.isStale || isRevealing)
                .instantHelp("Render these parameters and replace this motion in one undo step")
                Button {
                    isRevealing = true
                    pageError = nil
                    Task {
                        defer { isRevealing = false }
                        do { NSWorkspace.shared.activateFileViewerSelecting([try await model.pageURL()]) }
                        catch { pageError = WebMotionUIError.message(error) }
                    }
                } label: {
                    Label("Show Page in Finder", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(model.isRendering || isRevealing || model.isStale)
                .instantHelp("Show this motion's saved page and parameters in Finder")
            }
            .controlSize(.small)

            if let error = model.error ?? pageError {
                Text(verbatim: error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

// Authored parameter labels stay verbatim. Only installed fonts are offered by the shared text font browser.
private struct WebMotionParameterRow: View {
    let field: WebMotionParameterField
    let model: WebMotionEditorModel

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: field.label).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch field.kind {
            case .text:
                TextField("", text: stringBinding)
                    .textFieldStyle(.roundedBorder)
            case .font:
                TextFontPicker(fontName: stringBinding, catalog: TextFontCatalogStore.shared)
            case .color:
                HStack(spacing: 8) {
                    ColorPicker("", selection: colorBinding, supportsOpacity: true)
                        .labelsHidden()
                        .frame(width: 32)
                    TextField("", text: stringBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                }
            case .number:
                TextField("", value: Binding(get: { model.number(for: field.key) }, set: { model.setNumber($0, for: field.key) }),
                          format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
            }
        }
    }

    private var stringBinding: Binding<String> {
        Binding(get: { model.string(for: field.key) }, set: { model.setString($0, for: field.key) })
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { ((try? AIColor.parse(model.string(for: field.key))) ?? .white).swiftUIColor },
                set: { model.setString(AIColor.hex(SubtitleColor($0)), for: field.key) })
    }
}

private struct WebMotionTimingFields: View {
    let model: WebMotionEditorModel

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Render length").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("", value: Binding(get: { model.record.duration }, set: { model.setDuration($0) }),
                              format: .number.precision(.fractionLength(0...3)))
                        .textFieldStyle(.roundedBorder).monospacedDigit()
                    Text("s").font(.caption).foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Hit within motion").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("", value: Binding(get: { model.record.hitTime }, set: { model.setHit($0) }),
                              format: .number.precision(.fractionLength(0...3)))
                        .textFieldStyle(.roundedBorder).monospacedDigit()
                    Text("s").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .instantHelp("Duration and hit are measured within the full motion; the clip's timeline start stays in place")
    }
}
