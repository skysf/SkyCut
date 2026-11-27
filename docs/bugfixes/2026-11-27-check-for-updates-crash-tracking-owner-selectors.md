# 2026-11-27 Check for Updates… crashed SkyCut: a tracking area's owner without AppKit's selectors

## Symptom

On 2026-11-27, with 0.18.71 on offer, the developer's SkyCut 0.18.70 crashed twice, each time right after SkyCut ›
检查更新… (Check for Updates…):
- once after 9.5 hours of running;
- again 11 s after the relaunch, when the menu item was chosen a second time.

The answer window came up, the pointer moved, and SkyCut was gone. Both crash reports show the same main-thread stack:
`_NSSendEventToObservers` (an event monitor) → SkyCut's closure → `swift_task_isCurrentExecutorWithFlagsImpl` →
`SerialExecutorRef::isMainExecutor` → `swift_getObjectType` on a bad pointer. The first was EXC_BREAKPOINT
("pointer authentication trap"), the second EXC_BAD_ACCESS at 0x20.

Scope:
- Every build with the updater's menu item crashes this way on the menu check: 0.18.70, 0.18.71, and 0.18.69 (the
  two-build test's first build). The answer window shows for "up to date" too, so no newer version is needed.
- The automatic path doesn't crash: the check about a minute after launch, the download, the Update pill and the install
  at quit. That path ran on the same Mac with the same code in the 0.18.69 → 0.18.70 two-build test, the same morning.
- The same exposure exists, without the updater, wherever another alert runs inside a Swift task (see Fix).

## Root cause

Three things had to come together.

1. **An exception on every pointer crossing.** `AppUserPresence` (since 2026-11-11) puts a tracking area on every window
   that can become main. Its owner, `PointerWatcher`, is a plain `NSObject`, not an `NSResponder`. Swift exported its
   `@objc func mouseEntered(with:)` / `mouseExited(with:)` as `mouseEnteredWith:` / `mouseExitedWith:`, which is Swift's
   name for a method that overrides nothing. AppKit sends a tracking area's owner `mouseEntered:` / `mouseExited:`, so
   every time the pointer entered or left such a window, `doesNotRecognizeSelector:` raised NSInvalidArgumentException.
   AppKit's top-level handler logged and swallowed it: 129 times that day on the developer's Mac. At the top level that
   is harmless, but it also meant the watcher never did its job (noticing a pointer that enters while SkyCut is in the
   background).
2. **A modal loop inside a Swift task.** The menu check's answer was shown by
   `Task { @MainActor in AppUpdateAlerts.show(answer) }`, i.e. `NSAlert.runModal()` running inside a Swift concurrency
   job. When the pointer crossed a watched window during the alert, the exception was raised inside the modal loop. It
   unwound out of `runModal`, out of the task, and out of the runtime's `swift_job_run`. That function points the
   thread's executor-tracking slot (TSD slot 0x340 in macOS 26.5's `libswift_Concurrency`) at a record on its own stack
   and puts the old value back only on its normal return path. `-[NSApplication run]` caught and logged the exception
   and carried on, with the slot still pointing into a popped frame.
3. **The next isolation check.** The next mouse move ran AppUserPresence's local monitor, whose
   `MainActor.assumeIsolated` asks `swift_task_isCurrentExecutor`. Finding a tracking record, the runtime read stack
   garbage as the current executor and called `swift_getObjectType` on it. Any isolation check outside a task would
   have crashed the same way; the monitor was first because it runs on every mouse move.

The evidence:
- **Logs.** Of the 129 exceptions, 127 came from the top-level event loop, and SkyCut survived each. The only 2 raised
  inside `runModal` with a Swift task underneath each came right before a crash: 19:32:18.158 before the 19:32:19.36
  crash, and 19:33:42.75 within 0.1 s of the second. The crash reports' `HIE … SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`
  thread was created 2 ms after the first swallowed exception of that run.
- **The binary.** Disassembling 0.18.70 identified the crashing frames: AppUserPresence's monitor (it passes
  `#fileID` "SrtFlow/AppUserPresence.swift" and line 63 to `assumeIsolated`), and the runtime's check at
  `swift_task_isCurrentExecutorWithFlagsImpl+72` reading the tracking slot.
- **An isolated repro.** A command-line program, with no app bundle and no windows, raised an exception in a main-actor
  `Task` and caught it outside the run loop. Afterwards the tracking slot was still set although the job was gone; once
  that stack was reused, `MainActor.assumeIsolated` faulted with the second crash's stack, frame for frame. The same
  exception raised outside a task left the slot empty.

