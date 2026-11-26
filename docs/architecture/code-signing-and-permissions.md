# Code signing and system permissions: the Developer ID, hardened runtime and notarization

> Since 2026-11-26 the Developer ID of team 26TVX3S9FR signs user and release builds, with the hardened runtime, and
> Apple notarizes them (from 2026-10-03 a self-signed certificate did, ad-hoc before that: history at the end). Read this
> before changing packaging or signing (`scripts/build-app.sh`, `scripts/build-beta-app.sh`, `scripts/signing/`,
> `packaging/SkyCut.entitlements`, `packaging/signing-identity.sha1`), anything that needs a system permission (screen
> recording, microphone, the Downloads folder, Automation, the keychain), or code added to the app bundle.
> Cases: [录屏开关开着、自定义区域还是说没权限](../bugfixes/2026-10-03-screen-recording-permission-stale-after-update.md),
> [钥匙串密码框堵住 AI 调用](../bugfixes/2026-11-07-keychain-prompt-blocks-ai-calls.md).
> Evidence for this setup: [the Developer ID report](../reports/2026-11-26-developer-id-signing.md).

## 一、为什么：系统权限按签名记账

macOS 的隐私授权（TCC：录屏、麦克风、下载 / 桌面 / 文稿文件夹……）每条记录按 bundle id 找，但**按签名认**：
记录里存着授权那一刻那个 App 的 designated requirement（TCC.db 的 `csreq` 列），之后每次都拿正在跑的 App
去比，对不上就当没授权。钥匙串项的访问控制同理。

ad-hoc 签名（`codesign --sign -`）的 designated requirement 就是 `cdhash H"…"`：二进制、Info.plist 任何一处
变了 cdhash 就变（内容一样重签，cdhash 不变）。所以 ad-hoc 签的每个新版本，在系统眼里都是「另一个 App」。
2026-10-03 在 macOS 26.5 上量到的各种权限对不上之后的表现：

| 权限 | 用户怎么给 | 换了签名之后 |
| --- | --- | --- |
| 录屏（ScreenCapture，系统的 TCC.db） | 系统设置里拨开关 | 开关照样显示开着，App 照样被拒。**关掉再打开只改开关、不换钉着的签名**（用户刚拨过的记录 `last_modified` 是新的，`csreq` 还是老构建的 cdhash），怎么拨都没用。只有删掉这条记录（`tccutil reset`，或在列表里选中按「−」）让系统重新问 |
| 下载文件夹（用户的 TCC.db） | 系统弹框点「允许」 | 下一次访问重新弹框；点了允许，`csreq` 换成新构建的 |
| 钥匙串（Sky Studio 的 Key，原 fal 的 Key，[fal.ai 生成](fal-generation.md) 第六节） | 弹框输登录密码、点「始终允许」 | 每个新构建第一次读弹一次。**换成固定证书之后也照样弹**，见历史一节的 2026-11-07 更正 (that was the self-signed certificate; with the Developer ID, expected to ask once more and then no more: section 2) |

## 2. The Developer ID (since 2026-11-26)

The user, 2026-11-25, after renewing the Apple Developer Program (an individual account): 「以后打包 dmg就用这个签名，这样就可以
直接打开了。」

- **Identity**: `Developer ID Application: TIANYU LU (26TVX3S9FR)`, valid until 2027-12-25, its private key in the login
  keychain. The Command Line Tools sign and notarize; Xcode is not needed. `packaging/signing-identity.sha1` pins the
  certificate's SHA-1 and `scripts/signing/common.sh` the team. codesign's first use of the key asks for the login
  password once; the user chose Always Allow on 2026-11-26, after which signing asks nothing.
- **Designated requirement**: `identifier "<bundle id>" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6]
  /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "26TVX3S9FR"`.
  It names the team, not the certificate. Every new build satisfies it, and so does a renewed certificate of the same
  team, so the grants in section 一 carry over both. Renew before 2027-12-25 and put the new SHA-1 in the pin file; a
  certificate of another team would be another app to macOS.
