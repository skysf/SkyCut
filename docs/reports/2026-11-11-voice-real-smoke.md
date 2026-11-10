# 声音功能的真实冒烟：界面那一半（2026-11-11）

> 用户 2026-11-11 01:05 授权真实冒烟、总预算 USD 10（原价），协调者照 `impl-briefs/T2-real-smoke.md` 派的活。**花了 40 积分（USD 0.16）**。
> 范围中途改过：测试账号是 SkyCut 免费套餐，AI 工具全被照授权拦下；改生产库里账号的套餐被安全规则挡住、要等用户早上点头，所以今晚只走
> **App 里的界面**（进程内 GUI 冒烟驱动隔离测试 App），只能经 AI 工具的那几项记成「等用户开 AI 开关」，没有绕。

## 一、怎么测的

- **隔离测试 App**：bundle id `com.srtflow.SrtFlow.t2real.skystudiosmoke`，从 main（fb49bf5：声音 PR 3–9、App Nap #371、声音库审查 #375）加本 PR 的冒烟步骤打的。
  没碰正式版、测试版、用户的钥匙串和工程；步骤表、结果、截图、素材全在 `/private/tmp`，跑完删了。
- **真 Sky Studio + 测试账号**：TestTeam 成员 `E2E_TEAM_MEMBER`，SkyCut 免费套餐（`features.mcp: false`），起手余额 1,182.3。临时 Key 照 V 的 `--login` 那一套建：
  只放进测试 App 的进程环境，App 拿真的 `/me` 验过再存进它**自己的**钥匙串条目；冒烟 App 的 Key 钩子只认回环地址，所以 App 连本机一个只转发的小进程
  （原样转给 Sky Studio 的 `/api/skycut`，走系统代理；日志只记方法、路径、状态和对账要用的正文，不记任何头、网址去掉签名参数）。脚手架在仓库外的
  `SkyVoiceForClone/skycut-real-smoke/`（建 / 撤 Key、转发、打包、跑步骤表、记账、只读对账）。
- **怎么点界面**：[GUI 冒烟流程](../testing/gui-smoke-testing.md)「四之六」的进程内驱动，加了 `voice` 一步（第 19 条）：按钮背后是 NSButton、输入框要 key 窗口、
  「选择文件…」是系统面板，这几样由 `voice` 让那一节 / 那张 sheet 调按钮自己调的那个函数、往 sheet 自己的模型里填字；变声面板走片段右键那个入口。
  截图是 App 自己画的（这个终端没有录屏权限，第 21 条）。
- **每一单之前**记一行「已花 + 这次最坏」（上限 2,500 积分），测试 App 自己的每日额度设成 300 积分兜底；钱对三处：SkyCut 记的、Sky Studio 的任务行和余额、
  fal 的 billing-events（按 request_id）。

**免费套餐只关 AI 工具（先确认的那一条）**：代码里套餐只在两处判 —— `AIToolRouter` 里 AI 的调用（`SkyStudioAccount.aiRefusal`）和导出水印；声音库、设计、
变声的界面不看套餐，Sky Studio 的合同也写着「每个套餐都能花积分」。实测免费套餐下声音库照常取到、建 / 设计 / 变声 / 删都成了（下面）。

## 二、逐项结果

| # | 项目 | 跑了没有 | 结果 |
| --- | --- | --- | --- |
| 1 | 设置 → 剪辑与声音 → 新建声音（授权那一勾） | 跑了两次 | ✅ 选文件后参考录音和语言自动出来（中文 29.95 秒、有效人声 22.98 秒；英文 29.08 秒、20.50 秒，语言各自认对）；没勾授权时「新建」灰着、写「勾上那一句确认你能用这个声音」；勾上就亮。按下：`/uploads`（`voice_reference`、`audio/wav`）→ PUT → **一次** `POST /voices` 201，带 `consent: true`、`consent_statement_version: voice-consent-v1`、语言、用了哪一段、文件名、`idempotency_key`；新声音马上出现在列表里 |
| 2 | 设计声音一次（Qwen3 短描述） | 跑了 | ✅ 报价 22.5（`exact`；服务器按英文描述选 `qwen3-voice-design`，备用 MiniMax 752.8 不自动换）；按「设计」**一次** `POST /jobs`（`max_credits` 22.5）→ 25 秒做完、有样音，列表里出现「Designed · English」。⚠️ 报价那一行写成「Designed with Sky Studio · 22.5 credits」，没写 Qwen3 → 另开 PR #379 修（`docs/bugfixes/2026-11-11-design-quote-model-name.md`） |
| 3 | 删声音 | 跑了三次 | ✅ 点垃圾桶弹「删除『X』？」、按删除 → `DELETE /voices/{id}` 200，立刻从列表消失；跑完库里这个账号 0 个声音、0 段参考录音、0 个有效的长期授权 |
| 4 | 片段右键「换成我的声音」10 秒 | 跑了 | ✅ 见下一节 |
| 5 | `add_voiceover` 多批、繁体、长句 | **没跑** | 只能经 AI 工具：等用户开测试账号的 AI 开关 |
| 6 | 全部权限的长期授权（声音 PR 7） | **没跑** | 是 AI 权限模式的事、效果要经 AI 工具看：同上，等 AI 开关 |
| 7 | 不在前台时不降速（#371） | 没观察 | 这次是界面起的任务、测试 App 的窗口一直开着，没造出 App Nap 的条件；#371 用隐藏的测试 App 量过 |

### 变声（第 4 项）

- 素材：一段 10.00 秒的视频放在 V1（`dub-test-10s.mp4`：macOS 的 Samantha 读一句英文 + 合成的和弦铺底，单独做的，不是谁的声音）。
- 面板：默认选中「我的声音」里唯一那个（第 1 项建的中文声音），检测出这段说的是英语，写了一句「这段是英语，这个声音没有英语的录音，用它别的录音、可能没那么像」；
  报价 17.5（`exact`），按钮「Change Voice (up to 17.5 credits)」。
