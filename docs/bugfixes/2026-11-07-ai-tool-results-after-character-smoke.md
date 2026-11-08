# 2026-11-07 0.18.62 真积分验收后的五处 AI 工具结果

> 来源：[全部图片模型与角色系统的真积分验收](../reports/2026-11-07-image-models-and-characters-smoke.md)「发现」第 2、3 条与真实任务表。
> 用户同日授权「把你发现的问题都优化了，按照你的建议来」。本次只修结果，钥匙串另一个 PR 处理；不使用真实 Key、不再次花积分。

## 症状

1. `list_characters` 28 个角色的回答 79,969 字，四个视图的资产 / 缩略图地址和长提示词挤占上下文，挑角色前就可能被客户端截断。
2. 换角度 / 放大没有提示词，下载成 `Image.png`、`Image 2.png`，看不出来自哪张图、做了什么。
3. qwen-angles 的任务已经 done，仍报 phase=queued；角色 done 仍报 processing，让 AI 以为还没结束。
4. 正常完成的角色被随后一次 get_job 改写成 `Original Character recovered`，像是重启找回原单。
5. nano-banana-pro / gpt-image-2 的远端结果没给宽高，已下载的图片在 get_job 里仍没有实际尺寸；seedream5-pro 恰好给了就正常。

## 根因

1. 列表直接序列化整份安全 DTO。安全不等于适合列表；服务端分页只限制条数，没有限制每条返回的上下文大小。
2. 普通生成用提示词前 24 字起名，图片专用操作禁止 prompt，走到通用 Image 回退，没有使用已经测量过的源路径。
3. 远端 phase 原样解析；角色的完成快照又合入了本机最后一份 activity.progress。AIJobs 虽然只在 running 时读 liveDetail，终态 detail / 后续刷新仍能重新带回旧阶段。
4. refresh 每次看到 ready 都调用 adoptRecovered 并写固定恢复文案，没有区分新请求正常结束、已有结局的重复读取与真正的原单恢复。
5. 下载后的 ImageIO 只用来确定真实格式和扩展名，最终宽高只读远端 result.width / height，没有采用已经落盘文件的像素元数据。

## 修复

1. `SkyStudioCharacterSummary` 只投影 id、name、status、revision、available_roles、保存的模型 / 档位和时间。每条含 JSON 转义最多 1,024 UTF-8 字节：名字按 JSON 字节预算裁短，不按可能无限长的 grapheme 数计；异常过长的可选模型 / 日期省略，不裁出一个错误身份。Page.json 使用摘要，缓存及 get_character 的完整 DTO 不变，分页与独立 capabilities 对象不变。
2. `SkyStudioGenerationName` 复用已有短名清理与 ExportFileName：显式 name 优先；否则源名去扩展名，加 angle / 请求倍率，例 `小屋 angle.png`、`小屋 x2.png`，撞名是 `小屋 x2 2.png`。普通提示词生成保持原命名。
3. `SkyStudioJobStatus` 在远端终态清 phase / 用时 / 排队位置；`AIJobs.json` 最后统一经 `AIJobResult` 清掉终态的进行中字段，覆盖普通生成、角色、失败、取消和后续刷新。账单和成品字段保留，运行中阶段照常显示。
4. `SkyStudioCharacterJobReport.completionMessage` 同时供首次完成和后续刷新使用。新请求及其重复读取说 Character ready；plan=nil 的重启 / resume，或原先失败的整理后来成功，才说 recovered。
5. `SkyStudioImageResult.format` 从真实下载字节取尺寸，与本机参考图共用考虑 EXIF 方向的 pixelSize。最终顶层 width / height 采用落盘几何；remote_result 保留远端原始证据，不由请求倍率推算、不重编码、不重生成。

## 验证

- `ToolResultChecks` 真跑假 URLSession → SkyStudioAPI.characters → Page.json，28 / 50 条（四视图、长提示词、中文名字、模型与时间）的整页分别 **10,364 / 18,460 UTF-8 字节**，约 **10.1 / 18.0 KiB**；UTF-16 长度分别 10,196 / 18,160；包进实际 MCP text-result envelope 后分别 11,601 / 20,621 UTF-8 字节。还覆盖 1 KiB 单条上限、控制字符 / emoji / 组合字符、所有字段同时接近预算、空视图、完整 DTO / 分页 / 能力不变。
- 同组经真实命名器检查源名、倍率、显式 name、普通提示词与碰撞编号；经实际任务解析器检查 done / failed / cancelled 的脏 phase 和运行中 phase；检查正常完成、重复读取与真正恢复的文案。
- `ImageResultChecks` 合成 JPEG / PNG，经生产下载器落盘、ImageIO 格式收口和真实尺寸读取；保留格式纠正 / 原字节 / 下载不带 Key 的旧守卫。
- MCP `JobResultChecks` 对共用最终 JSON 边界注入旧排队 / 传输 / 等用户字段，终态全部清理，成品和实收保留，运行中 / 排队中字段保留。扫描守卫钉住实际 AIJobs、生成、角色刷新和图片下载的接线，完整 App 编译覆盖适配层。
- 反向验证只替换临时目录中的源码副本，仓库生产文件保持修复：Sky Studio 撤回摘要、命名、远端终态、完成文案和尺寸投影，实际 **252 / 6,351** 项断言失败；MCP 撤回共用终态边界，实际 **6 / 3,289** 项失败。五类各有红项，均为成功编译后运行时断言，不把编译失败算作验证。
- 完整 App target 编译通过；正式源码运行 `scripts/check-local.sh sky-studio mcp`，顺序验证全部扫描守卫和上述两套检查；受共用任务 DTO / 摘要依赖影响的 upscale / 官方制作路径另验通过（123 / 304 项）。最终全部扫描守卫、6,351 项 Sky Studio、3,289 项 MCP 正向检查通过。首轮 MCP 的一条既有 2 秒音频读取超时在重跑时通过；未跳过或放宽该守卫。工具全清单连 envelope 为 106,306 / 110,000 UTF-16 单位，总说明 2,012 / 2,048，三个角色工具说明均在 512 内。

### 实机验证（2026-11-08，正式版 0.18.63）

用真 Key、真积分（28 积分）：
- `list_characters`：同一账号 28 个角色，回答 10,786 字（UTF-8 10,890 字节），修复前 79,969 字。
  - 每条只有 `available_roles`、`created_at`、`default_generation_model`、`default_generation_resolution`、`id`、`name`、`revision`、`status`、`updated_at`；
  - 没有任何地址字段。
- 换角度：源图 `A red vintage bicycle le.png` → `A red vintage bicycle le angle.png`，1376×768，8 积分。
- nano2-lite：`A paper boat floating on.jpg`，`get_job` 报 1376×768。修复前同一模型宽高是 null。
- 两单 done 之后 `phase`、`queue_position` 都不再出现。
- 角色完成的文案没有再花积分去实测，由 `ToolResultChecks` 覆盖。

## 教训 / 防回归

- 列表和详情是不同的上下文预算，不能因为 DTO 安全就整份透传。按真实 JSON 字节量边界，既测一条极值，也测默认页和实际规模。
- 已结束是比“最后一次阶段”更强的事实；在最终结果边界统一清理，不能只修改一条服务端字段或只修角色。
- 查询不是恢复；账单、原单身份与完成来源要分开描述。
- 原始远端元数据保留作证据，交付几何从已保存文件读，不让服务端漏字段变成客户端永久不知道。
- 长期约束见 [Sky Studio 的任务](../architecture/sky-studio-jobs.md)第十二、十三节与 [AI 接口](../architecture/ai-control-mcp.md)第 56 条。
