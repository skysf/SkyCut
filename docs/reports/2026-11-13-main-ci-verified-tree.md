# 2026-11-13 合并后 main 上那一轮：树已经验过就不再跑检查

> 管什么：为什么合并之后 main 上那一轮可以在「树已经验过」时只编译、存缓存；量了什么、怎么量的；几种做法比下来怎样；GitHub 上当场试出来的行为。
> 不管什么：现行的规矩、怎么关、上线后看哪几个数、怎么对账（[构建与打包](../build/build-and-packaging.md)「CI」一节「合并之后 main 上那一轮」）；
> 守卫的细目（[检查细目](../testing/check-catalog.md)）。
> 数据截至 2026-11-13 07:21 UTC（PR #416 合并）。用户同一天定了四件：做这件事（下面的 A1）；记号认 24 小时；短轮里第 2–5 组的编译缓存不刷新、
> 上线后看数；发版说的「已通过 CI 的 main」= main 上那一轮绿就算（短轮时摘要里写着是哪一轮 PR 验的），不加「发版前必须完整跑一轮」。

「树」= 一个提交里全部文件的内容：两个提交的树一样，就是每个文件一字不差。

## 一、main 上那一轮比 PR 那一轮多做的

两轮跑的是同一个 `checks.yml`、同样的步骤。main 上那一轮独有的作用：

1. **存 `.build` 缓存**。GitHub 的缓存按分支隔开，PR 那一轮存的「can only be restored by re-runs of the pull request. It cannot be restored by
   the base branch or other pull requests targeting that base branch」（[Dependency caching](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)
   「Restrictions for accessing a cache」）。要让下一个 PR 用上，只能在 main 上存。11-13 仓库里的 207 份缓存全挂在 main 上；一次合并存 5 份，约 255 MiB。
2. **验真正合出来的那棵树**。ruleset `protect-main` 的 `strict_required_status_checks_policy` 是 false，PR 不用跟上最新的 main 就能合。
3. 顺带的：同一棵树多跑一遍；改了 `scripts/vendor-ffmpeg.sh` 之后把新的 ffmpeg 存成大家取得到的那一份（短轮里第 1 组照样做这一步）。

PR 那一轮检出的是 GitHub 替它合的提交，不是 PR 的头（[Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)：
`pull_request` 的 `GITHUB_SHA` 是「Last merge commit on the GITHUB_REF branch」，`GITHUB_REF` 是 `refs/pull/N/merge`）。
运行记录接口里的 `head_sha` 是头，所以测的是哪棵树只有日志里 `actions/checkout` 那一行说得出：`HEAD is now at … Merge <头> into <当时的 main>`。
重跑用原来那个提交（[Re-running workflows and jobs](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs)：
「The workflow will also use the same GITHUB_SHA … and GITHUB_REF … of the original event」）。

## 二、多少次合并是「一模一样的树」

**量法**：对每个合进 main 的 PR，取 `checks.yml` 里事件 `pull_request`、头提交 = PR 最终的头、结论 success 的最新一轮；从它的日志读检出的那个合并提交，
`GET /repos/{repo}/git/commits/{sha}` 取它的树，和真正的合并提交的树比。交叉核对：本地 `git merge-tree --write-tree <当时的 main> <头>` 重算，358 / 358 和 GitHub 的一样。

| 时段 | 合并 | 还原出来 | 树一模一样 | 其中改代码的 | 其中只改文档的 |
| --- | ---: | ---: | --- | --- | --- |
| 全部（08-16 到 11-13） | 390 | 358 | **308（86.0%）** | 305 里 263（86.2%） | 53 里 45 |
| 08-16 到 09-23 | 63 | 31 | 31（100%） | 30 里 30 | 1 里 1 |
| 09-24 到 11-04 18:00 | 223 | 223 | 200（89.7%） | 196 里 177（90.3%） | 27 里 23 |
| 11-04 18:00 到 11-13（快速通道和缓存都修好之后） | 104 | 104 | **77（74.0%）** | 79 里 56（70.9%） | 25 里 21 |

- 一件一件顺着做的日子是 100%；几个会话并行的 11-10（那天合了 39 个）是 56%，11-11 是 58%。
- 树不一样的 50 次：测的那一刻的 main 比合并时落后 1 个合并的 32 次，2 个 9 次，3 个 7 次，4 个、7 个各 1 次。
- 还原不了的 32 个没算进比例：#1–#20 那时还没有 CI；#21–#32 的日志过了 90 天（下载回 410）。
- 比的是树，不是「main 动没动」：7 个 PR 测的那一刻的 main 不是合并时的，树照样一样（分支里已经带着后来那些改动）。

