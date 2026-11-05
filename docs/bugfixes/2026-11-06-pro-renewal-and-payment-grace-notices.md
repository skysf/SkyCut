# 2026-11-06 Pro 快到期和续费失败宽限没有提醒

## 症状

已付费但不会自动续费的账号快到期，设置只有「Pro 到哪天」，导出面板没有续约说明。自动扣款失败但仍在宽限中的账号也没有付款失败和更新付款方式的提示，AI 的 get_status 无法转告用户。

## 根因

#321 已读取并缓存 auto_renews / pro_source / grace_until，#322 已完成台数说明，但此刻授权和呈现尚未接入续约状态。导出提醒原先只在要带视频水印时显示，正常 Pro 没有水印，不能直接把续约提醒塞在那条条件里。paid_until 原本只作日历显示，若直接与本机 now 比较会忽略服务器钟差；若反过来把显示日期整体挪钟差，又会重现午夜日期跳一天的问题。

## 修复

- 纯值 `SkyCutProNotice` 由有效 `SkyCutLicense.evaluate` 产生，设置 / 导出 / AI 共用。明确 false、未来七天内才提醒，天数向上取整；到期不等于客户端自行降级。
- manual 续约只给客服邮箱；其余用服务器可用地址或邮箱。宽限优先说明扣款失败、保留日期和更新原订阅付款方式，不建议另购订阅。台数满了不叠加提醒。
- 日历日期照服务器给的时刻；倒计时沿用 stored.local。旧服务器 / null 不猜状态，所有提醒都不能改变 plan / features / valid_until。
- `SkyStudioProNoticeRow` 复用邮箱复制，三语言齐全；导出无水印 / 只出音频也显示续约提醒，只出音频仍不显示水印说明。get_status 增加英文 pro_notice，不改 AI 能否使用。

## 验证

- `scripts/check-sky-studio.sh` 的 `ProNoticeChecks` 使用合同 fixture，覆盖七天边界及两侧一毫秒、整天 / 不足一天、刚好到期 / 已过期、钟差 / 请求延迟、可选字段、商务 / 订阅 / 一次性来源、链接 / 邮箱、宽限 / 台数优先、缓存失效和功能开关组合。
- `checks/sky-studio-wiring.sh` 钉住设置 / 导出共享提醒、动作目标、邮箱选中 / 复制、音频条件和 get_status 生产接线；本地化覆盖检查核对各语言键和插值。
- **反向验证（2026-11-06）**：临时把 SkyCutLicense 的 proNotice 接线改为 nil，84 条断言变红（5,215 条执行，退出 1）；去掉 manual 的购买地址限制，4 / 5,218 条变红（退出 1）；倒计时直接用服务器时刻而不经 stored.local，25 / 5,218 条变红（退出 1）。移除设置提醒、移除导出提醒、把更新付款方式链接接到建 Key 页，三次接线守卫分别退出 1。每次均在 finally 中逐字节恢复原源码。
- 修复版本 `scripts/check-sky-studio.sh`：5,218 条通过；`scripts/check-localization-coverage.sh`：1,064 条界面文案在 en / es / zh-Hans 中完整。arm64 调试 App 编译通过；检查需要本机 SwiftPM 子沙箱 / 模块缓存权限，沙箱拒绝没有算作通过。
- 推送前 `arch -arm64 /bin/bash scripts/check-local.sh sky-studio localization-coverage export-watermark`：全部扫描守卫及点名三项通过，水印真实导出 67 条通过；独立 worktree 只用本机主 worktree 已有的 vendored ffmpeg，不下载新依赖。
- 独立 `com.srtflow.SrtFlow.prc.skystudiosmoke` 真 App + 回环假服务：到期链接、商务邮箱、到期邮箱、宽限链接、宽限邮箱、台数满了、旧回答七种场景通过。前五种分别切 en / zh-Hans / es，15 组真实 get_status / seek 均通过：状态始终英文、入口与纯值一致、提醒不挡 AI；台数仍拒绝 seek，旧回答无提醒。结果在本机 `/private/tmp/skycut-prc-smoke/pro-notice-mcp-report.json`。
- **GUI 未完成**：本机图形会话锁屏（IOConsoleLocked / CGSSessionScreenIsLocked），computer use 识别到测试进程但报 cgWindowNotFound，无法看窗口。三语言排版、按钮实点和复制操作留在架构文档人工清单中，不把编译 / 接线 / MCP 冒烟当作 GUI 已通过；不连接真实账号或支付。

## 教训 / 防回归

续约提醒和权限判断是两件事；有授权但要用户处理付款，也必须让两个界面和 AI 看见。日期显示和倒计时比较沿用各自既有口径，不能为新提示另造钟差。长期约束与人工回归已写入 [Sky Studio 账号](../architecture/sky-studio-account.md)。
