import AppKit

// MARK: - What SkyCut says when it offers to move itself into Applications
//
// What it does: builds the question (Move to Applications / Not Now, with a line when an app of that name is there and goes
// to the Trash), the small "Moving…" panel the move runs under, and the alerts for a move that stopped. The words go
// through L10n (the in-app language); the app's name is the bundle's own ("SkyCut", "SkyCut Beta"). The off-screen renders
// (scripts/render-move-to-applications.sh) draw these same objects.
// What it doesn't: decide (MoveToApplicationsOffer), move (AppBundleMover), run the flow (MoveToApplicationsLaunch).
// Rules: docs/build/build-and-packaging.md "Installing from the DMG".

@MainActor
enum MoveToApplicationsAlerts {
    /// «Move SkyCut to the Applications folder?» Move is the default button, Not Now the other.
    static func question(appName: String, replacing: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(format: L10n("Move %@ to the Applications folder?"), appName)
        var text = L10n("It's running from the installer disk, but updates and the permissions you give it expect it in the Applications folder.")
        // On a line of its own: sentences in different languages don't join the same way (no space after 。).
        if replacing { text += "\n" + String(format: L10n("The %@ that's there now goes to the Trash."), appName) }
        alert.informativeText = text
        alert.addButton(withTitle: L10n("Move to Applications"))
        alert.addButton(withTitle: L10n("Not Now"))
        return alert
    }

    /// The panel shown while the copy is made and checked, laid out like the alerts: the app's icon, the line, a bar.
    static func progressPanel(appName: String) -> NSPanel {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        let label = NSTextField(wrappingLabelWithString: String(format: L10n("Moving %@ to the Applications folder…"), appName))
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.preferredMaxLayoutWidth = 212
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        for (view, width, height) in [(icon as NSView, 64.0, 64.0), (bar, 212.0, 6.0)] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
            view.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        let stack = NSStackView(views: [icon, label, bar])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        // As wide as the alerts (260 pt), as tall as the line needs.
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 260),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26),
        ])
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: content.fittingSize), styleMask: [.titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.contentView = content
        panel.isReleasedWhenClosed = false
        panel.center()
        return panel
    }

    /// Runs `work` off the main thread and returns its result. The progress panel appears only when it takes longer than
    /// 0.4 s (a warm image copies and checks 65 MB in about 0.1 s on an M1), so a quick move doesn't flash a window.
    static func whileMoving<Result>(appName: String, _ work: @escaping () -> Result) -> Result {
        let finished = DispatchSemaphore(value: 0)
        let box = MoveResultBox<Result>()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = work()
            finished.signal()
            // Runs on the main thread inside the panel's modal loop when there is one: `modal` is set, on the main thread,
            // right before runModal, and the main thread spins no run loop in between.
            DispatchQueue.main.async { if box.modal { NSApp.abortModal() } }
        }
        if finished.wait(timeout: .now() + 0.4) == .success { return box.value! }
        let panel = progressPanel(appName: appName)
        box.modal = true
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return box.value!
    }

    /// An app of that name is open from the Applications folder: never quit, nothing changed.
    static func running(appName: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(format: L10n("%@ is open from the Applications folder"), appName)
        alert.informativeText = L10n("Quit it, then open the copy on the installer disk again to replace it. Nothing was changed.")
        alert.addButton(withTitle: L10n("OK"))
        return alert
    }

    /// This account can't change the Applications folder. Show Applications Folder (default) or Not Now.
    static func notWritable(appName: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(format: L10n("%@ can't be moved to the Applications folder"), appName)
        alert.informativeText = String(
            format: L10n("You don't have permission to change the Applications folder. Drag %@ into it in Finder instead."), appName)
        alert.addButton(withTitle: L10n("Show Applications Folder"))
        alert.addButton(withTitle: L10n("Not Now"))
        return alert
    }

    /// A step of the move failed: which one, the system's reason, and where the app that was there is.
    static func failed(_ step: AppBundleMover.Step, detail: String?, oldAppInTrash: URL?, appName: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L10n("%@ wasn't moved to the Applications folder"), appName)
        var parts = [stepSentence(step, appName: appName)]
        if let detail, !detail.isEmpty { parts.append(detail) }
        parts.append(oldAppInTrash == nil
            ? L10n("Nothing in the Applications folder was changed.")
            : String(format: L10n("The %@ that was there before is in the Trash: put it back from there."), appName))
        alert.informativeText = parts.joined(separator: "\n")
        alert.addButton(withTitle: L10n("OK"))
        return alert
    }

    /// The copy is in place but macOS didn't open it. Show in Finder (default) or OK.
    static func openFailed(appName: String, detail: String?) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L10n("%@ was moved but didn't open"), appName)
        alert.informativeText = [L10n("It's in the Applications folder now: open it from there."), detail ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        alert.addButton(withTitle: L10n("Show in Finder"))
        alert.addButton(withTitle: L10n("OK"))
        return alert
    }

    private static func stepSentence(_ step: AppBundleMover.Step, appName: String) -> String {
        switch step {
        case .copy: return L10n("It couldn't be copied there.")
        case .quarantine: return L10n("The copy couldn't be cleared of the download quarantine.")
        case .signature: return L10n("The copy didn't pass the code signature check.")
        case .trash: return String(format: L10n("The %@ already there couldn't be moved to the Trash."), appName)
        case .install: return L10n("The copy couldn't be put in place.")
        }
    }
}

/// The move's result, handed from the background thread to the main thread (whileMoving).
private final class MoveResultBox<Value>: @unchecked Sendable {
    var value: Value?
    var modal = false
}