- 按「开始」：`/uploads`（`voice_convert_source`，960,044 字节 = 10 秒单声道 WAV）→ **一次** `POST /jobs`（`max_credits` 17.5）→ 81 秒做完，`chatterbox-hd`，`fallback_used: false`。
- 落地：**两条新音频轨**（A1 新的人声、A2 背景），两段都在 0.000–10.000，**和原段一样长**；**原段静音、没删**；三段在同一个链接组；提示条
  「Changed to the voice “T2 UI Voice”. The original sound is muted; press ⌘Z to undo.」。
- 两个文件都是 10.00 秒（48 kHz 单声道）：新的人声平均 −16.7 dB（原来的人声 −16.4 dB）、峰值 −0.1 dBFS；背景平均 −27.6 dB（原来的铺底 −24.4 dB）。
- **一步撤销**：撤一下回到只有 V1 一段、没静音、没有音频轨。
- 像不像没人听（夜里没有耳朵）；文件是用户声音克隆出来的，跑完删了。

## 三、每一单的实收

| 单 | Sky Studio 任务 | 报价 | SkyCut 记的 | Sky Studio 扣的 | fal 实收（billing-events，按 request_id） |
| --- | --- | --- | --- | --- | --- |
| 设计（Qwen3） | `069a06fc…`，`qwen3-voice-design`，done | 22.5 | 22.5 | 22.5，没有退款 | USD 0.09（1 个千字，和预期一样） |
| 变声（10 秒） | `18860935…`，`chatterbox-hd`，done | 17.5 | 17.5 | 17.5，没有退款 | 分离 USD 0.05（1 块）+ 变声 USD 0.02（1 分钟），和预期一样 |

- **合计 40 积分 = USD 0.16（原价）**；测试账号余额 1,182.3 → 1,142.3，正好少 40。新建 ×2、删除 ×3、几次报价不花钱。
- 这次没有 Gemini 的调用（没配旁白），Vertex 那边没有要对的。

## 四、Key 和清理

- 一共建过 8 把临时 Key（`E2E_TEAM_MEMBER` 6 把；第 6 对 2 把，只问了一次 `/me` 看套餐），全部撤销、从 `keys.list` 读回来是 `revoked`，测试账号现在 0 把有效的。
  每把只活了 0.4–18.5 分钟（每重打一次测试 App，新的签名读不到旧的钥匙串条目，就换一把）。
- 测试建的 3 个声音都删了（库里 0 个声音、0 段参考录音、0 个有效授权）。
- 测试 App 的钥匙串条目、偏好、支持文件夹删了；`/private/tmp` 里的素材（用户录音的拷贝）、变声出来的文件、截图原件、fal 的对账导出（里面有别人的行）都删了。

## 五、发现

1. **SkyCut：设计的报价说不出用哪家**（第 2 项）。声音的报价顶层没有 `model`，用哪个只在 `voice_plan.selection.model`，SkyCut 只读顶层；两份假服务都补了顶层的
   `model`，回归和 PR 8 的离屏渲染一直是绿的。修在 #379（`docs/bugfixes/2026-11-11-design-quote-model-name.md`，带反向验证），免费冒烟的假服务一起改成真回答的形状。
2. **冒烟本身的三个坑**（写进了 [GUI 冒烟流程](../testing/gui-smoke-testing.md)第 20–22 条）：步骤表放在「下载」底下，新签名的测试 App 读它就卡在等授权；
   终端没有录屏权限时截图一张等 15 秒、全失败（改成 App 自己画）；后台起的 App 里 sheet 收起之后 `onDisappear` 不一定跑（判收没收起看窗口挂不挂着 sheet）。
   最后这条在产品里的影响很小：新建声音的对话框在 `onDisappear` 里删临时的参考录音，没删的会在下次启动时被清掉一天以前的那一批。
3. 没有发现 Sky Studio 的问题：报价、任务、扣费、退款、删除、授权记录都和合同、和 fal 的账单对得上。

## 六、没测的，等什么

- **等用户开测试账号的 AI 开关**（`skycut_entitlements.feature_overrides.mcp` 或者开 Pro，语句在 `impl-briefs/status/T2-real-smoke.md`）：
  `add_voiceover` 用声音库的声音读多批的中英混合稿、繁体中文旁白（合批后切句、zh_TW 转写）、超过一批上限的长句、全部权限的长期授权（打开时的说明、
  建声音不再问、删了提示条有一句话）。开了以后 `skycut-real-smoke/drive.py` 的几步照 T2 的说明接着跑，估计不到 200 积分。
- Qwen3 用 1,100 字左右的描述核「每开始 1,000 字」计价（45 积分）：这次协调者定只设计一次短描述，没做。
- 变声出来的声音像不像、口型对不对：要人听。

## 七、截图（App 自己画的）

| 新建声音，还没勾授权（「新建」灰着） | 设计声音的报价（修之前写成 Sky Studio） |
| --- | --- |
| ![新建声音](2026-11-11-voice-real-smoke/new-voice-consent-unchecked.png) | ![设计报价](2026-11-11-voice-real-smoke/design-quote.png) |

| 声音库（建好、设计好之后） | 变声面板 |
| --- | --- |
| ![声音库](2026-11-11-voice-real-smoke/voice-library.png) | ![变声面板](2026-11-11-voice-real-smoke/change-voice-panel.png) |

变声落地之后的时间线（原段静音、两条新轨、提示条；预览是黑的，因为 App 自己画不出播放器的图层）：

![变声之后](2026-11-11-voice-real-smoke/change-voice-timeline.png)
