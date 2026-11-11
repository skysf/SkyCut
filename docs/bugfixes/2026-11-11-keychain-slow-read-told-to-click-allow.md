# 2026-11-11 钥匙串只是慢，AI 却被告知「请用户点 Allow…」

## 症状

2026-11-11 真实冒烟（[报告](../reports/2026-11-11-voice-real-smoke.md)第八节「发现」3）：机器正忙（负载 8，同时在打 0.18.65 的包），
测试 App 重启后第一个 AI 调用（`list_voices`）回：

> SkyCut needs the user's permission to read the Sky Studio key. Ask the user to click Allow… on SkyCut's notice, …
> In the macOS dialog, enter the Mac login password and choose Always Allow, then try again.

其实什么框都没有、也不需要授权：同一个调用几秒后再来一次就读到了 Key。照这句话做，AI 会叫用户去点一个根本不存在的系统框、输一次登录密码。
App 这边同样挂出「允许…」的提示。

## 根因

2026-11-07 的修复（[新构建钥匙串密码框堵住 AI 调用](2026-11-07-keychain-prompt-blocks-ai-calls.md)）给静默读加了 3 秒期限：
期限到了、或者那次读还在跑时又有人问，`KeychainSecretCache` 一律回 `.needsPermission`。可那时已经证明，**真要授权时静默读零点几秒就被拒**
（进程交互关掉之后，分区名单不匹配回 `errSecAuthFailed`，约 0.25 秒；0.18.63 实机启动 1.4 秒就回了 `get_status`）。
所以「3 秒还没回答」说明的是钥匙串忙（securityd 被别的活压着），不是要授权；把两种情况报成同一个结果，AI 和界面只能都说「去点 Allow…」。
11-07 的自检把这一点钉成了对的：「a blocked read returns permission-needed at its deadline」「a second caller does not wait behind a blocked read」都期望 `.needsPermission`。

这次冒烟里，启动时 `SkyStudioAccount` 自己的静默读先起了，AI 的调用碰上「那次读还在跑」，立刻拿到 `.needsPermission`；几秒后那次读迟到成功、缓存上了，重试就好。

## 修复

- `KeychainSecret.ReadResult` 加 `.slow`，只由缓存的静默读给：期限到了、或者那次读还没过期限就有人问，回 `.slow`；**回过一次「慢」之后那次读还没回来又有人问**，
  回 `.needsPermission`（再等也没用，这时才叫用户点）。交互读在跑照旧回需要授权（系统框在等用户）。`KeychainSecretCache.swift`。
- `SkyStudioJobKey`：`.slow` → `Problem.keychainSlow`，给 AI 的话是「钥匙串还没回答、没有授权框，过几秒同样的调用再来一次；只有重试时说要授权才叫用户点 Allow…」
  （`SkyStudioKeychainNoticePolicy.aiSlowNextStep`），**不发 `permissionNeeded`**（不挂「允许…」的提示）。所有 AI 付费工具都经它，话自动换过来。
- `SkyStudioAccount` 启动 / 后台的静默读碰上 `.slow`：先不提示，等 5 秒（`slowRetryDelay`）再静默读一次，还不行才照要授权处理（只重试一次）。
- 用户点「允许…」时（`KeychainSecretCache.key(willAsk:)`）静默读慢也照样进交互档。
- 声音库那一节 / 变声面板：`keychainSlow` 显示已有的「暂时用不了，稍后再试」，不叫用户去点 Allow…（没有新文案）。
- 规矩写进 [Sky Studio 账号](../architecture/sky-studio-account.md)「新构建的钥匙串授权」和 [阻塞的媒体读取](../architecture/blocking-media-reads.md)。

## 验证

- `scripts/check-sky-studio.sh` 的 `KeychainCacheChecks`（注入的假读取器，不碰真钥匙串、不弹框）：
  - 改了两条 11-07 的期望：期限到了是 `.slow`、那次读没过期限时别人问也是 `.slow`；加一条：回过「慢」之后那次读还没回来再问 → `.needsPermission`。
  - 新的 `runJobKeySlowChecks` 走生产的 `SkyStudioJobKey.key(.silent)`：第一次 `keychainSlow`、**没有**发授权提示、话里有「Wait a few seconds」「repeat the same call」
    「no permission dialog」且没有「Mac login password」；那次读还在跑时重试 → `needsPermission` 并发提示；读回来之后再试 → 拿到缓存的 Key，原生读只有一次。
- `checks/sky-studio-wiring.sh`：缓存的两处早回、期限到了 `finish(.slow)`；账号那边 `.slow` 先等 `slowRetryDelay` 再静默读一次、`case .needsPermission, .slow:`；
  `SkyStudioJobKey` 的 `.slow` → `keychainSlow`、`permissionNeeded` 只发一处。
- **反向验证**（类型都留着，只撤行为，不拿编译失败充数）：
  1. 缓存换回 11-07 的早回和 `finish(.needsPermission)`：4 条逻辑断言红（别人问、期限到了、AI 第一次的结果、不该发的提示），接线守卫红；
  2. `SkyStudioJobKey` 把 `.slow` 当要授权（发提示、回 `needsPermission`）：2 条逻辑断言红，接线守卫红；
  3. 去掉账号那边的重试：接线守卫红（账号是单例、读生产钥匙串，这一条只由扫描钉）。
  换回修复：`scripts/check-sky-studio.sh` 7,683 条全过，接线守卫绿。
- 没有在真机上再造「慢」：要把 securityd 压到 3 秒以上不可控，也不该为此去碰用户的钥匙串；冒烟里的现场原样记在报告里。

## 教训 / 防回归

- 一个期限到了，只说明「还没回答」，不说明原因；能用别的证据分开的（这里：要授权时零点几秒就拒），就别把两种原因报成同一个结果。
- 给 AI 的下一步要和真实情况一致：叫用户去点一个不存在的框，比让 AI 多重试一次代价大得多。
- 期望值要从意图来：11-07 的自检照实现写了「期限到了就是要授权」，修这一条时先把期望改对，再看它红不红。
