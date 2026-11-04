# 2026-11-04 四条扫描守卫从加上那天起，CI 一次都没跑过

## 症状

查 CI 为什么一轮要 11 分钟时，拿 `scripts/check-all.sh` 的清单和 `checks/` 目录对了一遍：`checks/` 顶层 45 条扫描守卫里，
有 4 条不在 check-all.sh 里，也没有别的检查脚本调它们：

| 守卫 | 加上的时候 | 钉着什么 |
| --- | --- | --- |
| `checks/sky-studio-wiring.sh` | 2026-10-28 | Sky Studio 的地址只在 `SkyStudioAPI`、硬件 UUID 不出本机、后台不弹钥匙串框、照授权拦和任务只走该走的路（324 行，收费方案第 5、6 刀的接线全在这里） |
| `checks/cloud-task-projects.sh` | 2026-10-31 | 生成任务带工程归属，卡片和 MCP 共用分组 |
| `checks/region-framing-wiring.sh` | 2026-11-02 | 源矩形取景接进现有编辑 / 批量和原生渲染 |
| `checks/voiceover-sync-wiring.sh` | 2026-11-02 | 旁白同步复用生产路径、只有一处提交 |

CI 只跑 check-all.sh 列着的检查，所以这四条从加上那天起在 CI 上一次都没跑过。本地跑 `scripts/check-guards.sh` 一直是全绿的。
`sky-studio-wiring.sh` 的文件头、AGENTS.md、[Sky Studio 账号](../architecture/sky-studio-account.md) 都写着它在「check-all 第 1 组」。

这次查到时四条在本地都是绿的，没有藏着的红。可这一个星期里，改到它们钉着的接线，CI 都拦不住。

## 根因

- **加一条守卫要做两件事，漏了第二件什么都不会红。** 一是把脚本放进 `checks/`，二是在 check-all.sh 里加一行 `run_check`。
  `scripts/check-guards.sh` 按通配符跑 `checks/*.sh`，新守卫自己就会被它跑到，推之前看到的是绿的；CI 不认识它，也不会说少了什么。
- **「check-all 照样逐条跑它们」是一句没人钉着的话。** check-guards.sh 的开头这么写，可两个入口一个按通配符找、一个按清单跑，
  对不对得上全靠加守卫的人记得。
- **文档写的是意图，不是查出来的事实。** 「进 check-all 第 1 组」是写的人打算做的事，没人回头去 check-all.sh 里看一眼。

## 修复

- 四条加进 check-all.sh 第 1 组（扫描守卫眼下都在这一组）。
- 新守卫 `checks/check-all-shards.sh`：`checks/` 顶层的每一个 `.sh` 都要在 check-all.sh 某一行 `run_check` 的命令里出现，按词比
  （`checks/x.sh`、`bash checks/x.sh` 都算；注释掉的、只是字符串的一部分的不算）。一条 `run_check` 都没读到、`checks/` 下一条守卫都没找到
  也红（扫空 = 假绿）。它自己也在 `checks/` 下，所以也进了 check-all。可以给它一份 check-all.sh 的副本做反向验证。
- 要故意不进 CI 的检查（要图形会话、要真钥匙串）照旧写成 `scripts/check-*.sh`：`check-cover-preview-attach.sh`、`check-keychain.sh`、
  `check-workbench-toolbar.sh` 这几个就是，文件头都写明了为什么。守卫只管 `checks/` 顶层。
- check-guards.sh 的注释改成指向这条守卫；长期规矩写进 [构建与打包「CI」一节](../build/build-and-packaging.md)。

## 验证

- 修之前跑新守卫：红，点名的正好是这四条加上它自己，退出码 1。
- 修之后绿：`checks/ 下 46 条守卫都在 check-all 里`。
- 反向验证（拿 check-all.sh 的副本给它）：删掉 sky-studio-wiring 那一行 → 红；把那一行注释掉 → 红；
  路径只作为别的词的一部分出现（`checks/sky-studio-wiring.sh.bak`）→ 红；副本里一条 `run_check` 都没有 → 红。退出码都是 1。
- 四条守卫和新守卫用 `/bin/bash`（check-all 用的那个 3.2）各跑一遍：都绿。新守卫过了仓库自己的几条 shell 守卫
  （变量边界、管道接 `grep -q`、花括号展开、吞构建输出、文件行数）。
- 这个 PR 的 CI 第 1 组日志里，五条都出现在 `✓` 行里。

## 教训 / 防回归

- **「按通配符找」和「按清单跑」是两个入口时，清单一定会漏。** 要么两边共用一份清单，要么钉一条守卫比两边。
- **文档里写「在第 N 组」之前，去 check-all.sh 里看一眼。** 分组只以 check-all.sh 为准。
- 长期规矩：`checks/` 顶层的守卫都要进 check-all，见 [构建与打包「CI」一节](../build/build-and-packaging.md)。