Why nothing caught it before release:
- The release test's step for the menu check (app-updates.md §10, step 14) "needs a person" and was never clicked.
- The render script draws the alerts off-screen, without `runModal`.
- No check presents the answer.

## Fix

- **`PointerWatcher`** (`Sources/SrtFlow/AppUserPresence.swift`): `@objc(mouseEntered:)` / `@objc(mouseExited:)`. AppKit's
  messages resolve and nothing raises. Behaviour change: a pointer entering a SkyCut window while SkyCut is in the
  background now notes the user, which is what the watcher was written for.
- **The answer window** (`AppUpdater.run(.answer)`): shown from the run loop with
  `RunLoop.main.perform { MainActor.assumeIsolated { AppUpdateAlerts.show(answer) } }`, outside any Swift task.
  - An exception raised by any other event during its modal loop now reaches AppKit's handler with no task to unwind.
  - Not `DispatchQueue.main.async`: an exception escaping a dispatch block terminates the app (shown with the repro).
  - Scheduled from a main-actor job, the block runs about 0.3 ms later.
- **Not changed.** These still run `runModal()` inside a task, but no longer get this exception. They await the answer,
  so moving them out of the task is a larger change. The rule for new alerts is
  [system file windows](../architecture/system-file-windows.md) rule 10.
  - the untitled-project save question: `ProjectClosing.swift:49`, from `async prepareToClose` (Quit, Restart and Update,
    New / Open, closing a window). A crash there would have lost that project's edits;
  - the stalled-drive question at quit: `ProjectQuit.swift:155`;
  - `FileReplaceQuestion`: `SaveLocation.swift:50`, from `saveAs(chosen:)` and the subtitle editor's Export As.

## Verification

Each guard was reverse-verified: red with its part of the fix undone, green with it.

- **`checks/AudioEngine/Presence.swift`** (group 15 of `scripts/check-audio-engine.sh`). The tracking areas' owner
  responds to `#selector(NSResponder.mouseEntered(with:))` and `mouseExited(with:)`. Told `mouseEntered:` with an enter
  event, it notes the user and counts a return; `mouseExited:` changes nothing. With Swift's own names back: 1 failure
  in 332 checks.
- **`checks/audio-engine-idle-wiring.sh` section 11** (every Swift file under `Sources`). A non-`override`
  `func mouseEntered` / `mouseExited` / `mouseMoved` / `cursorUpdate` `(with` without `@objc(<name>:)`, on its line or
  the line above, is red.
  - Selectors undone: red, both lines named.
  - A throwaway `NSObject` subclass in another file: red.
  - The name on the line above, or an `override` in an `NSView`: green.
- **`checks/app-update-wiring.sh` section 10.** The answer is shown by exactly the run-loop line, and nowhere else. Back to
  the `Task`: red. As `DispatchQueue.main.async`: red.
- **Local checks:** `scripts/check-local.sh audio-engine app-update app-update-wiring` green.
- **Manual, before the next release:** a real modal window crossed by a real pointer can't be driven from a check.
  [App updates](../architecture/app-updates.md) §10 step 19 clicks the menu's Check for Updates… with a newer version
  offered.
- **The repro stays out of the checks.** It tests Apple's runtime, not SkyCut's code: it would be red or green regardless
  of this fix. It also reads a private runtime slot whose place can change with the OS, and it needs an Objective-C shim
  no check builds.

## Lessons

1. **An exception AppKit swallows is not harmless.** Raised while a Swift task is on the main thread's stack, it unwinds
   the task and the runtime's `swift_job_run`, leaving the executor tracking dangling. SkyCut then crashes later,
   somewhere unrelated, at the next isolation check. A swallowed exception shows in Console
   (`log show --predicate 'process == "SkyCut" AND eventMessage CONTAINS "unrecognized selector"'`) long before it
   crashes anything: here, for two weeks.
2. **Write out the selector for an object AppKit messages by name that isn't an `NSResponder`** (a tracking area's owner):
   Swift's own name for `mouseEntered(with:)` is `mouseEnteredWith:`. Rule: [audio engine](../architecture/audio-engine.md)
   §2 item 11, held for every such owner by `checks/audio-engine-idle-wiring.sh`.
3. **A modal loop runs from the run loop, never inside a Swift task:**
   [system file windows](../architecture/system-file-windows.md) rule 10.
4. **A release test that skips a menu path ships it untested.** The menu's Check for Updates… was "needs a person" in the
   two-build test, and nobody clicked it. Its answer windows are now a step of their own (app-updates.md §10 step 19).