## 三、main 上那一轮抓到过什么

到 11-13 一共 369 轮，有过红的 24 轮：

| 是什么 | 轮数 | 其中树一模一样的 |
| --- | ---: | ---: |
| GitHub 没分到 macOS runner（「The job was not acquired by Runner of type hosted even after multiple attempts」） | 12 | 11 |
| 扫描守卫假红：pipefail 下管道末端的 `grep -q`（09-23 修了） | 3 | 3 |
| 性能 ratchet 的内存峰值超 10%（[已知的偶发](../architecture/preview-perf-ratchet.md)） | 2 | 1 |
| 别的检查偶发失败或卡住：audio-fade、看门狗 Bus error、第 2 组 30 分钟超时、upscale「Cannot Decode」、region-framing 超时、player-clock、still-clip-encode 的耗时断言 | 7 | 7 |

- 「PR 没跟上 main、合出来才坏」的真问题：**0 次**。树不一样的 50 次合并，main 上那一轮 48 次绿，红的 2 次也在上表里（ratchet 的内存峰值、没分到 runner）。
- 树一模一样还红的 22 次，按定义只能是环境或检查自己不确定：11 次没分到 runner，11 次是同一棵树第二遍撞出的不稳定检查。
  后者是 main 上那一轮真正起过的作用（其中 pipefail 的 `grep -q`、看门狗、region-framing、player-clock、still-clip-encode 后来各自修了；
  是不是因为 main 上红了才去修的，只核对了时间先后），以后要等下一个 PR 撞上。

## 四、时间账

**一轮里各占多少**（11-04 18:00 之后、5 组都绿的 main 完整轮，中位数）：第 1 组整个 job 448 秒，其中编 App 34 秒、跑检查 168 秒、性能 ratchet 184 秒、
取 + 存缓存 14 秒；第 2–5 组 327 秒，其中跑检查 304 秒（含编核心库和自检二进制，计时分不开）。短轮的第 1 组 = 去掉跑检查、ratchet、上传三步，
按这 55 轮的实际耗时算中位 62 秒（p90 96，最长 167）；其余四组各约 12 秒。

**编 App 要多久，看缓存差了多少**（208 个第 1 组 job：从日志读它取的是哪个提交的缓存，数那份缓存和这次编的树之间差几个 `Sources/**.swift`）：
差 0 个中位 15 秒；1–10 个 35–40 秒；11–20 个 48 秒；21–40 个 60 秒；41–80 个 91 秒（只有 5 个样本）；冷编约 2 分 10 秒到 2 分 45 秒（构建与打包里的数）。

**排队重放**：把 11-04 18:00 到 11-13 的 1,341 个 macOS job 按真实的建出时间和耗时放进「5 台、先到先得」重排，再把会跳过的 main 轮换成短的。
理想的 5 台对不上慢的那一截：等了 60 秒以上的 job，45% 的等待时间里本仓库在跑的不到 5 个，是 GitHub 那边 macOS 机器不够。所以给两个口径：
**下限**（理想的 5 台）和**校准**（每台用完再等 60 秒，整体分布对上实测：改代码的 PR 平均 12.6 对实测 13.1 分钟，p90 23.6 对 22.7）。
校准只对上了整体分布，单轮的误差平均 4 分多钟，只拿来比做法。没算「结果早出来以后，下一次推送、合并跟着提前」。

| 改代码的 PR 那一轮，从建出来到最后一组跑完（122 轮） | 现在 | A1（采用） | A2 | 一轮 main 都不跑（上限） |
| --- | --- | --- | --- | --- |
| 下限口径：平均 / p90（分钟） | 9.8 / 16.4 | 8.8 / 12.3 | 8.9 / 12.4 | 8.5 / 12.2 |
| 校准口径：平均 / p90（分钟） | 12.6 / 23.6 | 10.0 / 15.6 | 10.0 / 15.7 | 9.1 / 13.8 |
| macOS runner 总用时（台·分钟） | 6,050 | 4,514（−25%） | 4,484（−26%） | 3,689（−39%） |

按天：11-10（67 轮）平均 11.3 → 9.7（下限）/ 15.7 → 11.6（校准），那天实测平均 17.1；11-11 9.7 → 9.0 / 12.0 → 10.1；
一件一件做的 11-05 到 11-07、11-13 不变（6.4–7.8）：下一个 PR 推上来时，main 那一轮本来就跑完了。

