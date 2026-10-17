# 2026-10-17 open_folder 第二个文件夹时，结果里的 output_folder 还是上一个文件夹

## 症状

AI 多开第 ② 刀的测试版冒烟（0.18.39）：一个会话先 `open_folder Trip`、`new_project`，再 `open_folder Wedding`。第二次 `open_folder` 的结果里
`folder` 是 Wedding，`output_folder` 却是 `Trip/SrtFlow` —— AI 照着这一句去告诉用户「成片会放在 Trip 里」，其实之后的 `new_project`、
`get_status` 都已经按 Wedding 算了（`Wedding/SrtFlow/…`）。只有 `open_folder` 自己那一次的结果是错的。

## 根因

第 ②a 刀（PR #229）给每个 AI 调用加了 task-local 的 `AICallContext`，里面除了「哪个会话、哪个工程」，还**在调用开始时抄了一份文件夹**
（`folder: AIWorkspace.shared.folder(project:session:)`），`AIWorkspace.current` 优先用这份抄下来的。`open_folder` 正是那个会在调用当中
换掉这个会话的文件夹的工具：它先 `register` 新文件夹，再按 `current` 算 `output_folder` —— 拿到的还是调用开始时抄的旧文件夹。

抄一份的初衷是「几个子代理并排调用时各是各的」，可那靠的是**按谁来查**（这个工程记的文件夹 → 这个会话记的文件夹），不是抄下来的那一份：
同一个会话里换文件夹这件事本来就该马上生效，抄下来只会让同一个调用的前后两半说两种话。

## 修复

- `AICallContext` 只放「是谁」（会话、客户端、工程、停止时跟哪个工程），不再放文件夹（`Sources/SrtFlow/AICallContext.swift`）。
- `AIWorkspace.current` 在 AI 的调用里按 `folder(project: context.project, session: context.session)` **现查**；界面上照旧是最后点名的那个
  （`Sources/SrtFlow/AIWorkspace.swift`）。路由建上下文时不再传文件夹（`Sources/SrtFlow/AIToolRouter.swift`）。
- 子代理不串台照旧成立：碰工程的调用先按工程记的文件夹（打开 / 新建它时点名的那个），别的子代理后来 `open_folder` 不改它。

## 验证

- 扫描守卫（`checks/MCP/router-wiring.sh`，由 `scripts/check-mcp.sh` source）：`AICallContext` 里不许再有 `var folder`、`AIWorkspace.current`
  必须按调用是谁现查。反向验证：把三处改回修复前（`git stash`），守卫当场红；恢复后绿。
- 真机：用这个分支打的测试版重放同一段（`open_folder Trip` → `new_project` → `open_folder Wedding`），第二次的 `output_folder` 是
  `Wedding/SrtFlow`；之后 `add_clips project=p2` 引用 Trip 里的同名 C0001.MP4 仍落在 Trip 那一份上（工程记的文件夹没被改）。

## 教训 / 防回归

- 放进 task-local 的东西只放「这一次调用是谁」这种整个调用里不会变的身份；会被调用自己改掉的状态（当前文件夹）要现查，不能抄一份。
- 冒烟要走「同一个调用里先改再读」的工具（`open_folder` 改文件夹又报文件夹），别只验前后两个调用之间对不对。
- 长期约束写在 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第四节第 46 条 ⑥。
