# 2026-11-27 The update feed writer never parsed: an apostrophe in a `${…:?…}` message opened a quote

## Symptom

Ops, preparing release 0.18.70 (task REL70), found that `scripts/write-update-feed.sh` on main can't run. It writes the
release's update feed (`skycut.json`, [App updates](../architecture/app-updates.md) "The feed"), and the build doc
「公开下载发布」 says the release's feed comes from this script, so the release waited for it. Neither shell gets past
parsing, so not one line runs:

```console
$ /bin/bash -n scripts/write-update-feed.sh                  # 3.2.57, CI's shell
scripts/write-update-feed.sh: line 74: syntax error: unexpected end of file
$ /opt/homebrew/bin/bash -n scripts/write-update-feed.sh     # 5.3.20
scripts/write-update-feed.sh: line 74: syntax error: unexpected end of file from `if' command on line 15
```

The script came in with the updater (#565, its only commit `f903c9e1`) and has never parsed.

## Root cause

1. **Bash reads an apostrophe in the word of `${name:?word}` as the start of a single-quoted string, even inside double
   quotes.** Elsewhere inside double quotes an apostrophe is a plain character (`"it's"`); in the word of
   `${…:-…}`, `${…:=…}`, `${…:?…}` and `${…:+…}` (with or without the colon) it opens a quote. Bash 3.2 and 5.3 agree.
   The two usage messages had one each:

   ```bash
   16  TEST_FEED="${2:?--test-feed needs the test feed's own URL}"
   20  URL="${2:?the DMG's immutable URL on downloads.skylu.ai}"
   ```

2. **It failed only by luck.** The quote opened on line 16 closed at line 20's apostrophe, so lines 17–19 (`shift 2`,
   `fi`, the `DMG=` line) became part of one string inside line 16's expansion. The `if` on line 15 lost its `fi` and the
   parser reached the end of the file inside it. With no `fi` between the two apostrophes the script would have parsed
   and silently done something else. A probe with two such messages on adjacent lines parses under both shells, and run
   with both arguments it stops on `URL: unbound variable`: the second assignment never ran.
3. **No check runs the script, so nothing parsed it before the release.** It needs a signed, notarized release DMG.
   `scripts/check-app-update.sh` compiles `scripts/update-feed/FeedWriter.swift` and runs it on fixture values but never
   the shell wrapper, and no guard parses shell scripts that no check runs (release tools, smokes, pipelines). Ops'
   `/bin/bash -n` scan of every `scripts/*.sh`, `scripts/*/*.sh` and `checks/*.sh` found no other file failing.

## Fix

- `scripts/write-update-feed.sh`: the two messages reworded without apostrophes ("needs the URL of the test feed itself",
  "the immutable URL of the DMG on downloads.skylu.ai").
- New scan guard `checks/shell-syntax.sh` (in `scripts/check-all.sh`, next to the other shell guards):
  1. The files come from `git ls-files` (tracked, plus new files not yet added, minus ignored ones): every `.sh` file and
     every file whose first line is a bash or sh shebang. No fixed list, so a new script is covered on the day it is
     added.
  2. Each one must parse under `/bin/bash -n`, the shell `check-all.sh` and CI run scripts with.
  3. No line may hold a lone apostrophe in the word of `${name:-…}`, `${name:=…}`, `${name:?…}` or `${name:+…}`. Rule 2
     only catches an odd number of such apostrophes; with an even number the script parses and is wrong (root cause 2).
     An apostrophe inside a nested `"…"`, escaped (`\'`) or paired (`'…'`) within the same expansion is fine and not
     flagged.
- The rule went into [coding standards](../architecture/coding-standards.md) section 6, and the trap into
  [build version and shell traps](2026-08-06-build-version-and-shell-traps.md) as trap 8.

## Verification

- `/bin/bash -n` and bash 5.3's `-n` both accept the fixed script. Missing arguments now stop with their messages
  (`line 16: 2: --test-feed needs the URL of the test feed itself`, `line 20: 2: the immutable URL of the DMG on
  downloads.skylu.ai`), and a missing DMG with `✗ write-update-feed: no DMG at …`.
- The real build, read-only: `scripts/write-update-feed.sh --test-feed http://127.0.0.1:8123/skycut.json
  <main checkout>/dist/SkyCut-0.18.70-arm64.dmg http://127.0.0.1:8123/SkyCut-0.18.70-arm64.dmg
  <main checkout>/impl-briefs/REL70-notes.json <scratch>/skycut.json` exits 0 in about 5 s:
  `feed: SkyCut 0.18.70 (build 1, macOS 15.0+), 42684517 bytes, b4ec4c2b8828…, notes in zh-Hans / en / es`. The feed is
  byte-identical to the one ops wrote for REL70 (SHA-256 `5ce41c95…0912` for both), and a second run writes the same
  bytes. `hdiutil info` lists no image before or after either run, the script's work folder is gone, and the DMG's
  SHA-256, size and modification time are unchanged.
- The guard on the fixed tree: green, 212 scripts (211 tracked and the guard itself, not yet added), under a second.
  Reversed:
  - one apostrophe put back on line 16: red on both rules (the parse error, then line 16 named);
  - main's original script: red on both rules, lines 16 and 20 named;
  - a probe with two such messages on adjacent lines, which `bash -n` accepts: red on rule 3 alone, both lines named;
  - a file without `.sh` whose shebang is `#!/usr/bin/env bash`, with an unclosed `if`: red on rule 2. A
    `#!/usr/bin/env python3` file next to it is not handed to bash;
  - a probe with legitimate forms (`"${A:-"it's"}"`, `"${A:-'quoted'}"`, `${1:-'a b'}`, `${IFS_UNSET:-$' \t\n'}`,
    `"${A:-it\'s}"`, an apostrophe in a comment line): green, and it runs.
- `scripts/check-local.sh app-update shell-syntax`: all 62 scan guards and `scripts/check-mcp.sh --scans-only` green,
  `scripts/check-app-update.sh` 411 checks with 0 failed, the new guard green.

## Lessons

1. **A script no check runs gets parsed by no one.** Release tools, smokes and asset pipelines run by hand only, on the
   day they are needed. `checks/shell-syntax.sh` now parses every shell script that `git ls-files` lists.
2. **Never put an apostrophe in the word of `${…:-…}`, `${…:=…}`, `${…:?…}` or `${…:+…}`**, even inside double quotes:
   reword the message ("the URL of the test feed", not "the test feed's URL"). The rule:
   [coding standards](../architecture/coding-standards.md) section 6.
3. **`bash -n` passing proves little**: with two such apostrophes the script parses and is wrong. Run each branch once
   with `/bin/bash` (lesson 4 of the shell traps case); the guard's rule 3 looks for the apostrophe itself.

## Follow-up (same PR): the cleanup missed its mount, and relative arguments resolved against the repository

Both were found while fixing the parse error and folded into the same PR before review.

**Symptom.**
1. A run that failed after the mount left the DMG attached (hidden), and `rm -rf` ran over the mounted read-only
   volume. Failures that get there: Gatekeeper refusing the app, a wrong bundle id, a volume still busy at the final
   detach. Reproduced with the previous version and a scratch copy of the 0.18.70 DMG: a probe held the volume busy so
   the script's own unforced detach failed. The run printed `rm: …/mount/…: Read-only file system`, the image stayed
   attached (`/dev/disk4`) and the work folder stayed.
2. Relative arguments meant the repository, not the caller's folder. Run from another folder, `../fixture.dmg` gave
   «no DMG at ../fixture.dmg»; a relative output path would have written the feed into the repository.

**Root cause.**
1. The EXIT trap looked for its mount with `mount | grep -F " on ${MOUNT} "`. The mount point is under `${TMPDIR}`
   (`/var/folders/…`), `/var` is a link to `/private/var`, and `mount` prints the resolved path, so the test never
   matched, on any Mac. `scripts/check-app-update.sh` had met this in its own cleanup and resolves its folder with
   `pwd -P`; the release script didn't.
2. The script `cd`s to the repository before it reads the files it was given.

**Fix.** The mount and its cleanup moved into `scripts/update-feed/mount.sh`, which both the script and the check source:
- `feed_mounted` compares the device of the mount point with its parent's (`stat -f %d`), not paths;
- `feed_cleanup` forces off whatever is still mounted, and removes the work folder only when nothing is mounted inside;
- `feed_detach` says when the volume didn't detach.

The script makes `DMG`, `NOTES` and `OUT` absolute (from `$PWD`) before its `cd`.

**Verification.**
- The real DMG again: exit 0, byte-identical to ops' feed, 0 images attached before and after, the DMG unchanged.
- A forced failure after the mount, with the real script and a scratch copy of the DMG: the probe holds the volume busy,
  the unforced detach fails («the DMG did not detach (busy?)»), exit 1. Afterwards 0 images are attached, there is no
  work folder and no feed. The same run with the previous version left the image attached (above).
- A late failure, an unwritable output folder: «could not write …», exit 1, nothing attached, no work folder, nothing
  written.
- New cases in `scripts/check-app-update.sh`, on a scratch image:
  - relative arguments from another folder reach Gatekeeper and name the caller's path;
  - the mount fails right after the attach, in a folder reached through a link: `feed_mounted` sees it, nothing stays
    attached, no work folder stays.

  Reversed: without the absolute paths the first case is red («no DMG at ../fixture.dmg»). With the old path match all
  three mount assertions are red, and the check's own cleanup still detached the image.

**Lessons.**
4. Ask whether a volume is mounted by device, not by path: TMPDIR is under `/var`, and `mount` prints resolved paths.
   The rule: [coding standards](../architecture/coding-standards.md) section 6; trap 9 of the
   [shell traps](2026-08-06-build-version-and-shell-traps.md).
5. A script that `cd`s before it uses its arguments makes them absolute first.
