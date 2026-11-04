# 2026-11-04 成片检查没有疑点却报告绘图失败

## 症状

后台 MCP 对连续明亮画面及正常声音执行 `inspect_video`，结果 `findings=[]`、
`coverage_complete=true`、`screenshot_times=[]`，却同时报告 SkyCut 无法绘制画面。
这使一次完成的检查看起来像取帧失败。

## 根因

成片检查只为疑点请求证据截图。没有疑点时待截图列表为空，但收尾仍把用户默认的
`image=true` 当作“已请求截图”，共用 `AILookTool.finish` 因没有帧而生成失败提示。
分析取样与证据截图是两个阶段，不能用一个布尔值混为一谈。

## 修复

`AIInspectionTool` 仅在用户要图且实际证据列表非空时向拼图层声明要图。
有疑点而图片实际不可用仍报失败，`look` 的缺帧提示保持有效。

## 验证

已保存的后台 MCP 证据确认了修复前症状：任务 `done`，
`coverage_complete=true`，分析取样从 1.5 到 4.5 秒，`findings=[]`、
`screenshot_times=[]`、`limitations=[]`，却有“could not draw the picture”提示。
原证据位于本机测试目录 `official-evidence-1793763903000533000/inspection.json`。

新增 `checks/VideoInspection/Main.swift` 守卫经真实工具入口检查连续正常画面和声音
的 5–6 秒区间：完成分析、无疑点、无需截图且无绘图失败提示；另验证实际请求却缺图
仍有失败提示。实际 `scripts/check-video-inspection.sh` 安全反向只撤掉
`!wanted.isEmpty` 条件，得到 **35 条断言、1 条失败**：唯一失败正是干净区间
错误报告绘图失败，其余疑点取证与真实缺图语义通过。恢复条件后同脚本重新编译、
链接生产 App，得到 **35 条断言、0 失败**，退出码 0。

本机日志保存在 `skycut-inspection-empty-evidence-20261104/branch-verification/`。
首次沙箱运行被 Swift 编译缓存写入权限阻断，未执行断言，单独归档且不计入反向红；
取得窄编译权限后才得到上述真实红 / 绿。反向结束后逐字节恢复生产源，正向未改源码。

实施前的 `/tmp` 独立入口试编在 180 秒编译截止时结束，尚未运行任何媒体断言，
不能计为专项或反向通过。该次失败记录单独保留；本分支改用仓库的实际
`scripts/check-video-inspection.sh` 编译、链接和测试生产代码。

单场景实际 MCP 入口 `scripts/gui-smoke/sky-studio/inspection.py` 已通过：13 次真实工具调用，
自有后台工程导入 8 秒蓝画面与连续正弦音的合成素材，默认 `image=true` 检查 5–6 秒。
任务 `done`，`coverage_complete=true`，实际取样 `[5, 5.5, 6]`，疑点、截图时刻、
图像内容、限制均为空，没有 `image` 失败字段。工程保存并关闭，结束时没有任务。

证据目录为 `srtflow-inspection-empty-mcp-20261104/inspection-empty-evidence-1793778562972379000`。
复制的 App 与 helper 可执行代码段分别和刚链接产物一致。假服务仅收到 `GET /me`，
没有报价、上传、准入或真实 provider 调用，本机花费 0。只清理本轮完整路径所属的
测试 App / 服务；核对端口、PID 文件、测试 socket、假 Key 与测试偏好均已清空。
用户 App 未操作。构建、反向与此单场景证据分别保留，不以旧官方生成场景替代。

## 教训 / 防回归

“没有要取的证据”和“取证失败”必须分开。成功 / 失败应根据实际操作和结果，
不能仅根据调用方最初的偏好。长期合同见
[成片疑点检查](../architecture/finished-video-inspection.md)的证据截图说明。
