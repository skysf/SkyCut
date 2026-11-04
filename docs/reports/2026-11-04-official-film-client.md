# 2026-11-04 官方原创短片客户端接入

本报告按实际证据更新。长期合同见 [官方原创短片](../architecture/official-film.md)。
只记录公开合同和合成测试，私有配方、研究来源、凭据与不透明 pin 不进入仓库。

## 分项状态

| 范围 | 当前证据与边界 |
| --- | --- |
| 客户端 API 合同 | 已实现公开 film、严格状态 / 动作 / cut 校验、官方真实引用报价、pin / 双侧审查传输、精确审批身份；MCP 运行路径待后续接入 |
| 工程内连续性与声音计划 | 公开合同已定义，持久化、实际使用区间和验收失效仍待接入 |
| 后台 App / MCP 验收 | 本轮尚未执行；先完成免费隔离服务验收 |
| 真实视频生成 | 本轮尚未执行；需要当前实时报价及新的预算授权，历史批准不能复用 |
| 服务端生产启用 | 2026-11-04 只读核查：受控发布开关为 false；包含官方基础实现的服务端 main 对应发布运行被跳过，不能据合并声称已启用 |
| 并发容量 | 本轮未发起 10 / 100 用户真实负载，不把本机幂等测试计为容量验收 |

服务端基础实现已合并于 [Sky Studio PR #234](https://github.com/skysf/skystudio-aigc-app/pull/234)，
对应的 [受控发布运行](https://github.com/skysf/skystudio-aigc-app/actions/runs/41682319535) 为 skipped。
这两项分别说明代码状态与该次发布状态，不能证明生产中的私有配置已激活。

## 第一刀：公开合同

- `SkyStudioFilm` / `SkyStudioFilmReader` 只验证公开故事声明；不猜服务端私有支持范围。
- `SkyStudioFilmInputs` 保住实际原创图片输入、顺序和首尾角色。官方 quote 带真实 inputs；普通 quote 保持原格式。
- `SkyStudioOfficialRecipeQuote` / `SkyStudioSeamReview` 保留不透明 pin、有效期和双侧指纹。
  缺官方报价回答时失败，不退到普通生成。修订 1 的中间镜头也要求左右两侧。
- `SkyStudioApproval` 对官方请求把 film、引用、pin、当前审查和价格绑定；普通请求身份保持原样。
- 审查中修正了提示词长度的跨语言差异：与服务端相同，裁掉首尾空白后按 Unicode scalar 计数。

专项自检 `scripts/check-sky-studio.sh`：1,259 项通过。两次反向验证均实际变红：
临时不发送官方 quote 的 inputs，4 项失败；临时撤掉已完成动作保护，2 项失败。恢复后 1,259 项再次通过。
`scripts/check-guards.sh` 全部扫描守卫通过。
没有访问真实生成服务、上传研究素材或消耗生产积分。

本地 `scripts/check-all.sh` 全部通过（含完整 App、1,259 项 Sky Studio、123 项 upscale、3,168 项 MCP）。
PR / CI 证据在完成后补记；本地通过不代替 GitHub 汇总 job 的结论。
