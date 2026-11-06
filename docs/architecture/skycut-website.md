# SkyCut 官网

## 范围与设计

2026-11-04 用户定稿：域名 `skycut.app`，Vercel Pro；C 版暖白 / 森林绿。
英文、简体中文、德文、西班牙文，与个人站相同。主文案短，桌面左右排、iPad 上下排、
手机简化三维场景；不是把桌面截图缩小。首页、文档、隐私页均生成静态 HTML。

代码位于 `website/`，与 Mac App 的 Swift 构建分开。Vite 仅打包本地依赖；Three.js
动态加载，WebGL 不可用、减少动态效果时使用 CSS 静态时间线。GSAP 只增强滚动，不把
必要内容先藏起来。字体 Outfit 随站点提供；影片素材来自《南极》及用户点名的本机视频。

2026-11-04 用户精简：移除“更新”页及桌面导航、手机菜单、页脚中的入口，
不再生成对应 HTML 或 sitemap 条目。首页四语言可见文案不用句读标点，
中文缩短为简洁短语；字标移除末尾圆点。邮件地址、系统版本和时间码保留必要符号。
官网页面不展示 GitHub 或源码信息，不对外链接代码仓库和内部技术文档。

2026-11-05 用户确定：浏览器图标复用 SkyCut 软件本身的正式图标，不另设绿色字母标志。
`npm run build:favicons` 调用仓库现有 `scripts/make-icon.swift`，沿用
`packaging/icon-source-1024.png` 与同一份透明边缘处理，输出 16 / 32 / 64 的 ICO、
32 / 64 PNG 和 180 Apple touch icon；不改原图、不另写抠图实现。重建需要 macOS / Swift，
正常网站构建只复制已生成资源，Linux CI 不重建图标。

## 设备语言与手动选择

2026-11-05 用户确定：打开 `https://skycut.app/` 时按设备 / 浏览器的第一首选语言进入
对应版本，超过已有翻译范围统一默认英文。实现只读浏览器语言，不按 IP 推测、不新增
云端函数或浏览器设置修改。

- `src/language.js` 使用 `navigator.languages[0]`，列表缺失或为空时用
  `navigator.language`。`zh` 的地区与字形变体（包括繁体系统）统一进入现有简体中文；
  `en` / `de` / `es` 匹配各自地区变体。其他首选语言直接英文，不跳去第二首选的德文等。
- 根入口优先级为显式 `?lang=` → 本机保存的手动选择 → 设备首选语言 → 英文。
  手动选择只写既有 `SrtFlow.website.language` 本地存储键；禁用存储也不阻止浏览。
  `?lang=` 的有效选择会保存并从网址移除，保留文档路径、其他查询参数与锚点。
- `/en/`、`/zh/`、`/de/`、`/es/` 等明确语言的网址保持稳定，供分享、搜索收录和手动
  切换；不能在打开这些网址时再强制按设备切走，造成跳转循环或让搜索引擎看不到其他版本。
- `tests/language.test.mjs` 调用实际 `applyLanguage()`，覆盖首页重定向、全部中文设备
  变体、不支持的首选语言、缺失语言列表、手动偏好、存储失败和深链接稳定性。
  人工回归：全新浏览器打开根域名应匹配首选语言，手动换语言后回根域名仍保留所选版本。

