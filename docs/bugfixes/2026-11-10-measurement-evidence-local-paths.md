# 2026-11-10 实测证据里漏了本机路径（带着账户名）

## 症状

MCP 按需说明的基线实测出证据 JSON 时，`scripts/gui-smoke/client-measure/report.py` 说「路径换成 `$RUN`，不含用户的工程或 Key」，
可出来的那一份里还剩 5 处本机的绝对路径：`/private/tmp/claude-<uid>/-Users-<账户名>-…/measure-runs/baseline-7a9d8c9/7-cover/work…`
（任务 7 旧题的终端命令和工具参数里）和 `/tmp/claude-<uid>/.../work/SkyCut/Projects/Review.skycut`（任务 1 的最后那段话里）。
临时目录的名字里带着用户的账户名。提交前手查（grep 临时目录和 `/Users/`）才发现，手补之后才进的仓库（#354）；试点那一份同样漏 1 处。
写这个案例时又发现：#354 把开发时留在草稿目录里的两份调用表（`fixture-calls.json`、`fixture-close.json`）一起拷进了 `scripts/gui-smoke/client-measure/`，
里面写着同样的本机路径；脚本根本不用它们（`make_fixture.sh` 自己在临时目录里写调用表）。

## 根因

`scrub` 只把**这个任务的目录**原样换成 `$RUN`（`/private/tmp/…` 和 `/tmp/…` 两种写法）。有两种路径对不上这个前缀：

1. **跑完改过名的目录**：任务 7 换题时，旧题那一场是在 `…/7-cover/` 里跑的，跑完改名成 `7-cover-v1`；出证据时按新名字换，会话记录里的旧名字原样留下。
2. **模型自己写短的路径**：模型在最后那段话里把路径写成 `/tmp/claude-<uid>/.../work/SkyCut/Projects/Review.skycut`，中间是三个点，任何前缀都对不上。

家目录（`/Users/<账户名>`）也从没换过；这一轮碰巧没出现。

## 修复

- `report.py` 的 `scrub`：先照旧换这个任务的目录；再把**凡是指到某个 `work` 目录的临时路径**（`/private/tmp`、`/tmp`、`/var/folders` 开头）都换成 `$RUN/work`；
  家目录换成 `~`；还剩绝对路径就在 stderr 打一行提醒（`warning: <任务>: path left in the evidence: …`），人再看一眼。
- 删掉那两份没人用的调用表。
- 新扫描守卫 `checks/report-evidence-no-local-paths.sh`（`check-all` 第 5 组）：`docs/reports/*.json` 和 `scripts/gui-smoke/client-measure/*.json` 里
  不许有 `/private/tmp`、`/tmp`、`/var/folders`、`/Users/<名字>` 开头的路径，有就列出来、红。漏网的进不了仓库。
- 长期约束写进 [GUI 冒烟流程](../testing/gui-smoke-testing.md)「四之十」第 6 步（实测脚本的规矩都在那一节）。

## 验证

- 新的 `report.py` 重出基线和试点两份证据：stderr 没有提醒，结果和手补过的那两份**逐项相同**（`json` 比对相等）。
- 反向验证：
  - 旧的 `report.py`（main `ec1d37e` 那一版）出同样两轮：基线剩 5 处、试点剩 1 处本机路径；
  - 把没补过的基线证据放回 `docs/reports/`：守卫红，列出 5 个不同的路径；恢复后绿。
  - 把删掉的两份调用表放回去：守卫红，两个文件各列出一个路径；删掉后绿。
- 三份现有的证据（11-03、基线、试点）和 `tasks.json` 守卫都绿。

## 教训 / 防回归

- 「换掉某个前缀」挡不住改过名的目录和模型写短的路径：要按**形状**换（指到 `work` 的临时路径、家目录），换完再扫一遍剩下的绝对路径。
- 进仓库的证据是从会话记录里抽的，会话记录里什么都可能有：守卫扫的是**进仓库的文件**，不靠出证据的脚本自觉。
- 把草稿目录里的脚本整个拷进仓库之前，逐个看一遍有哪些文件、脚本用不用它们：开发时手跑的一次性数据不该跟进来。
