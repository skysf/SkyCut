# 2026-10-28 停不下来的 upscale 没人再查：成品不进作品库，还占着一个名额

## 症状

收费方案第 6 刀的真积分测试（用户同意，测试版 0.18.50）里，AI 起了一单 ByteDance 1080p 的 upscale（`upscale_clip`）。`POST /jobs` 回 `queued` 之后不到一秒就 `cancel_job`：SkyCut 回「Sky Studio 已经开始了、取消不了、积分花了、成品照样会进作品库」。

Sky Studio 那边查日志：取消在 09:30:56 到达。fal 在 09:30:53–54 已经收下这一单，所以回 409 `not_cancellable`、不退款，这些都对。但从 09:30:58 到 09:45 再没有请求查这一单：

- 任务那一行一直是 `queued`，作品行一直是 `pending`，成品还留在 fal 那边；
- 「成品照样会进作品库」这句话没有兑现；
- 这一单一直占着账号「同时开着的最多 3 个」中的一个，要等 Sky Studio 的巡检兜底（升级画质类 245 分钟）才会收掉。

最后是用户同意后，Sky Studio 用一把临时 Key GET 了一次，这一单才存进作品库、变成 done。

## 根因

Sky Studio 没有长轮询，也不在后台自己去服务商那里收成品。**有人 GET `/jobs/{id}` 时**，服务器才去 fal 取成品、存进作品库、把任务标成 done（接口合同「GET /jobs/{id}」）。

SkyCut 的 `SkyStudioJobRun.stop()` 在取消回 409、或取消请求没送到时，只回一个「停不下来 / 说不准」的结局就结束了，没有人再查这一单。写 #267 时把「成品照样会进作品库」当成了服务器自己会做的事，没去核对「谁来触发这一步」。自检也只钉了停的三种结局分得对不对，没钉停下之后还有没有人去查。

## 修复

`Sources/SrtFlow/SkyStudio/SkyStudioJobRun.swift`：

- `stop()` 在 `not_cancellable` 和「取消没送到」这两种结局下，先把任务号交给 `keepFollowing`，再回结局。
- `keepFollowing` 在**不继承取消的后台任务**里跑 `followToEnd`（调用者这时已经被取消了）。
- `followToEnd` 照 `poll_after_seconds` 一直查到 done / failed / cancelled，不下载、不换源。连着 10 次查不到、等满 5 小时、服务器回了别的错，就交给 Sky Studio 的兜底。
- 自检可以把 `onUnstoppable` 换成只记下任务号的。

排队中取消成功（退钱）的那一单不再查。SkyCut 退出前还没查完的单，只能靠 Sky Studio 的兜底；对方说会把巡检改成替没人查的单收尾。

## 验证

- `scripts/check-sky-studio.sh` 第 7 组（`checks/SkyStudio/JobRunChecks.swift`）：
  - 第 6 节：停的三种结局里，回 409 和取消没送到的那两种把任务号交了出去；排队中取消成功的没交。
  - 第 6b 节：`followToEnd` 查到 done 就停，只发 GET（不下载、不取消），照服务器说的间隔查（15、15、30 秒）；查到 failed 就停；断网两次照查；连着 10 次查不到就算了。
- 反向验证在 CI 上做：先推一个只有自检、`stop()` 里没调 `keepFollowing` 的提交，第 6 节那两条变红，第 6b 节照绿；再推修复，全绿。PR 里有两次运行的链接。
- 真服务器上重测这一单要再花积分，等下一版测试版装上之后，和第 6 刀别的种类一起测：取消 → 回 409 → 过一两分钟，看作品库里是不是已经存好。

## 教训 / 防回归

- 接口合同里「谁触发哪一步」要读清楚：没有长轮询的服务器，「有人查」本身就是流程的一部分。客户端放手之前，要么把它查到底，要么确认服务器自己会收尾。
- 告诉用户「成品照样会进作品库」之前，先确认是谁让这句话成真。长期规矩写在 [Sky Studio 的任务](../architecture/sky-studio-jobs.md)「停」那一行。