浏览器语言顺序与空列表回退依据 [MDN Navigator.languages](https://developer.mozilla.org/en-US/docs/Web/API/Navigator/languages)；
明确语言 URL 不互相自动跳转依据 [Google 多语言站点说明](https://developers.google.com/search/docs/specialty/international/managing-multi-regional-sites)。

## 首屏时间线动画

- 2026-11-04 用户要求：更接近参考图的暖白底座、绿色圆角边框与前后叠放卡片；
  底部自动播放，播到哪段就把那张画面卡片平滑移到最前播放；整组自动旋转 360°，
  卡片背面透光，不能出现不透明的空白背板。
- 卡片水平边与底座共用 X 轴，卡片自身的旋转保持为零；换位只改变位置和缩放，
  不额外加侧倾或偏航。360° 转台使用共同的父级旋转基准，避免卡片和底座各歪一个角度。
- `scene-playback.js` 是片段顺序与时长的唯一来源：船、企鹅幼崽、鲸鱼各 5 秒，
  第四段使用用户指定的 `AI_Video_SouthPole/Shot_企鹅.mp4`，完整保留 10 秒原速画面，
  合计 25 秒循环。底部片段宽度与高亮框按实际时长计算。实际视频 `currentTime`
  同时决定当前画面、卡片顺序、播放头和时间码，
  不用两个计时器模拟同步。独立的转台每 48 秒转一圈，不随视频循环重置方向。
- 只建一个静音、内联、循环的视频解码器，将同一个 `VideoTexture` 接给当前卡片；
  其他卡片用各自静态缩略图。正面写深度以保持正确遮挡，背面有同一画面的半透明材质，
  边框是中空几何，不用整块实心背板挡住后面的卡片。手机保留两张可见卡片并继续轮换。
- 暂停按钮同时停止播放与转台；滚出视口、页面隐藏、WebGL 丢失时停止视频和动画帧；
  恢复时继续原进度。系统减少动态效果使用静态回退。销毁时释放视频、纹理与几何，
  手机/桌面切换时复用同一个视频，不能偷偷再开解码器。
- 前三段素材沿用用户已公开的《南极》短片，第四段以用户提供的企鹅视频替换篝火。
  随站点提供轻量的 640 × 360 / 20 fps H.264 静音循环与四张 JPEG，
  不在首屏下载整部影片。重建命令是在 `website/` 执行
  `npm run build:scene-media -- /path/to/antarctica-720p.mp4 /path/to/Shot_企鹅.mp4`，
  需要本机 ffmpeg / ffprobe。源片段时间写在 `SCENE_CLIPS`，原片短镜头去掉底部
  烧录字幕并放慢到 5 秒；新企鹅视频不裁画幅、不改速度，只移除音轨。脚本
  验证循环总长与无音轨后才替换资源。此命令不联网、不部署。

## AI 功能演示

2026-11-05：原来的“精细调整 / 开口就好”两卡替换为三段独立流程，每段桌面左边是
AI 对话、右边是 SkyCut 编辑器。窗口参照用户截图的工具栏、素材栏、预览、检查器、
播放条与多轨时间线重建，统一米白与森林绿，不照搬深色窗口。

- 创作：构思 → 剧本 → 探险者角色 → 三个镜头 → 自动剪辑。素材来自用户指定的
  `AI_Video_SouthPole`，使用破冰船、企鹅幼崽、鲸鱼各 5 秒，组成 15 秒静音演示。
  角色示意使用同目录人物镜头，剧本与南极场景对应。
- 画质提升：同目录 `Shot对着镜头南极洲气温.mp4` 是真实 1280 × 720 原片，
  `_1920x1080_topaz-precision.mp4` 是已有 1920 × 1080 版本，均为 24 fps。
  演示检查、增强进度、换回时间线，直接使用这两个版本，不调用新的付费增强。
- 字幕：按用户点名使用完整 10 秒 `Shot_Speak1.mp4`。原声是英文，已用本机 SkyCut
  转写核对，并参照目录里的成片中英字幕。英文、法语、日语、德语、西班牙语、简中、
  繁中共七种自动轮换，也能手动选择。字幕演示语言与官网四种界面语言分别管理。
  原文与当前译文只有两条字幕轨，四句文字按真实说话时间摆放，画面字幕、轨道文字
  和语言按钮同步，语句之间的停顿不残留上一句。
- 这些是明确标注“交互演示”的本机动画，不是真实 AI 会话或远程生成任务。
  网站不会控制用户打开的 SkyCut 工程，也不上传示例视频。
- `showcase-state.js` 管时序，`showcase-view.js` 管文字与轨道，`showcase-media.js`
  管本地视频。`showcases.js` 使用 Three.js 的 CSS3DRenderer，保留 HTML 的清晰文字
  和键盘按钮。桌面使用透视与独立深度传递，窗口无额外侧倾；iPad / 手机采用自然文档流保持文字与按钮的正确位置，流程和视频动画相同。
- iPad 上下排列，手机进一步收起素材栏和检查器，保留预览、主轨、字幕与一条声音轨，
  不能把整张桌面截图缩小。暂停、重播、点击步骤定位都同时控制视频、播放头和流程。
  三个演示共用一个动画时钟，只播放视口内的段落，切后台立即暂停。减少动态效果默认
  显示完成状态并停播，静态 HTML 保留文案、海报和流程。
- **视频播放口径（2026-11-05）**：视口内主动设置 `preload=auto` 并 `load()`，不能
  对 `preload=none` 的视频只等 metadata。三个演示从首个可见阶段自然循环，点击步骤
  定位后继续播放，完成状态不停在末帧。视频自己的 `currentTime` 驱动播放头、时间码
  和字幕；流程进度不能冒充播放进度，RAF 中不得反复 seek 追模拟时钟。只有定位、
  重播、换源允许 seek；换源保留实际位置。自动播放被拒绝时给出明确的播放按钮。
- **轨道连续帧**：每个演示从本地视频抽取 12 个时刻，保存为一张 1920 × 90 JPEG；
  创建演示每个片段使用对应的四格，其他两个片段各用十二格。SVG 窗口保持原始帧比例，
  不能将一张海报拉成整条视频轨，也不能为每格缩略图创建视频解码器。
- 重建网页素材：在 `website/` 运行
  `node scripts/build-showcase-media.mjs /path/to/AI_Video_SouthPole`。
  原素材只读，输出十二份静音 MP4 / JPEG，校验时长、尺寸及无音轨；不联网、不部署。
  只重建轨道图集时运行 `node scripts/build-showcase-filmstrips.mjs`。

## 文档页视频教程

教程视频统一放在 `website/public/media/guides/`，按英文标题用小写连字符命名：
「如何在 Mac 上安装 SkyCut」对应 `how-to-install-skycut-on-mac.mp4` 和同名 `.jpg` 封面；
字幕一种语言一个 VTT，使用同名的 `.zh-Hans.vtt`、`.en.vtt` 等语言后缀。

四语言文档页的安装说明后共用这一段 32.5 秒录屏，`#video` 直接定位到教程。
只移除静音音轨，视频流不重编码；封面是 4.5 秒的安装窗口，缩为 864 × 540 JPEG。
使用原生 `video` 的 controls、playsinline、metadata 预加载和 poster，不自动播放。
每页只输出一条默认开启的字幕：中文是 `zh-Hans`，英文是 `en`；德文与西班牙文暂用英文，
构建时若发现同名 `.de.vtt` / `.es.vtt` 就自动采用，新增翻译只需加对应 VTT 文件。
Vercel 为 `/media/` 下所有 `.vtt` 显式设置 `text/vtt; charset=utf-8`，保留 nosniff。

静态 JSON-LD 沿用现有实体图，为文档页增加 [VideoObject](https://schema.org/VideoObject)，
标题、说明与页面一致，视频、封面、时长和这一页的字幕来自同一份资源配置；不推测上传日期。
`tests/install-guide.test.mjs` 覆盖四语言播放器合同、默认字幕、VTT 时间轴和 MIME 配置；
`npm run check:seo` 另外核对实际构建的 VideoObject 与视频、封面、字幕资源逐字节一致。
人工回归：本地 `npm run dev` 检查四语言安装区，桌面与 390 像素宽度播放真实视频，
确认字幕默认可见、暂停 / 定位可用、封面和布局正常且无横向溢出，并保留两种宽度的截图。

2026-11-06 本地验收：57 项网站测试、生产构建、SEO 产物审计和原生
`scripts/check-local.sh docs-index-drift` 全绿；视频流与原片 hash 相同、无音轨，
两份 VTT 与用户审核版逐字节一致。本地 Safari 核对四语言桌面与 390 × 844 布局，
中英文默认字幕及真实播放正常，保留桌面 / 手机截图；未创建云端预览或部署。

## 价格

首页 `#pricing` 放在短片与下载之间，桌面导航、手机菜单和页脚都链接到各自语言首页的
这一节，不新增页面。内容以[收费方案「自助购买 Pro」第 21–36 条](../plans/2026-10-27-paid-plans-and-sky-studio-key.md#自助购买-pro2026-11-05-拍的板)
为准：免费版手动剪辑、Sky Studio 导出水印、新账号 7 天 Pro；Pro 提供 AI / MCP 剪辑与
无水印导出，一个账号一人使用最多 2 台 Mac，Claude / Codex 客户端由用户自备。

英文、德文、西班牙文写 $19 / 月、$149 / 年；中文写 ¥129 / 月、¥999 / 年，并补充
微信一次性买一年 ¥999、不自动续费。月付不送积分，年付每个付费年送 1,000 Sky Studio
积分；生成图片、视频、配音所用积分另购。价格不含税、结账按所在地另加；可随时取消
自动续费并用到已付期限，已付费用不退、法律另有规定的除外。官网不展示折扣百分比。

购买按钮只有一个目的地址 `https://skystudioai.com/app/skycut/pro`，新标签打开，说明先
登录 Sky Studio 再购买。官网不放结账、支付 SDK、Dodo 代码或付款方式分流。
`content/pricing.js` 是金额与币种的唯一来源，四语言文案在各自 `content` 文件；首页
`SoftwareApplication.offers` 共用这份标价，标明免费版和 Pro 月付 / 年付周期与不含税，
不在文档或隐私页额外声明 offers。周期采用
[Schema.org UnitPriceSpecification](https://schema.org/UnitPriceSpecification) 的 `billingDuration`。
sitemap 与 canonical 仍为 12 个 URL。

**2026-11-06 已合并发布**：Claude 确认 Sky Studio 购买页正式上线后，PR E（#325）
已合并，并按既有 main 发布链路上线。四语言首页的价格区、购买外链与 JSON-LD `offers`
均已上线；对应 main 提交与部署记录见下方「运行与部署」。

验收：`npm test` 覆盖四语言价格、权益、条款、导航和唯一购买外链，`npm run build` 后
`npm run check:seo` 核对真实产物的 offers、币种和周期。人工回归检查四语言在桌面、
834 × 1112 iPad、390 × 844 手机的价格区，手机菜单跳转后关闭，价格与周期不折坏、
文字和按钮无横向溢出；桌面左右并排、平板上下排列、手机逐项展开月付与年付。

## SEO 与创始人身份

2026-11-05 用户确定：SkyCut 创始人是 **Sky Lu**，与 **Sky Studio** 属于同一产品家族。
公开来源为 [Sky Lu 创始人页面](https://skylu.ai/founder/)，本次已读取线上页面核对：
中文名陆天宇、Sky Studio 创始人，以及学习 → Sky Studio 创作 → SkyCut 剪辑的流程。
不复制其他仓库的规则或改动创始人站点。

- 页脚以四种语言显示创始人与产品家族，分别链接创始人页面和 Sky Studio。
  保留主页短文案与原有配色，不额外堆叠长篇个人履历。
- `scripts/site-config.mjs` 是公开域名、语言、路由与身份 id 的统一来源；`seo.mjs`
  在构建时生成独立页面标题、摘要、author、robots、canonical、hreflang、OG 和 Twitter。
  这些内容已存在于静态 HTML，不能依赖浏览器执行 JavaScript 才注入。
- `structured-data.mjs` 的 JSON-LD 连接 Person、Organization、SoftwareApplication、
  WebSite、WebPage 和文档 / 隐私的 BreadcrumbList。复用创始人页面现有实体 id：
  `https://skylu.ai/#person` 和 `https://skystudioai.com/#organization`。
  Sky Studio 的 `founder`、SkyCut 的 `creator` / `publisher` 与 `applicationSuite`
  表达同一产品家族；价格只写方案里定的真实价格；不捏造成立时间、评分、下载量或尚未发布的系统支持。
- 只有首页、文档、隐私三类 × 四语言 = **12 个 canonical URL** 进入 `sitemap.xml`。
  每项都列四种语言与英文 `x-default`，与 HTML 的 reciprocal hreflang 对齐。
  根目录英文副本 canonical 指向 `/en/`，不重复进入 sitemap。
- 404 为 `noindex,follow`，不进 sitemap；canonical 指向自己的 `/404.html`，不能指成首页。
  `robots.txt` 开放页面、屏蔽 `/api/` 并声明正式域名的 sitemap 地址。
  不把本机构建日期当成页面修改日期伪造 `lastmod`，不填无实际依据的更新时间。
- 分享图片是四张 1200 × 630 PNG，沿用暖白 / 森林绿和 Outfit 字体，分别对应页面语言，
  带 Sky Lu 与 Sky Studio 家族信息；所有 OG / Twitter 图片链接都是正式域名的绝对地址。
  `npm run build:social` 重建 SVG 与 PNG，需要 Pillow、fontTools 与简体中文字体；
  可通过 `--cjk-font` 传入字体，默认使用 macOS 黑体。普通 `npm run build` 只复制已生成
  的公共图片，不依赖 Python。当前工具进程若以 x86 运行而 Pillow 为 arm64，可使用
  `arch -arm64 python3 scripts/build-social-images.py`。
- `npm run check:seo` 在 Vite 构建后读取实际 `dist`，核对 12 个语言页面、根目录副本、
  404、JSON-LD、图片、构建资源、robots 与 sitemap；源模板测试不能代替这个产物检查。
  `tests/seo.test.mjs` 另外核对路由摘要、实体关系、语言互链、真实 PNG 尺寸与 JSON 安全序列化。
- 最终合并部署后再验证正式域名 HTTP 状态、实际分享预览，并在 Google Search Console
  提交 `https://skycut.app/sitemap.xml`；本地完成不代表已经部署、提交或被搜索引擎收录。

实现口径参考 [Google 多语言页面](https://developers.google.com/search/docs/specialty/international/localized-versions)、
[Google sitemap](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap)、
[站点名称](https://developers.google.com/search/docs/appearance/site-names) 与
[Schema.org 软件应用](https://schema.org/SoftwareApplication)。

## 运行与部署

- 在 `website/` 执行 `npm ci`、`npm test`、`npm run build`。
- CI 的 `check-all` 汇总 job 在 App 分组完成后额外安装网站依赖，执行网站测试、构建与
  SEO 产物审计；网站任一项失败都不能合并，不改变现有 App 分组与文档快速通道。
- **开发和验收只在本地预览**：`cd website && npm run dev`，打开
  `http://127.0.0.1:5173/zh/`。Vite 提供页面与热更新，并直接调用实际的本地邮件登记
  处理器 `/api/subscribe`，不用部署云端函数。`npm run build` 也是本机构建。
- 参考 `cursor-skystudios-app-cinematic` 的本地开发入口与合并后发布原则；该项目以
  Vite 前端代理本机 `vercel dev` 的 API。本官网只有一个登记处理器，复用既有 Vite
  middleware 即可，不引入它的双进程、认证或生产环境配置，也不复制其云端 Preview 权限。
- 只看打包后的静态页面时，可先 `npm run build` 再 `npm run preview -- --port 4173`；
  这个静态预览不提供邮件 API，登记行为必须在 `npm run dev` 中验证。
- 开发期间禁止 `vercel deploy`、`vercel --prod`、云端 Redeploy 或 Preview 部署；
  功能分支 push、PR 创建或更新不应产生 Vercel 构建。最终 PR 的 CI 通过并合并到
  `main` 后，才由合并后的 `main` 提交触发一次正式部署。不能上传本地未合并工作区。
- `website/vercel.json` 的 `git.deploymentEnabled` 用 `**: false` 关闭所有分支，
  仅 `main: true` 放行；`**` 覆盖带斜杠的功能分支。这是 Git 集成的分支过滤，不能
  阻止手动 CLI 部署，后者由上述协作规则禁止。规则语义按
  [Vercel Git 配置](https://vercel.com/docs/project-configuration/git-configuration) 执行。
- Vercel 项目以 `website/` 为根目录、Vite 为框架、`dist` 为输出。
- 独立项目为 `skystudios-projects/skycut-website`，正式域名是 `https://skycut.app`，
  `www.skycut.app` 以 308 跳转到正式域名。Root Directory 为 `website`，Vite / Node 24，
  `npm ci` 安装、`npm run build` 构建、`dist` 输出；云端地址
  `https://skycut-website.vercel.app` 不是开发评审入口。
- **实际发布链路（2026-11-05）**：Vercel GitHub App 尚未安装，仓库自动关联会明确报
  `Install GitHub App`。目前保持 `gitProviderOptions.createDeployments=disabled`，
  功能分支和 PR 不创建 Vercel 构建。CI 全绿后通过 PR 合并，再调用 Vercel 的
  `POST /v13/deployments`，`target=production`、`gitSource.type=github`、
  `repoId=1315079157`、`ref=main`、`sha` 为刚核对的合并提交。这是从已合并 Git 提交
  发布，不上传本地文件；不是已经接通自动部署。
- 首次正式发布为 [PR #309](https://github.com/skysf/SkyCut/pull/309)，main 提交
  `934579ff120d01214ec798779ec9d7fe70f2fe20`，Vercel 部署
  `dpl_9kNSMvUQTFARnfC3GVAxFm5E74P5` 为 READY。以后若接通 GitHub App，仍须只放行
  `main`，保留 `vercel.json` 的分支过滤；不能给功能分支或 PR 开 Preview。
  邮件服务尚未配置，单独开通与验收。
- 价格与购买入口于 2026-11-06 通过 [PR #325](https://github.com/skysf/SkyCut/pull/325) 合并，main 提交
  `81b6ca887c00663f7e7d9de5dfb4f4b1a76e2a37`；按上述实际发布链路调用 `POST /v13/deployments`
  （`gitSource`、`ref=main`、`sha` 为该提交），Vercel 部署 `dpl_7MMY3iAmnbHuizVyfoewBFLt6S67` 为 READY。
  Claude 已核对四语言首页均有价格区、购买外链和 JSON-LD `offers`。
- `.vercel/`、`node_modules/` 和生成的语言 HTML 不入库。源是 `content/*.js` 和
  `scripts/*.mjs`，不能直接改生成页。
- 下载沿用 `https://skylu.ai/download/skycut`。2026-11-05 用户单独授权更新 App，
  森林主题随正式包 `SkyCut-0.18.58-arm64.dmg` 发布；下载入口由个人站仓库的 `_redirects` 管理，
  文件放在既有 R2 的 `skycut/` 前缀。后续每次 App 发布都先验签、上传新版本对象并从
  公开地址读回核对，再更新入口；不是自动取最新本地包。官网网页发布与 App 发版分开，
  只换 DMG 不需要重建或部署 Vercel 官网。证据见 [构建与打包](../build/build-and-packaging.md#公开下载发布)。

## 邮件登记合同

2026-11-07 用户确定：现在只收集邮箱，直接写进 Sky Studio 自己 Google 账号中的
Google 表格，不发邮件、不做双重确认。原 Brevo 和 Turnstile 从未配置；为这一步引入
发信账户、邮件模板、独立名单和机器人挂件超出当前需要，因此移除相关代码和环境变量。
以后需要发送 newsletter 时再导出表格、单独选择发信服务，本次不接入。

平台上线通知（Intel / Windows）与 newsletter 三个选择独立，初始均不勾选。
四语言成功文案表示“已经记下，有消息会发邮件”，不要求去邮箱确认；不再生成专用确认页。
隐私页说明邮箱、三个选择、语言、登记与更新时间，数据保存在 Sky Studio 的 Google
表格，Google 是数据处理方；只发送所选通知，保留至退订或要求删除。退订或删除写信给
`support@skycut.app`，表单保留“随时可以退订”。

部署只需要两个服务端环境变量，身份名沿用 `SRTFLOW_` 前缀：

| 环境变量 | 作用 |
| --- | --- |
| `SRTFLOW_SIGNUP_SHEET_URL` | 必须完整匹配 `https://script.google.com/macros/s/<id>/exec`，id 只含字母、数字、下划线或连字符，不带端口、查询或片段 |
| `SRTFLOW_SIGNUP_SHEET_SECRET` | 至少 32 个字符的共享密钥，与 Apps Script 的 `SECRET` 一致，不能用空白凑长度 |

两个都有效时 `GET /api/subscribe` 只返回 `{"ready":true}`，否则只返回
`{"ready":false}`，普通提交返回 503。URL 和密钥不进页面；邮箱不写日志。
用户部署的脚本原样保存在 `website/integrations/signup-sheet.gs`，仓库中密钥仍是
`REPLACE_WITH_SECRET` 占位符。脚本由用户自己绑定表格并部署为 web app，不由网站创建
或部署；修改脚本合同须先与用户确认。

浏览器仍只 POST 到同源 `/api/subscribe`。处理器校验来源、JSON 类型、4 KiB 上限、
邮箱、三个布尔选择（至少一项）和 `en` / `zh` / `de` / `es` 语言；拒绝额外字段。
邮箱 trim 并转小写，首字符不得是表格公式起始字符，遵守脚本已有验证。隐藏蜜罐
`website` 非空时回同样成功，跳过表格写入。单实例每 IP 每分钟最多五次，限频是附加
守卫，不是跨实例的全局额度，也不代替将来按实际滥用情况调整。

服务端以 `Content-Type: application/json` 向上述地址 POST，字段只有：

```json
{"secret":"...","email":"...","newsletter":false,"intel":true,"windows":false,"language":"en"}
```

Apps Script 先返回 302，再跳到 `script.googleusercontent.com`；fetch 必须跟随，
POST 遇到 302 转为 GET，读取最终输出。只有最终 2xx 且 JSON 为 `{"ok":true}` 才回
`{"code":"registered"}`；`{"ok":false,"error":"bad_request"|"forbidden"|"bad_email"}`、
其他 JSON、HTML、非 2xx、网络错误与超时都返回 502 / `upstream`，前端提示稍后再试。
不自动重发；重复邮箱由脚本合并选择，不新增一行，网站不做另一份去重。

用户已部署脚本并实测四次：包含 302 的往返为 4.3–6.4 秒；错密钥、坏邮箱、成功写入与
邮箱大小写变化后的再次登记均符合合同。这是用户提供的上游实测，网站测试仍只用假服务。
处理器的请求超时是 **15 秒**，覆盖重定向与读 JSON；`vercel.json` 给
`api/subscribe.js` 显式设置 **20 秒** `maxDuration`（按
[Vercel 函数时长配置](https://vercel.com/docs/functions/configuring-functions/duration)）。
浏览器请求保留 20 秒超时，提交期间按钮显示“正在提交”、禁用并设置忙碌状态；控制器在
等配置和等结果期间都锁住提交，结束后恢复按钮，失败保留用户填写的内容。

## 日常品牌邮件

2026-11-06 起使用 **Zoho Mail Lite**：一个邮箱 `support@skystudioai.com`，两个别名
`sky@skystudioai.com`、`support@skycut.app`。回复自动使用收到来信的那个地址。
`skystudioai.com` 与 `skycut.app` 两个域名的 MX、SPF、DKIM（选择器 `zmail`）、DMARC
均按 Zoho 配置。newsletter 的发信服务以后另定，不再沿用私人 Gmail 转发、Thunderbird
与 SMTP2GO 的旧方案。网站代码不读取品牌邮箱或个人邮件。

## 验收

自动：四语言同结构、严格简中匹配、静态页面和资源引用、真实 HTTP 调用生产处理器、
表格请求字段和共享密钥、独立选择、严格 JSON 成功回执、302 跟随、来源伪造、超量 /
畸形输入、蜜罐、限频、上游失败、超时与未配置，以及提交按钮忙碌状态和防重复提交。
测试用本机假表格服务，不调用真实 Google 地址、不写真实表格、不发邮件。

表格登记验收（2026-11-07）：70 项网站测试、本地生产构建、12 个语言页面的 SEO
产物审计和原生 `scripts/check-local.sh docs-index-drift` 通过；Apps Script 与用户提供的
部署版逐字节一致。Chrome 本地开发预览检查桌面与 390 × 844 手机表单，两个宽度均
显示“邮件登记暂未开放”，三项选择、语言、退订说明和按钮排版正常，保留两张截图。
首次扫描因沙箱拒绝读取 `sysctl` 中止，获准重跑后全部守卫通过。未请求真实表格、
未部署或修改 Vercel 环境变量；PR 的 `check-all` 通过后等待用户 review，再决定合并。

首版验收（2026-11-04）：16 项网站测试通过、生产构建通过、仓库
`scripts/check-guards.sh` 通过。Chrome 检查桌面、834 × 1112 iPad、390 × 844
手机排版；中文短片实际播放，Windows 按钮仅勾选 Windows；未配置服务时显示未开放。
Vercel 四语言首页、文档、隐私、API 和资源返回 200，未知路径为 404。
尚未进行真实邮件投递与退订、实际 iPad / 手机硬件测试；未运行 Mac App 全套构建检查。

首屏联动验收（2026-11-04）：20 项网站测试通过（含片段边界、循环队列、20 fps 时间码、
连续整圈旋转），本机构建通过。企鹅替换后循环为 25 秒、640 × 360、20 fps 且没有
音轨。Safari 桌面、约 800 像素平板宽度与 390 × 844 手机尺寸预览可见；观察到实际
视频画面、播放头/时间码推进、卡片换到最前及背面透光，暂停按钮可切换为继续动画。
本地开发日志未见错误；本次未创建任何 Vercel 构建或部署。

AI 展示验收（2026-11-05）：Safari 桌面确认暖白窗口，字幕切换为繁中后画面与时间线
同步更新；834 × 1112 iPad 与 390 × 844 手机响应式预览已检查，观察到实际视频画面、
自动切换语言和播放头推进。移动端使用自然文档流，已检查点击日语按钮后画面与时间线一起更新且不跳出内容。
28 项网站测试、本机生产构建、`scripts/check-guards.sh` 全部通过。
原片 / 1080p 资源及创作循环的尺寸、时长与静音轨道已核验。本次只在本地预览，
未提交、推送、创建 PR 或触发 Vercel 构建；正式开 PR 前仍须合入当时最新 main。

播放与轨道修复验收（2026-11-05）：32 项网站测试、本地生产构建和文档索引检查通过。
恢复旧生产代码后，加载 / 播放与步骤控制两条回归守卫变红，再恢复修复转绿。
Safari 桌面逐一观察三个视频的真实画面、循环、播放头与字幕；390 × 844 响应式预览
确认步骤定位继续播放、连续帧轨道正常，暂停后换语言仍停在同一秒，恢复后继续。
案例见 [官网演示停在封面且轨道像宽图](../bugfixes/2026-11-05-website-demos-stall-on-posters.md)。

发布前验收（2026-11-05）：合入最新 main 的 CI 优化后，40 项网站测试、生产构建、
SEO 产物审计与原生 `scripts/check-local.sh` 扫描守卫全部通过；sitemap XML 为 12 个
页面 / 60 个语言链接。浏览器 PNG / ICO 与 Apple touch icon 已改用官方 App 图标。
真实邮件服务仍未配置，表单按合同显示尚未开放；本次官网发布不包含邮件服务开通或 App 发版。

正式域名验收（2026-11-05）：PR 和合并提交的 CI 全绿，Vercel 从上述准确 main SHA
构建成功，未上传本地工作区。线上 17 个页面为 200、未知路径为 404，sitemap 为 12 项 /
60 个语言链接，robots 与 CSP 正常；ICO、三张 PNG、四个演示 MP4 和中文分享卡片与本地
源文件逐字节一致，视频 Range 请求为 206。`www` 跳转与公开下载的 GET 302 已确认；
订阅 API 返回 `ready:false`。线上仅验证 HTTP 与资源合同；三端画面和交互证据仍是前文的
本地 Safari 验收，不能把 HTTP 检查冒充线上浏览器实测。

人工：桌面、iPad、手机宽度；主标题最多两到三行；语言、菜单、播放、下载、三种登记；
WebGL 与静态回退、减少动态效果、暂停、滚出视口停止渲染；浏览器控制台和网络错误；
首屏四段真实画面轮播、当前卡片移到最前、播放头/时间码同步、完整 360° 与背面透光、
暂停后画面和转台一起停止、手机/桌面切换仍为同一播放进度；
三个 AI 演示的阶段定位、重播、自动 / 手动切换七种字幕、暂停与后台恢复、
720p 到 1080p 换源之后保持同一播放位置；真实手机 / iPad 硬件仍需最后验收。
正式配置表格后由用户用自有邮箱核对实际新增、重复登记合并选择和退订 / 删除流程。
品牌邮箱两域名实际收发另行验收；模拟测试不能当成真实写表或投递证据。
