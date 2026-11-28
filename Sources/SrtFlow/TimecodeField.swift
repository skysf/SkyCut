import SwiftUI
import SrtFlowCore

// MARK: - An editable timecode cell, and the time still being typed in it
//
// What it does: the subtitle tables' start / end cells (the Burn In panel, the edit page's subtitle rows): the time is written
// to the subtitle on Return or when the cell loses focus; text that is not a time puts the value back. While a time is typed
// and not entered yet, it is a draft the subtitle does not have: `PendingTimecode` holds the one cell being edited, and
// anything that asks before unsaved subtitle edits go away (BurnInSubtitleEdits, ProjectQuit) writes it first, so a time
// still being typed counts as an edit — the Burn In page's counterpart of the edit page's `endPendingTextEditing`.
// What it doesn't: what a subtitle's time may be (the bindings it is given); asking about unsaved edits (BurnInSubtitleEdits).
//
// Why (2026-11-28, review CXM1 of docs/bugfixes/2026-11-28-burn-in-subtitle-edits-dropped-unasked.md): a time typed and not
// entered, the only edit, was not asked about at ⌘Q: the cell writes it only on Return or focus loss, after SwiftUI's next
// update, and Quit had already let SkyCut go. Moved out of SubtitleEditPanel.swift with that change.

/// The time a cell is being typed into, before Return or leaving the cell writes it (TimecodeField). One cell is edited at a
/// time.
@MainActor
enum PendingTimecode {
    private static var cell: UUID?
    private static var write: (() -> Void)?

    /// `cell` holds a typed time its subtitle does not have yet; `write` writes it (or puts the value back).
    static func began(_ cell: UUID, write: @escaping () -> Void) {
        self.cell = cell
        self.write = write
    }

    /// `cell` wrote its time, put its value back, or went away.
    static func ended(_ cell: UUID) {
        guard self.cell == cell else { return }
        self.cell = nil
        write = nil
    }

    /// Writes the time still being typed, if there is one: before anything asks about unsaved subtitle edits.
    static func commit() {
        let pending = write
        cell = nil
        write = nil
        pending?()
    }
}

/// 可编辑的时间码格子：回车或失焦时提交，输入不合法就回退。
struct TimecodeField: View {
    @Binding var value: TimeInterval
    @State private var text: String
    /// This cell, for PendingTimecode.
    @State private var cell = UUID()
    @FocusState private var focused: Bool

    init(value: Binding<TimeInterval>) {
        _value = value
        _text = State(initialValue: Timecode.formatMillis(value.wrappedValue, separator: ","))
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        TextField("", text: $text)
            .focused($focused)
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onChange(of: text) { _, typed in
                // Typed and not entered yet: a draft the subtitle does not have (PendingTimecode).
                if focused, typed != Timecode.formatMillis(value, separator: ",") {
                    PendingTimecode.began(cell) { commit() }
                } else {
                    PendingTimecode.ended(cell)
                }
            }
            .onChange(of: value) { _, newValue in
                guard !focused else { return }
                text = Timecode.formatMillis(newValue, separator: ",")
            }
            .onDisappear { PendingTimecode.ended(cell) }
            .monospacedDigit()
    }

    private func commit() {
        PendingTimecode.ended(cell)
        guard let parsed = Timecode.parse(text) else {
            text = Timecode.formatMillis(value, separator: ",")
            return
        }
        if parsed != value { value = parsed }
        // **回读，别显示 parsed。** 绑定有权拒绝（字幕表那边就拒绝 start >= end），
        // 显示 parsed 会让格子里挂着一个根本没生效的时间：界面说 4 秒、
        // 存盘和导出还是 1 秒，用户毫不知情（2026-08-12 复审 P2）。
        text = Timecode.formatMillis(value, separator: ",")
    }
}
