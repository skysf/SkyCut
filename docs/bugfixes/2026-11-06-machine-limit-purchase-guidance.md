# 2026-11-06 台数满了却引导再买 Pro，水印说明固定叫人发邮件

## 症状

账号已有 Pro，但当前 Mac 因 `machine_limit_reached` 使用免费版时，设置、导出和 AI
仍按普通免费账号提示开通。购买配置打开、`upgrade_url` 非空后，甚至会叫已经付费的
用户再买 Pro。另一个入口中，带水印的导出给 AI 的说明总是要求发邮件，忽略购买地址。

## 根因

`SkyCutLicense.proActivationURL` 只排除了当前 `plan == pro`，没有区分账号已有授权、
当前 Mac 因台数被降级的情况。#321 虽已读取并缓存全部可选字段，却还没有把原因、
台数和管理地址送到当前授权的展示路径。`SkyCutGates.watermarkNote` 还是静态常量，
内部固定用 `.free(.noKey)`，无法读取此刻授权中的购买 / 管理信息。

## 修复

- 有效的当前授权携带可选原因、原话、`machines.limit` 和经过既有网址校验的管理地址；
  台数满了时 `proActivationURL` 恒为 nil，不以这些说明字段重新计算功能。
- 设置和导出复用 `SkyStudioContactRow`：认识台数原因就本地化台数和当前 Mac 免费，
  引导管理 Mac / 客服；未知原因原样显示 `plan_message`。三种界面语言同时补齐。
- AI 拒绝、`get_status` 的下一步和水印说明共用管理优先的英文提示。水印说明改为
  `watermarkNote(license:)`，导出开始 / 完成都读取那一刻的当前授权。
- 新 fixture `me-machine-limit-purchase-v1.json` 同时返回台数拒绝和非空购买地址，
  防止将来因购买配置开启又出现重购入口。

## 验证

- `/bin/bash scripts/check-local.sh sky-studio localization-coverage`：全部扫描守卫、
  Sky Studio 断言和三语言覆盖检查通过；补充刷新问题不隐藏台数提示的断言后，
  `check-sky-studio.sh` 共 **3,122 条通过**。完整 arm64 App 编译通过。
- 反向验证：撤掉 `proActivationURL` 的台数优先条件，**50 / 3,118 条失败**；
  水印说明改回固定无 Key 快照，**172 / 3,118 条失败**。两个检查均退出 1。
  将真实导出调用改用无 Key 快照、断开管理按钮，接线守卫也分别退出 1。全部恢复。
- 独立 `.prb.skystudiosmoke` App、回环假服务和假 Key：三语言 × 设置 / 导出 ×
  管理链接 / 邮箱，共 **12 种真实窗口截图**。主窗口 1180×740、设置默认宽度 750，
  所有提示完整，均无购买入口。采用仓库进程内 `SmokeDriver`，仅测试包将设置初始
  分类暂改为 Sky Studio，截图后源码逐字节恢复；管理链接实点与复制邮箱留人工清单。
- 真实测试 MCP：台数满了的管理链接 / 邮箱两种回答，`get_status` 与 `seek` 拒绝均
  说明 2 台和这台免费，西班牙语 App 下返回仍为英文。临时将免费 fixture 改成有效
  体验，合成 1 秒视频实际导出成功，`export_video` 与完成的 `get_job` 的水印说明
  都给当前购买地址、不再要求发邮件；fixture 用后原样恢复。

本机证据在 `/private/tmp/skycut-pr-b-gui/`（截图、进程内日志与 `mcp-report.json`），
反向日志在 `/private/tmp/skycut-pr-b-reverse-*.log`。没有读取生产 Key、请求真实支付，
不据此宣称真实服务端已实现新合同。

## 教训 / 防回归

账号授权与当前 Mac 的授权要分清；去哪里处理问题也是授权快照的一部分，不能只用
plan 是否为 Pro 来选择购买。凡给 AI 的水印说明都必须用当前授权，不能用固定的免费
快照。长期合同、守卫和人工回归见[Sky Studio 账号](../architecture/sky-studio-account.md)。