## 五、几种做法

- **A1（采用）**：PR 全绿留记号；main 上那一轮树一样就只让第 1 组编译、存缓存，其余四组十几秒结束；查不到一律照常全跑。不少验任何一棵树。
  第 1 组的缓存和现在一样新，而且合并后约 1 分钟就存好。第 2–5 组的缓存只在完整的轮里刷新：它们不在最慢的那条线上（327 对 448 秒）。
- **A2（整轮不跑）**：省的和 A1 几乎一样，但缓存只在完整的轮里刷新。重放下来，PR 编 App 时和缓存差的源文件数从中位 7 个（p90 25）变成 22 个（p90 59），
  45% 的 PR 轮变慢、平均多 14 秒（p90 43 秒），都落在最慢的第 1 组上；顺着做的日子缓存一天不刷新，越攒越旧。没采用。
- **B（合并前必须跟上 main，main 上不再跑）**：保证变强，但树不一样的那些合并，每个都要先合 main、再等一轮 PR 的 CI：11-04 到 11-13 至少多 27 轮
  （23 轮完整 + 4 轮只改文档），main 每动一次就跟一次是 37 轮；会话在合并前每次多等至少 7.5 分钟。缓存还是要另想办法。
  历史上 50 次没验过的合并一次真问题都没出过。没采用。
- **C（合并队列）**：用不了。仓库是个人账号的，合并队列只给组织的仓库（[GitHub 2023-07-12 的公告](https://github.blog/changelog/2023-07-12-pull-request-merge-queue-is-now-generally-available/)：
  「Merge queue is available on private and public repos on the GitHub Enterprise Cloud plan and all public repos owned by organizations」）。
- **D（不动）**：11-04 到 11-13 有 56 轮完整的 main 轮是同一棵树的第二遍。

## 六、GitHub 上当场试出来的

都在用后就删的孤立测试分支上做，workflow 只用 ubuntu，没占 macOS runner；分支、运行、临时变量做完都删了。

| 情形 | 应该 | 结果 |
| --- | --- | --- |
| #418：绿了就合；合之前把那一轮重跑过一次 | 认 | 合并后那一轮认出记号（`verified by run …`），检查那一步没跑；重跑检出的是同一个提交，同名的记号被盖掉、没报重名 |
| #419：测的时候基线还没动，#418 合进去之后直接合 | 不认 | `no marker for tree …`，照常全跑 |
| #420：基线动了以后关掉再打开（按最新的基线重测了一轮），再合 | 认 | 被新那一轮认下 |
| #421：那一轮留了记号之后才红 | 不认 | `run … ended failure`，照常全跑 |
| #422：自己那一轮不留记号，另一个 workflow 上传了同名的 artifact（树、头提交、仓库、事件、结论全对） | 不认 | `run … is .github/workflows/x4-forger.yml, not …`，照常全跑 |
| 重跑时仓库变量读哪个值：第一次跑时临时变量是 `before`，改成 `after` 再重跑 | — | 第一次读到 `before`，重跑读到 `after`，两次检出的提交一样。所以「关掉开关再重跑」能让那一轮完整跑 |

- token 只给 `contents: read`、`actions: read` 就够：列 artifact、读运行记录都成功。
- 合并得很快时记录来得及：#418 在汇总 job 结束后 9 秒合并，main 上那一轮去查时那一轮已经是 completed。历史上只有 1 次（#224）是在那一轮记录更新后
  12 秒之内合的；更紧的没试到，所以判断里留了最多 30 秒的等待，等不到照常全跑。
- 没法在 GitHub 上造的情形（接口出错、记号过期、超过 24 小时、fork、别的头提交等）放进了守卫：假的 `gh` 逐条答，见[检查细目](../testing/check-catalog.md)。
- 反向验证：在 workflow 和判断脚本上逐处改坏 39 种（跑检查的步骤不看判断、写成 `== 'true'`、判断那一步删掉 / 挪后 / 写死 true / 加 if / 没给 token、
  编 App 被跳过、存缓存被跳过、记号留在「分组全过」之前、main 上也留、留 7 天、留记号能把 check-all 弄红、记号按提交起名、判断脚本的 17 个条件各撤一个），
  `checks/ci-verified-tree.sh` 每一种都红，没改坏时绿。
