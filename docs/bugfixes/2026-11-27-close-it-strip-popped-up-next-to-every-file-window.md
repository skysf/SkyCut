# 2026-11-27 A Close It strip popped up next to every macOS file window after 5 s

## Symptom

The user, 2026-11-27: 「…只要是在skycut里面打开了finder的功能，就会出现这个窗口，这个窗口也不知道什么意思，很奇怪」. Opening a project,
choosing where a screen recording is saved — any macOS open / save window SkyCut opened — and after 5 s a small panel titled
"SkyCut" stood next to it: 「如果 macOS 的窗口没有反应了，在这里关掉它。」 with 「关掉它」 ("If the macOS window stops responding, close
it here." / "Close It").
- A person choosing a file usually takes longer than 5 s, so it came up in normal use, next to nearly every window.
- The user couldn't tell what it meant.
- It broke the quiet rule: nothing pops up by itself (user, 2026-11-27).

## Root cause

- **The way out of a stuck window was a timer.** The 2026-11-19 fix ([case](2026-11-19-modal-file-windows-can-wedge-app.md))
  needed a way out of a system window whose panel service hangs: its buttons are dead and macOS says nothing. It chose a
  timer: `SystemFileWindows` showed `FileWindowHelper`'s strip once the window had been on screen 5 s without an answer,
  on the assumption that most picks take less. Browsing folders takes longer, so the strip came up in normal use.
- **macOS gives SkyCut no signal of a hung panel service**, so a timer can't tell a stuck window from a person thinking.
  - ViewBridge, the remote-view machinery the panel runs on, checks the service's responsiveness internally
    (`-[NSRemoteView _ensureViewServiceIsResponsive]`, `-[NSViewServiceMarshal checkResponsiveness:reply:]`), but exports
    no notification or API for it.
  - The [2026-11-18 measurement](2026-11-18-export-folder-chooser-freezes-app.md): a stopped service left the panel dead
    for 45 s with no callback, alert or timeout.
- **The one thing a stuck window's person does was ignored.** While a window was up, a second request for a file window
  was dropped silently ("one window at a time"). A person asking again for a window that was stuck, or hidden behind
  SkyCut's own window, got nothing at all.

## Fix

- **No timer.** Nothing appears next to the system window while the person chooses, however long they take:
  `SystemFileWindows.phaseChanged(.choosing)` does nothing, and `stripDelay` is gone.
- **The strip comes only when the person asks for another file window while one is up** (`offerToCloseOpenWindow`, from
  `start`), and only while that window is on screen. Asking again is the sign a stuck window gives; it used to be a silent
  no-op. Its button cancels the window, which works even when the service hangs (0.09 s measured on 2026-11-18), and
  offers the fallback for the first request: type a path, drag from Finder, or Try Again.
- **The strip names the file window and says its button closes it** (never SkyCut). The wording was approved by the user
  on 2026-11-27 (「可以」):
  - zh-Hans: 「选文件的窗口卡住或没反应，点这里关闭。」, with the button 「关闭」;
  - en: "If the window for choosing a file is stuck or not responding, click here to close it.", with "Close";
  - es: "Si la ventana para elegir un archivo se ha quedado colgada o no responde, haz clic aquí para cerrarla.", with
    "Cerrar".

  The text replaces "If the macOS window stops responding, close it here." in all three string tables. The button reuses
  the existing "Close" key instead of "Close It" (关掉它), which the export panel's row keeps.
- **Considered and not chosen:**
  - the strip when the person clicks back into a SkyCut window while the system window is open: the windows are
    non-modal since 2026-11-19, so clicking the timeline meanwhile is normal use and would pop it up;
  - a menu item: permanent UI for a rare failure, and a stuck person rarely looks through menus;
  - a much later timer: it still pops up by itself for someone who leaves the window open.
- **Unchanged:**
  - A window that never appears, vanishes, or comes back empty at once still gets the fallback within about 3 s. That
    fallback is the answer to the person's own request.
  - The export panel's folder row keeps its inline line "Choose a folder in the macOS window. If that window stops
    responding, close it here." with Close It. It is a line inside the export panel, not a window of its own.

What the person sees now:
- **Normal:** the macOS window, and nothing else, however long they take. If they ask for another file window while it is
  open, the strip stands next to it, and Close (关闭) closes that window; SkyCut stays open.
- **Stuck:** the macOS window's buttons do nothing. Asking for the window again (the same menu item or button) brings the
  strip next to it; Close closes the stuck window at once and offers the typed path, a drop from Finder, or Try Again.
  ⌘Q quits, as before.

Rule: [system file windows](../architecture/system-file-windows.md) rule 5.

## Verification

Each guard was reverse-verified: red with its part of the fix undone, green with it.

- **`scripts/check-export-profile.sh`** (`FileWindowsChecks`), 203 assertions green:
  - a pick the person cancels after 1.2 s shows nothing;
  - a window up 1.5 s without an answer shows nothing;
  - asking for another window while one is up opens nothing, answers nothing, and puts the strip next to the open window
    (at its frame);
  - the strip's button cancels it and offers the fallback for the first request, and Try Again's answer reaches the first
    caller;
  - a second request while the window isn't on screen yet shows nothing.
- **`checks/file-io-off-main-wiring.sh`:** `.showStrip(` appears once, inside `offerToCloseOpenWindow`, which is called only
  from `start`; no sleep or timer in `SystemFileWindows.swift`.
- **Reversals:**
  - the timer back (0.4 s, the delay the check used to pass): the guard (two lines) and 3 assertions red;
  - no strip on a second request: the guard and 3 assertions red;
  - a strip even when the window isn't on screen: 1 assertion red.
- **Localization coverage** green: the new text is in all three tables, and the button reuses "Close".
- **Pictures:** the strip rendered off-screen in en / zh-Hans / es with the approved wording, to settle with the user before
  the push (not in the repository).
- **Not verified:** a real panel service frozen under SkyCut. That stays manual:
  [system file windows](../architecture/system-file-windows.md), manual regression items 2 and 3.

## Lessons

1. **A timer can't tell a stuck window from a person thinking.** When macOS gives no signal, wait for the person's own sign
   (here, asking again), and say plainly what the helper is about.
2. **"Most take less than N seconds" makes the popup routine for everyone else.** Anything shown on a timer pops up by
   itself, which the quiet rule forbids.
3. **An action of the person's that SkyCut drops silently is a signal going to waste.** Here it was a second request while
   a window was up.
