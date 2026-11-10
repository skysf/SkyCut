# 2026-11-10 说明书的 fields 一节漏写参数定义里的可选值、类型和条数

## 症状

`skycut_guide` 的名片说说明书给出「每个字段的类型、可选的值和范围」（PR #344 合进 main 的那一版），实际 `fields` 一节漏了好几样：

- `set_settings.optimized_media_cache_gb` 只能选 2 / 5 / 10 / 20 / 50，写出来只有 `(integer)`：AI 读了说明书照样会传 15、被拒；
- `generate_media.camera_angle` 的 `rotate` / `tilt` / `zoom` 档位全没了 —— Codex 会删掉 `generate_media` 的参数说明（超过 5,000 字节），
  本来要靠说明书兜底，说明书也不写；
- `generate_media.duration`（数字、`"auto"` 或 null）、`seam_review.previous` / `next`、`save_project.production` 都写成了 `any`；
- 批量工具（`edit_clips` / `set_texts` / `set_shapes`）「最多 100 项」没了。

协调者派的审查代理按 base / head 各编一份 `SrtFlowMCPKit`、把真实输出导出来核对时发现（审查记录 review-344 第 1 条）。

## 根因

- `MCPGuideFields` 只认字符串枚举（`compactMap(\.stringValue)`），数字的可选值整个丢掉；
- 只看 `type` 是不是一个字符串：`["object","null"]` 这种并集和 `anyOf` 都落到 `any`；
- `maxItems`、`minLength`、`maxLength`、`additionalProperties` 从来不写。
- 守卫没抓住：`GuideChecks` 只抽查 `edit_clip` 的 4 行（全是字符串枚举和普通范围），没有拿真实清单逐个核对。

## 修复

- `Sources/SrtFlowMCPKit/MCPGuideFields.swift`：可选的值任何类型都写（字符串照原样，数字、布尔、null 照 JSON 写法）；类型并集写成
  `object or null`；`anyOf` / `oneOf` 的每一种写法连同它自己的可选值都写（`number or string (one of: auto) or null`）；条数、长度的上下限、
  能不能带别的字段都写；`anyOf` 里对象的字段照样往里缩进。另外公开 `entries(for:)`（每个参数的路径 + 那一行），给守卫按路径找那一行。
- 现在 `generate_media` 整份超过 6,000 字，第一次回概要 + 有哪些节、`fields` 按 `section` 取（分节本来就有，这是它第一次真用上）。

## 验证

- 新守卫 `checks/MCP/GuideContentChecks.swift` 的 `runGuideFieldFactChecks`：自己走一遍真实清单（不借渲染代码），每个参数的每一样事实都要
  出现在它自己那一行；走空了算红（至少 200 条，2026-11-10 是 250 条）；审查点名的五处单独再查一遍。
- 反向验证（每样单独换回修复前的写法）：只认字符串的可选值 → 红 6 条（`camera_angle` 三个档位、`optimized_media_cache_gb` 和点名的两处）；
  不认并集和 anyOf → 红 8 条（`production`、`seam_review.previous` / `next`、`duration` 的三种写法和点名的两处）；不写条数 → 红 12 条（三个批量工具的
  1 到 100 项、四处「至少 1 项」……）；fields 漏掉第一层的 `x` → 红 6 条（按路径认那一行，里层同名的不算）。恢复后转绿。
- `scripts/check-mcp.sh` 全绿。

## 教训 / 防回归

- 说「写全了」的地方，守卫要拿真实数据逐个核对，抽查几行同一种写法的等于没查。
- 长期约束（fields 必须写出参数定义里的每一样事实、守卫怎么查）写在 [MCP 说明书](../architecture/mcp-guide.md)第三节第 5 条。
