# 2026-10-27 连接 AI 客户端时留的配置备份，谁都能读

## 症状

2026-10-26 真 Codex 冒烟（[报告](../reports/2026-10-26-codex-client-smoke.md)第一节）：在设置里点「连接 Codex」，SkyCut 在 `~/.codex/config.toml` 旁边留了一份
`config.toml.skycut-backup`。原文件的权限是 `-rw-------`（600，只有本人能读），备份却是 `-rw-r--r--`（644，谁都能读）。
同一次误点连上的 Claude 桌面版也一样：`claude_desktop_config.json` 是 600，`claude_desktop_config.json.skycut-backup` 是 644。

这次没泄露什么（用户的 Codex 配置里令牌走环境变量），但这几份配置里**可以直接写着密钥**（Codex 的 MCP 服务器能带令牌、Claude 桌面版的 `env`），
而这台 Mac 的家目录是 755、`~/.codex` 也是 755：本机别的账户能一路走进去读这份备份。

## 根因

- `AIClientSetup.rewrite` 第一次改配置之前，用 `original.write(to: backup)` **另写一个新文件**当备份 —— 新文件用的是默认权限（umask 022 下就是 644），
  原文件的 600 没跟过来。
- 改写配置本身用的是 `Data.write(options: .atomic)`，它换文件时会带上原文件的权限，所以配置本身一直是 600 —— 只有备份这一处漏了，
  看配置文件的权限是看不出来的。
- 这段代码写在 `AIClientSetup` 这个 `@MainActor` 的界面类里，`check-mcp` 编不到它，连接的自检只测了「改了什么」（`AIClientConfigFiles` 的纯值），
  没测过写到盘上的文件。

## 修复

- 抽出 `Sources/SrtFlow/AIClientConfigWrite.swift`（只依赖 Foundation，`check-mcp` 编得到）：读 → 改 → 原子写回；第一次改之前存备份，
  **备份一建出来就是原文件的权限**（`open(O_WRONLY | O_CREAT | O_EXCL, 原文件的权限位)`，不走「先建再改权限」，中间不留谁都能读的空档）。
  照原文件的权限来，不是一律改成 600（原文件 644 的，备份也是 644）；配置是个链接时按它指着的那个文件算；读不到权限按最严的 600。
- `AIClientSetup.rewrite` 只调它。

## 验证

- `checks/MCP/ConfigBackupChecks.swift`（`scripts/check-mcp.sh`，CI 第 4 组）：600 的配置备份也是 600、内容是原文、配置本身改了且还是 600；
  再改一次备份不动；644 的原文件备份是 644；链接的配置按目标文件的权限和内容备份；没有原文件不建备份。
- `checks/client-config-backup.sh`（扫描，`check-all.sh` 第 1 组）：整个 `Sources` 里只有 `AIClientConfigWrite.swift` 写 `.skycut-backup`，
  `AIClientSetup` 改配置经过它。
- 反向验证（本机只编这两个小文件，不编整个自检）：备份换回 `original.write(to:)`，11 项里 3 项红（600 的配置、再改一次、链接，备份都成了 644）；
  放回去全过。在 `AIClientSetup` 里放回自己写备份的那几行，扫描红；放回去绿。

## 教训 / 防回归

- **「另写一份」不等于「拷一份」**：内容一样，权限、扩展属性都是新的默认值。存别人的配置（尤其可能带密钥的）时，权限要从原文件来。
- 只测「改成了什么」的纯值，测不到「写到盘上是什么样」；写文件的那一下要能被自检编到，就从界面类里抽出来。
- 没修、另记一笔：配置是个链接时，原子写回会把链接换成一个普通文件（用 dotfiles 仓库管配置的人，仓库里那份就不再更新）。
  这是 `Data.write(options: .atomic)` 的行为，和这次的权限无关，要改另开一个 PR。