- **Keychain**: for an app with a Team ID, a keychain item's partition list records `teamid:26TVX3S9FR` once the user
  chooses Always Allow, so a later build of the team should read the Sky Studio Key without asking. The per-build
  question of the 2026-11-07 correction (history below) came from the missing Team ID. Expected, not yet seen: manual
  regression item 5 below.
- **Hardened runtime** on every piece (`--options runtime`; notarization requires it), with a secure timestamp. The runtime
  denies some resources without even asking the user unless the code has their entitlement. Only the app has
  entitlements (`packaging/SkyCut.entitlements`); the helpers have none:

| Entitlement | For | Proof (2026-11-26, the report) |
| --- | --- | --- |
| `com.apple.security.device.audio-input` | the microphone: narration while recording the screen, a voice sample for a new voice ([声音库](voice-library.md)第九节) | a probe app signed without it made tccd log «Prompting policy for hardened runtime; service: kTCCServiceMicrophone requires entitlement com.apple.security.device.audio-input but it is missing»; with it, nothing |
| `com.apple.security.automation.apple-events` | `AIFinderSelection`: `osascript` asks Finder for its selection (`open_folder` with `from_finder`) | the same probe: the same line for kTCCServiceAppleEvents; with it, nothing |
| none | the audio engine, ffmpeg, `skycut-mcp`, `skycut-web-motion` (WebKit runs the pages in its own processes), Kokoro (Core ML) | the E2E MCP suite and a Kokoro line on a Developer-ID, hardened copy of the release build gave the same results as an ad-hoc control |
| none | screen recording and the Mac's sound (ScreenCaptureKit): the runtime has no gate for them, only the user's grant | with the user's grant on a hardened test build: the report, section 5 |
| none | the main-thread stack capture: it suspends and reads only its own process's threads, which the runtime allows | not exercised (no stall during the runs) |

  No runtime exception (`com.apple.security.cs.*`: JIT, unsigned executable memory, library validation, DYLD variables;
  `get-task-allow`): nothing needs one. `checks/release-signing.sh` refuses them, and wants an entitlement for every usage
  description of a protected resource in `packaging/Info.plist`, and the other way round. Screen recording has no
  entitlement: only the user's grant, as before.
