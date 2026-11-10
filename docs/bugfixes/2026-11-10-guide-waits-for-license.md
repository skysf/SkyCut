# 2026-11-10 说明书要先等授权问完才回答

## 症状

`skycut_guide` 写着「free, read-only, instant」、在 Claude Code 里预先加载，是 AI 一上来就调的那个工具。可每次调用都先等授权问完：
有 Key、这次启动还没问过授权（或者上次问到的已经过了 `valid_until`）时，要先读钥匙串、再问 Sky Studio 的 `/me`，网络慢就卡到 `/me` 回来，
最长 20 秒（`SkyStudioAPI.requestTimeout`）；`/me` 一直失败时，每次调说明书至少还要睡 100 毫秒。一个标成 `openWorld=false` 的只读工具因此
去读钥匙串、发网络请求。审查记录 review-344 第 2 条。

## 根因

PR #344 把 `skycut_guide` 加进了 `SkyCutGates.alwaysAnswered`（没开通也照答），但路由的门 `SkyStudioAccount.aiRefusal(for:)` 是**先**
`await settledLicense(...)`、**再**问 `aiAllows`：放行的判断在等待之后，所以「不看授权的工具」照样要等授权。`get_status` 也走这条路，
但它该等：它报的 `skycut_plan` 就是问完的授权。

## 修复

- `SkyCutGates.answeredBeforeLicenseCheck = [.skycutGuide]`：说明书的回答不看授权，连等都不用等。
- `SkyStudioAccount.aiRefusal(for:)`：照授权拦生效时，先放行这个集合里的工具（返回 nil），再去等授权。`get_status` 不在里面，照旧等。

## 验证

- `checks/SkyStudio/GateChecks.swift`：`answeredBeforeLicenseCheck` 正好是 `skycut_guide`，而且是 `alwaysAnswered` 的子集（`get_status` 不在里面）。
- `checks/sky-studio-wiring.sh` 第 5 节：`aiRefusal` 里放行它的那一句在 `await settledLicense(` 之前。
- 反向验证：把放行那一句挪到等待之后（修复前的顺序），`checks/sky-studio-wiring.sh` 变红（放行在第 5 行、等待在第 4 行）；把集合改成空，
  GateChecks 红 1 条；恢复后转绿。
- `scripts/check-sky-studio.sh` 全绿。

## 教训 / 防回归

- 「这个工具不受某个条件约束」时，要连「等这个条件」一起免掉，不能只在等完之后放行。
- 长期约束写在 [MCP 说明书](../architecture/mcp-guide.md)第三节第 2 条和 [Sky Studio 账号](../architecture/sky-studio-account.md)「AI 的门」。