- **Notarization** (`scripts/signing/notarize.sh`): the app is zipped with ditto and submitted (`xcrun notarytool submit
  --keychain-profile notary-26TVX3S9FR --wait`), and its ticket stapled to the app; the DMG is then built from the
  stapled app, signed (`sign-dmg.sh`), submitted and stapled. `stapler validate` and Gatekeeper's own assessment (`spctl
  --assess`: «source=Notarized Developer ID») must pass, or the build stops. The Beta is notarized the same way.
  - The profile: one for all of the user's apps (user, 2026-11-26: 「因为我电脑上有不同的 app，都需要用，我可以做成一个通用的
    password吗？还是一个app一个？」, answered with one app-specific password and one profile named by the team). The user
    creates it once: `xcrun notarytool store-credentials notary-26TVX3S9FR --apple-id <Apple ID> --team-id 26TVX3S9FR`.
    Scripts only name it (`SKYCUT_NOTARY_PROFILE` overrides the name); they never ask for, read or print the password.
  - `build-app.sh` and `build-beta-app.sh` start with `notarize.sh --check`: a profile notarytool cannot use stops the
    build before the compile and says how to create it.
  - How long it takes, measured: [the report](../reports/2026-11-26-developer-id-signing.md).
- **A Mac without a Developer ID of the team, or a `security` that cannot list identities**: the build stops (since the
  FBS1 review, 2026-11-26; before that it signed ad-hoc and exited 0 with only a warning). Someone building SkyCut for
  themselves sets `SKYCUT_ALLOW_ADHOC=1`: ad-hoc, with the same runtime and entitlements, not notarized, with a ⚠️
  warning. Nothing in `scripts/` sets it, and such a build never goes to anyone. CI runs none of the build scripts.
- **A failed build** deletes the app and DMG it had begun writing in `dist/` (the Beta likewise), so nothing unsigned or
  un-notarized stays there under a release's name. `notarize.sh` tries the staple three times, 20 s apart, because a
  ticket can take a moment to become downloadable after «Accepted».
- **The self-signed identity** of 2026-10-03 («SrtFlow Signing» in `~/.config/srtflow/signing/`) stays untouched as a
  backup; no script uses it. `create-identity.sh`, which made it, was removed (git history has it).

## 三、规矩

1. **Sign and notarize only through `scripts/signing/`**: `sign-app.sh` signs the app and the Beta, `sign-dmg.sh` the DMG,
   `notarize.sh` notarizes both. Packaging scripts never call `codesign`, `notarytool`, `stapler` or `spctl` themselves.
2. **Only the pinned Developer ID signs user and release builds.** `sign-app.sh` refuses a pin that is no longer valid and
   another certificate of the team (renewed: update the pin, the team keeps every permission). Never sign SkyCut with
   another team's certificate.
3. **A build signed ad-hoc (only with `SKYCUT_ALLOW_ADHOC=1`, «⚠️ SKYCUT_ALLOW_ADHOC=1: signing ad-hoc») or not notarized
   never goes to a user or a release.** No script sets the opt-out.
4. **Every code file in the bundle is named in `sign-app.sh`**, which refuses any other Mach-O: new code is signed on
   purpose, with only the entitlements it needs. A new protected resource (camera, location, contacts…) needs its usage
   description and its entitlement together, and a proof like the probe in the report; a runtime exception needs proof
   that a real feature fails without it.
5. **App 这边**：录自定义区域发现没授权时，先 `ScreenCapturePermissionRepair.resetRecordOncePerBuild()` 再
   `CGRequestScreenCaptureAccess()`。它用 `tccutil reset ScreenCapture <自己的 bundle id>` 删掉 SkyCut 自己那条
   录屏记录，**每个构建（cdhash）最多删一次**：删完、系统重新问过之后，同一个构建再被拒，要么用户没开，要么开了还没
   重开 SkyCut（授权下次启动才生效），再删只会把用户刚开的那条也删掉。改成固定签名之后升级不会再让记录作废，它兜的是
   改签之前留下的旧记录和没有证书的构建。调 `tccutil` 的只有它；起子进程用 `ChildProcess`（结束回调，不占线程）。
6. **给用户的话不写「关掉再打开」**：拨开关救不回钉着旧签名的记录。写「到系统设置里打开 SkyCut，再退出并重新打开」。
7. 冒烟用的开发版（`SrtFlowDev.app` 等，[GUI 冒烟流程](../testing/gui-smoke-testing.md)）照旧 ad-hoc：它们的权限本来就
   每次重给。

## 四、换签名的时候（每台机器一次）

- **2026-10-03, ad-hoc → self-signed**：老的记录全是 ad-hoc 的 cdhash，换签之后都对不上，每台机器还要再给一次：录自定义区域时 App
  自己删掉旧记录、系统问一次 → 到系统设置里打开 → 退出并重新打开；读下载文件夹弹一次；钥匙串里的 fal Key 弹一次「始终允许」。
- **2026-11-26, self-signed → Developer ID**: every grant names the old certificate (`certificate leaf = H"76d2…90ef"`), so
  the first Developer ID build asks once more: recording a custom region (the app deletes its own stale record once per
  build and the system asks; turn it on in System Settings, then quit and reopen SkyCut), the microphone, the Downloads
  folder, Finder automation, and the keychain (Allow… on the app's banner, the login password, Always Allow). Accepted:
  SkyCut has no users besides its owner (2026-11-25). After that, new builds and a renewed certificate keep them.

## 五、守卫与人工回归

| Check | Pins |
| --- | --- |
| `checks/release-signing.sh` (scan guard, `checks/release-signing/`) | rules 1–6, steps matched as whole lines (a step commented out or made conditional is red) and every failure branch checked to end the run: the build scripts' order (profile checked before the compile; the app signed and notarized before the DMG is built; the DMG signed, then notarized; the Beta signed, then notarized); one signing command with the runtime, inside out, entitlements only on the app, the timestamped identity only when `signing_mode` says so; the pin, the team and the profile name; `signing_mode_from` fed listings (pinned → Developer ID, expired pin or another certificate of the team → refused, no Developer ID of the team → ad-hoc); entitlements against Info.plist's usage descriptions, no runtime exception; notarytool only with the keychain profile; it also signs a fixture app ad-hoc with the opt-out (runtime on all four pieces, stray code refused); with stub `security`, `xcrun` and `codesign`, the real scripts refuse a failing `security`, an expired pin, no Developer ID without the opt-out, an unusable notary profile and another leaf certificate; the screen recording repair and wording |
| `scripts/check-mcp.sh` (`checks/MCP/packaging-wiring.sh`), `checks/web-motion-wiring.sh` | the helpers are copied in before signing and signed before the app |
| `sign-app.sh` itself | after signing: our team, the pinned leaf certificate, a timestamp, the runtime and the entitlements on every piece, the team requirement; unnamed code refused |
| `notarize.sh` itself | Accepted, stapled, `stapler validate`, Gatekeeper's «Notarized Developer ID» |

What no check reaches (system dialogs, System Settings, TCC.db needs Full Disk Access), before a release:

1. `codesign -dvvv` on the app and each helper: `TeamIdentifier=26TVX3S9FR`, `flags=0x10000(runtime)`, a `Timestamp=`;
   `codesign -d -r- dist/SkyCut.app` names the team.
2. `spctl --assess --type execute -vv dist/SkyCut.app` and `spctl --assess --type open --context context:primary-signature
   -vv <dmg>` say «source=Notarized Developer ID»; `xcrun stapler validate` passes on both.
3. A downloaded (quarantined) copy of the DMG opens directly: it mounts without a warning, and the app dragged to
   Applications opens after the standard «downloaded from the Internet» question, never through System Settings › Open Anyway.
4. The first Developer ID install asks once for each grant (section 四): record a custom region; the microphone (narration
   while recording, a voice sample in a new voice); Finder's selection; the Downloads folder; the keychain banner.
5. The next install (another cdhash) asks for none of them again, the keychain included (`teamid:` partition).
6. In a terminal with Full Disk Access: `sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "select hex(csreq) from
   access where service='kTCCServiceScreenCapture' and client='com.srtflow.SrtFlow'"` decodes (`xxd -r -p` → `csreq -r -
   -t`) to the team requirement (`certificate leaf[subject.OU] = "26TVX3S9FR"`), not `certificate leaf = H"…"` or a `cdhash`.

Testing permissions with a test bundle (seen 2026-11-26): give it its own bundle id and stage it in a normal folder if you
can. One under `/private/tmp` is not listed in System Settings' privacy lists, so the user adds it with «+», which records
the grant. `tccutil reset <service> <id>` cannot resolve its id (−10814): reset through a stub bundle with that id in a
normal folder (`lsregister -f`, reset, `lsregister -u`, delete). Proof run: [the report](../reports/2026-11-26-developer-id-signing.md) section 5.

## History: the self-signed certificate (2026-10-03 to 2026-11-26)

Kept as it was written; none of it is in use any more.

- **证书**：自签名、只能签代码（EKU codeSigning）、20 年，名字「SrtFlow Signing」（2026-10-18 改名 SkyCut 之后照旧用它：证书名用户看不见，换证书 = 所有授权再给一次，[产品名与代码名](product-name.md)）。签出来的 designated
  requirement 是 `identifier "<bundle id>" and certificate leaf = H"<证书的 SHA-1>"`，换版本不变，系统里给过的
  权限跟着走。2026-10-03 的探针：同一把证书签的两个不同构建（cdhash 不同）互相满足对方的 requirement
  （`codesign --verify -R`）；当时的钥匙串探针未覆盖 512 格式的分区名单，不能由 requirement 相同推断跨构建不弹框（见下方更正）。
- **不是 Developer ID**：不花钱，Gatekeeper 的表现不变 —— 照样没公证，下载来的第一次打开照样要「仍要打开」
  （`spctl` 照样 rejected）。哪天换成 Developer ID，requirement 再变一次，用户再给一次权限。
- **私钥在仓库外**：`~/.config/srtflow/signing/`（专用钥匙串 `srtflow-signing.keychain-db` + 它的密码
  `keychain-password`，目录 700、文件 600，同 `r2.env`）。仓库里只钉证书的 SHA-1：`packaging/signing-identity.sha1`。
- **签名只经一处**：`scripts/signing/sign-app.sh`。有签名身份就用它签，签完核对 requirement 真的钉在证书上；没有就退回 ad-hoc
  并警告。只换了签名身份：没开 hardened runtime、没有 entitlement，和 ad-hoc 时一样。
- **专用钥匙串只在签名那几秒挂上搜索列表**：codesign 只在搜索列表里的钥匙串中找身份，`--keychain` 只是在
  列表里挑，不在列表里就报「no identity found」（实测）。签完原样放回、锁上；不长期挂着 —— 上了锁的钥匙串
  留在列表里，别的 App 找证书时会弹框要它的密码。
- **建身份**：`scripts/signing/create-identity.sh`，一次性（2026-11-26 删掉）。用系统的 `/usr/bin/openssl`（LibreSSL）：Homebrew 的
  OpenSSL 3 默认导出的 p12 `security import` 认不出来。

### 2026-11-07 更正：钥匙串换了构建照样要问一次

上面「前一个构建在钥匙串里建的项，后一个构建不弹框就读得到」，对真实的版本升级不成立。

0.18.62 装上后第一次读 Sky Studio Key，系统弹框要登录密码。用 `security dump-keychain -a` 看那一条的访问表：
- 解密那一项信任 SkyCut，按的是固定证书的 requirement，每个构建都满足；
- 另有一项 `partition_id`，列的是 `cdhash:…`，即旧构建的代码哈希。

原因：
- 钥匙串的分区名单对带 Team ID 的 App 记 `teamid:…`；
- 我们的自签名证书没有 Team ID（`codesign -dvvv` 报 `TeamIdentifier=not set`），只能按代码哈希记。

结论：
- 每个新构建第一次读都要用户输密码。点「始终允许」把这一构建加进名单，只点「允许」下次启动还会问。
- TCC（录屏、麦克风、下载文件夹）按 requirement 认，固定证书照样管用。
- 只有换 Developer ID（有 Team ID）之后，钥匙串升级才不再问。

App 本来只在用户点了设置里的按钮时才弹框，后台问 `/me` 和 AI 起的活都只用不弹框的那一档。但这次弹框出在启动时，AI 的调用一直等在框后面。

修复与 512 格式探针见[钥匙串密码框堵住 AI 调用](../bugfixes/2026-11-07-keychain-prompt-blocks-ai-calls.md)：静默档关闭进程交互，全部读写共用专用串行执行器，静默等待有期限；启动显示非模态授权提示，用户点 Allow 后才问系统。每构建授权一次仍保留，实际新构建由用户验收。探针曾留下两张 SecurityAgent 框，杀进程不等于关框，之后禁止继续运行弹框变体。原始经过见[真积分验收报告](../reports/2026-11-07-image-models-and-characters-smoke.md)「发现」第 1 条。
