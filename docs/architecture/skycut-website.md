# SkyCut 官网

## 范围与设计

2026-11-04 用户定稿：域名 `skycut.app`，Vercel Pro；C 版暖白 / 森林绿。
英文、简体中文、德文、西班牙文，与个人站相同。主文案短，桌面左右排、iPad 上下排、
手机简化三维场景；不是把桌面截图缩小。首页、文档、隐私页均生成静态 HTML。

代码位于 `website/`，与 Mac App 的 Swift 构建分开。Vite 仅打包本地依赖；Three.js
动态加载，没有 WebGL、减少动态效果、设备太慢时显示从同一个场景烤出来的静图
（见「首屏的质感与渐进增强」）。GSAP 只增强滚动，不把必要内容先藏起来。字体 Outfit 随站点提供；影片素材来自《南极》及用户点名的本机视频。

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
  恢复时继续原进度。系统减少动态效果、WebGL 丢失时换回烤好的静图（见下一节）。
  销毁时释放视频、纹理与几何，手机/桌面切换时复用同一个视频，不能偷偷再开解码器。
- 前三段素材沿用用户已公开的《南极》短片，第四段以用户提供的企鹅视频替换篝火。
  随站点提供轻量的 640 × 360 / 20 fps H.264 静音循环与四张 JPEG，
  不在首屏下载整部影片。重建命令是在 `website/` 执行
  `npm run build:scene-media -- /path/to/antarctica-720p.mp4 /path/to/Shot_企鹅.mp4`，
  需要本机 ffmpeg / ffprobe。源片段时间写在 `SCENE_CLIPS`，原片短镜头去掉底部
  烧录字幕并放慢到 5 秒；新企鹅视频不裁画幅、不改速度，只移除音轨。脚本
  验证循环总长与无音轨后才替换资源。此命令不联网、不部署。

## 首屏的质感与渐进增强

2026-11-11 用户要求首屏的 3D 更有质感，同时「不同浏览器，有些比如没有开动效或 motion 的浏览器
也能正常看到」；看过第一版后确认。上一节定过的构图、配色和行为都不变。只用 `three@0.187.0`
自带的东西（物理材质、PMREM、examples 里的几何工具），不加依赖、不升级版本。

### 一张烤好的静图是默认画面

- 静态 HTML 里就有 `<picture class="scene-still">`：AVIF / WebP 带透明，JPEG 兜底（铺在页面底色上，
  只有很老的浏览器会用到）；不 lazy、`fetchpriority="high"`、alt 用 `imageAlt`。它是 LCP 元素，
  也是关了 JavaScript、没有 WebGL 2、减少动态效果、WebGL 上下文丢失、设备太慢时看到的画面。
  原来用 CSS 拼的静态时间线已删除，任何回退都不许再退到另一种画面。
- 静图从同一个 Three.js 场景烤出来（`src/scene-still.js`），姿势就是实时场景的第一帧
  （`OPENING_ANGLE`、第 0 秒）。实时场景画好第一帧后直接换上，不做淡入淡出：两张图一样，
  换的那一下看不出来；半透明的阴影叠在一起淡入反而会闪一下。
- **一张图对所有宽度**：相机的竖直视角固定，版面变窄只是两边被裁掉。所以静图烤得比任何版面都宽，
  按高度铺满（`object-fit:cover`），和画布对齐。宽屏一套、手机（两张卡）一套，
  手机那套的 `media` 查询与场景的 `COMPACT_QUERY` 是同一个。
- **出血**：画布和静图比版面框每边大 `--scene-height` 的 10%（`SCENE_BLEED`），相机不变
  （`setViewOffset`），柔和阴影自然淡出，不会被框切出一条直线。两者都不接收指针事件，
  拖动和视差挂在版面框上，画布压不住旁边的按钮。各档 `--scene-height` 必须是 10 的倍数，
  出血才是整数像素，画布才不发虚。
- `.hero-visual` 有 `scene-ready` 这个类时显示画布、隐藏静图、出现暂停按钮；没有就是静图。
  版面框的高度每档写死，静图和画布都是绝对定位，所以哪种情况都不跳版面。

### 实时场景什么时候接手、什么时候让位

- `main.js` 等静图画出来，再按 `wantsLiveScene`（有 WebGL 2 且没开减少动态效果）动态加载 `scene.js`。
  **减少动态效果**一开始就开着时 Three.js 根本不下载；中途打开，循环停、换回静图；关掉后接着转。
- Chromium 里每帧读媒体查询的 `matches` 会把它的 `change` 事件吃掉，所以循环发现自己不该再跑时
  要走同一个 `sync()`，不能只靠事件。
- **太慢就让位**（`scene-governor.js`，纯值）：帧预算 40 ms（30 Hz 的屏和 iOS 低电量模式算正常）。
  连续超预算 3 秒，先把像素比从 2 降到 1.5、再到 1（低于 10 fps 直接降到 1），还不行就释放 GPU、
  这次访问一直显示静图（`data-scene-fallback="slow"`）。单帧最多按 250 ms 计，偶发的一次卡顿不会误判；
  高于约 95 Hz 的屏跳帧，不多画。创建上下文带 `failIfMajorPerformanceCaveat`，
  浏览器自己退到软件渲染时直接留静图。
- **上下文丢失**：换回静图、停循环；恢复时重做环境贴图（它在渲染目标里，丢了就没了）再接着转。
- 初始化不堵主线程：环境贴图、每张画布贴图、几何各占一个任务（`breathe()`），着色器用 `compileAsync`。
  改初始化时别把它们并回一个任务，TBT 会回到改前的水平以上。

### 材质和光

- Neutral 色调映射：暖白和森林绿保持页面上的数值，filmic 曲线会把暖白压灰。灯光全是中性白，
  暖色只来自材质本身。
- 环境光是程序生成的小摄影棚经 PMREM 得到的（`scene-environment.js`），不下载 HDR。竖直的玻璃只会映出
  地平线下面那一圈、底座顶面只会映出后方低处、倒角映出上方：每块灯就是为其中一处摆的
  （环形灯和一条细环给每条倒角一条亮线，低处的灯带让玻璃转过去时有扫光）。
- 底座是带清漆的物理材质；面板除了印刷贴图还有一张浮雕 + 粗糙度贴图（剪辑缩略图和字幕条略凸、较亮，
  走带控制和声音轨略凹）。底座上的字用随站的 Outfit，时间码按固定格子排，各系统和静图都一样。
- 卡片：正面写深度、背面半透明照旧，没有实心背板。外面叠一层只加反射的「玻璃」
  （黑底、加色混合、不改 alpha，背面透出的页面底色不受影响），是透射的便宜近似。边框截面是圆肩。
- 主光在卡片后上方，每张卡在底座上朝镜头投一片柔和的影子；地面只显示阴影，
  底座下面另有一张预先模糊的接触阴影跟着底座转。
- 视频和海报开 mipmap 与各向异性过滤，像素比上限 2。鼠标划过时相机轻微平移（真视差），触屏不做。

### 改了场景要重烤静图

改了场景的任何外观（材质、灯光、构图、底座上的字、四张海报、three 或 Outfit 的版本）之后，
在 `website/` 运行 `npm run build:hero-still`，把新的图片和 `scripts/hero-still-stamp.json` 一起提交。

- 脚本起本机 Vite，用无头 Chromium（软件 WebGL，结果不随机器变，连烤两次逐字节相同）渲出
  `scripts/hero-still.mjs` 里列的每个尺寸，停掉服务后再用 Pillow 编成 AVIF / WebP / JPEG 写进
  `public/media/`。不联网、不部署、不开窗口。需要一个 Chromium 内核的浏览器（`CHROME_PATH` 可指定，
  默认找 Playwright 缓存里的 headless shell 或本机 Chrome）和带 Pillow 的 `python3`。
- `npm run build:hero-still -- --review <目录>` 另出几个角度的 PNG 供人看；`HERO_STILL_GPU=1` 用本机 GPU，更快。
- **指纹**：烤的时候把场景模块、四张海报、烤图脚本、three 和 Outfit 的版本算成一个指纹，连同每个产物的
  哈希写进 `scripts/hero-still-stamp.json`。`tests/hero-scene.test.mjs` 每次重算：改了场景没重烤、
  手改了某张静图、静图依赖了没登记的场景模块，都会红。只改注释也算改了，重烤一次即可（图片不会变）。

### 浏览器级的手动检查

`scripts/check-hero-browsers.mjs` 在真的浏览器内核里验上面这些规矩：三个内核 × 三种屏宽 ×
{有动效, 减少动态效果} × {有 WebGL, 没有 WebGL} 共 36 格（该实时的实时、其余都是静图、
减少动态效果时一次都不画、没有报错，首屏在桌面是两栏、iPad 和手机是一栏），
同一内核同一屏宽的四格版面框必须完全相同（9 项），
再加 Chromium 里的 18 项回退行为（关 JavaScript、丢上下文再恢复、暂停、中途开 / 关减少动态效果、
滚出视口、慢设备、软件渲染）。版面框要等页面稳定后再比：首屏底部三个标签的行高跟着字体走，
网页字体在加载完成后才换上时整个首屏会挪 1 像素左右，有没有场景都一样，不能算到场景头上。

- 全程无头，不开窗口；只能在 Mac 上跑（无头 Chromium 靠 Metal 才拿得到真 GPU）。
- Playwright **不是**这个包的依赖，也不进 CI，用固定版本的 npx 跑。在 `website/`：

  ```sh
  npm run build
  npx -y playwright@1.65.0 install chromium webkit firefox   # 每台机器一次
  npx -y -p playwright@1.65.0 node scripts/check-hero-browsers.mjs --out /private/tmp/skycut-hero-check
  ```

  `--out` 存每一格的截图，`--engines chromium` 只跑一个内核。版本对不上、没先构建、有一格不符，
  脚本都以非零退出。改 `scene*.js`、首屏的 HTML / CSS、`main.js` 里加载场景的那一段之后跑一遍。
- CI 里跑的是 `tests/hero-scene.test.mjs`：帧预算和加载条件的纯值规则、四语言静态 HTML 里的静图、
  每个静图文件的像素尺寸、CSS 的版面合同、指纹。它们各自做过反向验证（改坏就红）。
- 脚本里不认的两类控制台输出：无头 WebKit 自己的视频控件图标（`Button failed to load`），
  以及静态预览里没有的登记接口（404）。

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

首页 `#pricing` 位于短片与下载之间，四语言导航均链接到这一节，不新增页面。
标价、权益和购买条款以[收费方案「自助购买 Pro」第 21–38 条](../plans/2026-10-27-paid-plans-and-sky-studio-key.md#自助购买-pro2026-11-05-拍的板)
及现行授权代码为准。新账号保留 7 天 Pro 体验提示；Free 手动功能照常，视频导出带
Sky Studio 水印；Pro 开放 MCP 并导出无水印。Pro 一个账号一人使用、最多 2 台 Mac
是购买限制，只放底部条款，不当作表内优势。Claude Code / Claude Desktop / Codex
客户端由用户自备。

### 价格卡片与逐行对比（2026-11-07）

两张卡片放价格、年付折合与节省金额、积分和下载 / 购买入口。免费卡片另放一行概括：
完整剪辑、字幕、录屏和小工具，导出带水印；以大号 $0 / ¥0 与“永久免费”标明价格，
提供“看完整对比”链接跳到 `#pricing-comparison`。详细功能集中在同一张
原生 `table`：左列是功能，右边 Free / Pro 两列，公共功能同一行两边打勾；顶部高亮
AI 剪辑、视频水印、让 AI 调云端模型、年付积分四项差别。下方按剪辑、画面、文字形状、
声音、字幕、录屏工具、导出、角色系统和本机 / 云端模型分组。角色系统单独成组，紧邻模型区，
读取与导入管理标“不扣积分”，设定图、头像和带角色的图片 / 视频生成标“消耗积分”。
手机 390 宽仍是左右对比、文字换行，
不改成上下两份功能清单，不用横向滚动隐藏一边。表头滚动时保留方案列名。

`content/feature-matrix.js` 保存统一行序、授权差别与依据，四份 `content/comparison-*.js`
只管翻译；`scripts/comparison.mjs` 统一渲染，`content/ai-models.js` 集中维护品牌模型名。
首页可见文案不用句读标点，模型名称、金额的小数点等必要符号保留。

英文、德文、西班牙文用 $19 / 月、$149 / 年，中文用 ¥129 / 月、¥999 / 年。
`content/pricing.js` 是金额与币种的唯一来源；`annualBreakdown` 按传入标价计算
年价 ÷ 12（保留两位小数）与月价 × 12 − 年价。年付卡片以 $12.42 / ¥83.25 每月作为
大号主价格，与月付数字同字号，下一行紧接“按年付费 $149 / ¥999 每年”的真实扣款。
节省 $79 / ¥549 用深绿标签强调，中文写“比按月付一年省 ¥549”，四语言按完整句式
插入现算金额，不把一条句子拆成生硬的两段。不能把折合数字写进 JSON-LD，结构化数据仍是
免费 0、真实月价与真实年价，周期为 `P1M` / `P1Y`，沿用
[Schema.org UnitPriceSpecification](https://schema.org/UnitPriceSpecification)。
年付每个付费年送 1,000 Sky Studio 积分，月付不送；云端生成另用购买的积分。
价格不含税、结账按所在地另加；取消自动续费后用到已付期限，已付费用不退，法律
另有规定的除外。中文保留微信一次性买一年 ¥999、不自动续费，不展示折扣百分比。

唯一购买目的地仍是 `https://skystudioai.com/app/skycut/pro`，新标签打开，说明先登录
Sky Studio。官网不接支付 SDK 或结账逻辑。12 个 canonical URL 和 sitemap 不变。
价格与购买入口于 2026-11-06 通过 PR #325 上线；完整功能对比和年付折合展示于
2026-11-07 通过 [PR #333](https://github.com/skysf/SkyCut/pull/333) 合并上线。

### 模型目录来源与授权

2026-11-07 快照来自只读 Sky Studio 仓库
`cursor-skystudios-app-cinematic` 的 Sky Studio PR #242 合并版本
`94c3dcd3c86ce005d15a34e1dba13ebe3fab7a00`，对应已受控上线的目录。
只用 `git show <revision>:<路径>` 读取，不改该仓库、不调用真实生成服务。2026-11-10 起 pin 改到 Sky Studio PR #245（定价修正：
Omni 换成 1.2、Veo 3.1 Pro 下架）的 head `86b797a9c935c3499674fce33525ab0255527745`，**改这一版时 #245 还没合并**：官网这一版
要等 #245 在生产上线后再合（合进 main 就部署，见上面「后台接口上线不等于客户端已发版」那一条的同类规矩）。角色引用的两个锚点在这个 revision 里还在。

- `docs/agents/skycut-api.md` 的 `GET /models` 与 `Per kind` 是合同。
- `api/_utils/skycut/catalog.ts`、`visualModels.ts` 和各 `*Contract.ts` 构建 SkyCut 专用目录；
  共 31 条记录、26 个不同 id（2026-11-07 是 33 / 27；2026-11-10 Veo 3.1 Pro 下架少两条；**2026-11-11 声音模型改照声音目录快照之后是 39 / 34**，见下面「声音功能上线后」），其中图片类 9 条。五个共享视频模型分别列
  文生视频和图生视频，所以不能写成 31 个互不相同的模型，也不能搬 Studio 网站中未向 SkyCut 开放的模型。
- `shared/skycutImageModels.ts` 钉公开图片 id 与网页内部 id 的映射，`shared/modelDisplayNames.ts`
  给普通图片与五个共享视频模型的显示名；`visualModels.ts` 直接给 `Qwen Angles` 与
  `Image Upscale` 这两种特殊操作的名字和 operation。`shared/musicModel.ts` 给音乐名；
  `shared/skycutWan3.ts`、`skycutHeygen.ts`、`skycutH3LipSync.ts`、
  `skycutRemoveBackground.ts`、`videoUpscale.ts` 给其他视频、口型、去背景与放大的名称。
  `catalog.ts` 直接提供三种音频的标题。
- 与任务草稿的简称相比，按代码显示 `Minimax H3`、`Ideogram Remove Background`、
  `HeyGen v3 Lipsync Speed` / `Precision`、`MiniMax H3 Max Lip Sync (Image to Video)`、
  `Eleven v4 narration`、`Sonilo sound effects`（`Zonos 2 voice clone` 2026-11-11 随声音目录去掉）。
- Sky Studio 的 SkyCut 目录或这些显示名变更时，**同步更新**本网站快照、四语言说明和
  相关测试；页面提示“模型目录会更新，以 App 里看到的为准”。CI 不依赖另一仓库的本机路径。

| 类别 | 显示模型 | 记录数 | 界面与 AI 入口 |
| --- | --- | --- | --- |
| 图片生成 | Seedream 5.0 Flash、Nano Banana 2、Nano Banana 2 Lite、Nano Banana Pro、GPT Image 2、Seedream 5.0 Pro | 6 | Pro 经 AI，扣积分 |
| 图片换角度 | Qwen Angles（`qwen-angles`，`operation=camera_angle`） | 1 | Pro 经 AI，扣积分；一张图旋转、俯仰、推拉 |
| 图片放大 | Image Upscale（`image-upscale`，`operation=upscale`） | 1 | Pro 经 AI，扣积分；2 / 3 / 4 倍，受 1650 万输出像素上限约束 |
| 图片背景去除 | Ideogram Remove Background | 1 | Pro 经 AI，扣积分 |
| 视频 | Minimax H3、Gemini Omni 1.2 Flash、Veo 3.1 Fast、Seedance 2.0 Pro、Seedance 2.5；Wan 3.0 Text to Video / Image to Video / Reference to Video | 13 | Pro 经 AI，扣积分 |
| 对口型 | HeyGen v3 Lipsync Speed / Precision、MiniMax H3 Max Lip Sync (Image to Video) | 3 | Pro 经 AI，扣积分 |
| 音乐 | Lyria 3 Pro | 1 | Pro 经 AI，扣积分 |
| 旁白生成 | Gemini 3.8 Flash TTS、Eleven v4 narration | 2 | Pro 经 AI，扣积分 |
| 音效生成 | Sonilo sound effects | 1 | Pro 经 AI，扣积分 |
| 用克隆的声音读旁白 | IndexTTS2 cloned reading、MiniMax Speech 2.8 HD cloned reading、HeyGen Voice Turbo cloned reading、MiniMax version of a voice (one-time) | 4 | Pro 经 AI，扣积分 |
| 声音设计 | MiniMax voice design (one-time)、Qwen3 voice design (one-time) | 2 | Free / Pro 界面直接用，Pro 也可经 AI，均扣积分 |
| 变声 | Chatterbox HD voice conversion、Chatterbox voice conversion | 2 | Free / Pro 界面直接用，Pro 也可经 AI，均扣积分 |
| 视频画质提升 | Topaz Starlight、ByteDance Upscaler Pro | 2 | Free / Pro 界面直接用，Pro 也可经 AI，均扣积分 |

普通图片新增的四个模型，0.18.61 就能让 AI 点名使用；图片换角度、图片放大和角色系统要
SkyCut 0.18.62（2026-11-07 发布）。这一版官网在 0.18.62 发布、图片放大修好之后才合并上线
（[PR #337](https://github.com/skysf/SkyCut/pull/337)）。以后同类内容照此办：后台接口上线不等于客户端已发版，
等客户端发布、真积分验收过再合并官网。

图片放大原来由 Sky Studio 调 Google Vertex 的 `imagen-4.0-upscale-preview`。2026-11-07 冒烟发现它被下线（404，
网页端同样失效），当天 [Sky Studio PR #243](https://github.com/skysf/skystudio-aigc-app/pull/243) 换成 fal SeedVR2
（`fal-ai/seedvr/upscale/image`）。对外 id `image-upscale`、显示名 `Image Upscale`、x2 / x3 / x4 和 8 积分都不变，
所以本页文案不用改；实测见 SkyCut 的[真积分验收报告](../reports/2026-11-07-image-models-and-characters-smoke.md)。

### 声音功能上线后的功能表和模型表（2026-11-11）

0.18.65 的声音功能（声音库、右键「换成我的声音」、全部权限下的长期授权）进了对比表：

- 功能行（「声音」一组）：`voiceLibrary`（Free / Pro 都包含：用自己的录音新建声音不扣积分、设计声音花积分、在设置里管理；全部权限下 AI 用和建声音不必每次再问）、
  `voiceChange`（Free 界面直接用、Pro 界面或 AI，都花积分）。**界面这两条不看套餐**：[真实冒烟](../reports/2026-11-11-voice-real-smoke.md)在免费套餐下建、设计、变声、删都走通了。
- 声音模型**照 SkyCut 仓库里的声音目录快照** `checks/SkyStudio/Fixtures/models-voice-2026-11-10.json`（Sky Studio `/models` 的导出原样拷来的），
  `ai-models.js` 的 `voiceCatalogSnapshot` 指着它，网站测试逐条比 id、kind、标题：旁白 2 个（Gemini 3.8 Flash TTS、Eleven v4 narration）、
  克隆读稿 3 个 + MiniMax 版一次性费用 1 个、声音设计 2 个、变声 2 个。Zonos 2 已经不在目录里，去掉了。
- 模型行的可用性：旁白、克隆读稿只有 AI 入口（Pro）；声音设计、变声、视频画质提升在界面里就能用（`inApp`），Free 也行。
- 目录从 26 个 id / 31 条记录变成 34 / 39。那边的快照换了，这里跟着换，`llms-full.txt` 自动跟着变。

### 角色系统来源与费用

同一 revision 的 [Saved Character references](https://github.com/skysf/skystudio-aigc-app/blob/94c3dcd3c86ce005d15a34e1dba13ebe3fab7a00/docs/agents/skycut-api.md#saved-character-references-2026-11-07)
规定读取与引用角色，[Native Character creation and management](https://github.com/skysf/skystudio-aigc-app/blob/94c3dcd3c86ce005d15a34e1dba13ebe3fab7a00/docs/agents/skycut-api.md#native-character-creation-and-management-2026-11-07)
规定创建、导入、编辑、换图、头像与删除。页面只说明 AI 入口，不承诺有手动角色面板。
所有角色行的 Free 都写“需要 Pro”，Pro 都是“让 AI 调用”；不扣积分的操作也需要软件 Pro 授权。

| 功能行 | 接口依据 | 积分 |
| --- | --- | --- |
| 读取角色（`characterRead`） | `GET /characters`、`GET /characters/{id}`，同账号当前可用视图与 revision | 0 |
| 带角色生成（`characterGenerate`） | visual quote / jobs 的 `character_id`、`character_roles` 与 `character_revision`，支持的图片 / 视频模型复用角色引用 | 按对应模型和引用数量正常收费 |
| 角色设定图（`characterCreate`） | `POST /characters/create` 或 `operation=character_create`，文字或一张自有照片 | 一张源图的费用，裁出四个视图不收四次钱 |
| 导入与管理（`characterManage`） | `POST /characters/import` 正面 / 侧面 / 背面齐全；`PATCH` 改名；`PUT images/{role}` 换图；`DELETE` 删除 | 0 |
| 重做头像（`characterHeadshot`） | `POST /characters/{id}/headshot` 或 `operation=character_headshot`，以当前正面图生成 | 一张引用图的费用 |

角色导入的 `character-import` 是内部服务标记，角色能力中的图片模型也是复用现有模型，
均不新增 `/models` 条目。`feature-matrix.js` 的 `characterRows` 保留固定 revision 的合同链接；
CI 校验链接与行结构，不联网读取另一个仓库，也不把外部仓库本机路径作为 CI 依赖。

**不扣积分不等于 MCP 免费**：`SkyCutGates.aiAllows` 除 `get_status` 外按授权拦所有 AI
工具。Apple 语音识别（macOS 26）与 Apple 翻译（macOS 15）在字幕面板中可免费使用；
Kokoro 配音、音效合成、主体识别与扫字目前只有 AI 生成 / 分析入口，因此使用仍需 Pro，
但本机计算不扣积分。Kokoro 在设置中下载声音包，下载按钮不等于有手动配音面板。
它有 8 个中英文角色，支持中、英、日、西、法、意、葡、印地语；不把德语写进 Kokoro。
合成器有 16 个预设，网页只保留数量说明，不展示 whoosh 到 shutter 的预设名列表。
页面将这两项分别写成“内置多语言声音合成”和“内置音效合成器”，不展示 Kokoro 名称，
声音说明和语言标签保留；四语言采用同样口径。Kokoro 仍是内部实现和源码依据的名字。
两者数量与语言由网站测试对照 App 代码；云端模型的 id、品牌名、类别归属与记录数按上述发布快照维护。
镜头切换检测实际是 `AIShotScan` / `AIShotDetector` 的本机画面差异分析；不冒称由
Apple Vision 检测切点。Vision 用于主体、标签和画面文字识别。

**upscale 的例外已复核**：检查器 / 右键 → `UpscalePanelModel` → `UpscaleJob`
的面板路径只查 Key、报价与预算，没有 Pro 判断；`SkyStudioJobGate` 管积分预算和
审批，不管软件授权。AI 的 `upscale_clip` 仍先经过 `AIToolRouter` 的 MCP 门。
因此不能把界面画质提升也标成 Pro 独享。另见[视频 upscale](video-upscale.md)。

### 功能逐行依据

统一授权依据是 [Sky Studio 账号](sky-studio-account.md)、`SkyCutGates.swift` 和
`AIToolRouter.swift`：本轮不修改任何 App 授权行为，只照已实现的入口写文案。
每条既有功能的具体实现与长期合同如下，文件路径也存在 `feature-matrix.js` 的 `sources` 中；
角色行的外部合同依据与费用见上表：

| 功能行 | 依据 |
| --- | --- |
| Claude Code 与 Claude 桌面版及 Codex 来剪辑（`aiEditing`） | [ai-control-mcp.md](ai-control-mcp.md)、[MCPToolCatalog.swift](../../Sources/SrtFlowMCPKit/MCPToolCatalog.swift)、[SkyCutGates.swift](../../Sources/SrtFlow/SkyStudio/SkyCutGates.swift) |
| 视频导出水印（`watermark`） | [sky-studio-account.md](sky-studio-account.md) |
| 让 AI 使用云端模型（`cloudAI`） | [sky-studio-jobs.md](sky-studio-jobs.md) |
| 年付 Pro 赠送 Sky Studio 积分（`annualCredits`） | [2026-10-27-paid-plans-and-sky-studio-key.md](../plans/2026-10-27-paid-plans-and-sky-studio-key.md) |
| 多轨剪辑（`multitrack`） | [video-tracks.md](video-tracks.md)、[clip-animation.md](clip-animation.md) |
| 精细时间线工具（`timeline`） | [timeline-drag-gestures.md](timeline-drag-gestures.md)、[timeline-clipboard.md](timeline-clipboard.md)、[timeline-linkage.md](timeline-linkage.md) |
| 变速与定格（`speed`） | [timeline-drag-gestures.md](timeline-drag-gestures.md)、[VideoEditFreezeFrame.swift](../../Sources/SrtFlow/VideoEditFreezeFrame.swift) |
| 工程管理（`projects`） | [video-edit-project-file.md](video-edit-project-file.md)、[open-projects.md](open-projects.md)、[optimized-media.md](optimized-media.md) |
| 画面摆放（`transform`） | [preview-free-transform.md](preview-free-transform.md) |
| 动画与关键帧（`animation`） | [clip-animation.md](clip-animation.md)、[keyframe-animation.md](keyframe-animation.md)、[video-fades.md](video-fades.md) |
| 转场（`transitions`） | [transition-handles.md](transition-handles.md) |
| 调色与滤镜（`color`） | [filters.md](filters.md) |
| 局部模糊与马赛克（`covers`） | [cover-blur-mosaic.md](cover-blur-mosaic.md) |
| 画面文字（`text`） | [text-overlays.md](text-overlays.md) |
| 文字与数字动画（`textAnimation`） | [text-overlays.md](text-overlays.md) |
| 形状与绘制动画（`shapes`） | [shapes.md](shapes.md) |
| 片段声音控制（`audioEdit`） | [audio-waveform.md](audio-waveform.md)、[audio-volume-curve.md](audio-volume-curve.md)、[audio-fades.md](audio-fades.md) |
| 轨道与总线混音（`mixing`） | [audio-mixer.md](audio-mixer.md) |
| 声音场景（`scenes`） | [sound-scenes.md](sound-scenes.md) |
| 音乐与音效库（`library`） | [AudioLibraryPanel.swift](../../Sources/SrtFlow/AudioLibraryPanel.swift) |
| 字幕编辑（`subtitleEdit`） | [README.md](../../README.md)、[subtitle-track-visibility-and-layout.md](subtitle-track-visibility-and-layout.md) |
| 字幕样式（`subtitleStyle`） | [subtitle-track-visibility-and-layout.md](subtitle-track-visibility-and-layout.md)、[README.md](../../README.md) |
| 录屏（`recording`） | [README.md](../../README.md)、[screen-recording-lifecycle.md](screen-recording-lifecycle.md) |
| 视频压缩（`compression`） | [README.md](../../README.md)、[export-settings.md](export-settings.md) |
| 字幕文件工具（`subtitleTools`） | [README.md](../../README.md) |
| 视频导出（`videoExport`） | [export-settings.md](export-settings.md)、[VideoEncodeSettings.swift](../../Sources/SrtFlowCore/VideoEncodeSettings.swift) |
| 声音导出（`audioExport`） | [export-settings.md](export-settings.md)、[export-audio-mixdown.md](export-audio-mixdown.md) |
| 独立字幕文件（`subtitleExport`） | [export-settings.md](export-settings.md) |
| Apple 语音识别（`speech`） | [SpeechTranscriptionService.swift](../../Sources/SrtFlow/SubtitleGen/SpeechTranscriptionService.swift) |
| Apple 翻译（`translation`） | [SubtitleTranslationService.swift](../../Sources/SrtFlow/SubtitleGen/SubtitleTranslationService.swift) |
| Apple Vision（`vision`） | [AIVision.swift](../../Sources/SrtFlow/AIVision.swift) |
| SkyCut 分镜头检测（`shots`） | [AIShotScan.swift](../../Sources/SrtFlow/AIShotScan.swift)、[AIShotDetector.swift](../../Sources/SrtFlow/AIShotDetector.swift) |
| 内置多语言声音合成（内部键 `kokoro`） | [AIVoiceRole.swift](../../Sources/SrtFlow/AIVoiceRole.swift)、[KokoroVoiceSettingsRow.swift](../../Sources/SrtFlow/KokoroVoiceSettingsRow.swift) |
| 内置音效合成器（`synth`） | [SoundEffectPreset.swift](../../Sources/SrtFlow/SoundEffects/SoundEffectPreset.swift)、[sound-effect-synth.md](sound-effect-synth.md) |

验收：网站测试核对四语言同结构、每行 Free / Pro 两格、Pro 高亮差别、所有模型名与
本机功能入口、源码证据路径、8 个声音角色 / 8 种语言 / 16 个音效预设，以及新版类别与
内置功能标题、页面不展示 Kokoro 和预设名列表，以及 33 条目录 / 9 条图片记录、新操作
与视频画质提升的区别、角色各行的 Pro 门和积分标记。折合与节省金额
用真实标价和另两组价格验证；生产构建后的 SEO 审计继续验证真实 offers 标价和周期。
人工在本地 `npm run dev` 核对中文和英文的桌面、390 手机卡片与完整对比表 / 模型，
确保长模型名能换行、两列持续并排、无横向溢出，并保留截图。真实 iPad / 手机硬件另验。
价格卡片还需分别核对 1280 / 1440：同排两卡等高时，免费卡片的零元价格、概括、
对比链接与下载按钮有合理间距，不出现中间整块空白。1440 另留完整对比表截图，
包含顶部 Pro 差异和下方本机 / 云端模型；390 核对月付与年付的大字月价能直接比较、
真实年扣款紧随年付月价、节省标签能换行，点击对比链接落到正确锚点。

2026-11-07 本地验收：81 项网站测试、生产构建、12 个语言页面的 SEO 审计，以及
原生 `scripts/check-local.sh docs-index-drift` 的全部扫描守卫和文档索引检查通过。
Safari 检查中文桌面，Chrome for Testing 检查英文桌面和中英文 390 宽布局；
六张验收截图保留在 `/private/tmp/skycut-pricing-2026-11-07/`，各语言包含桌面、手机
价格卡片和完整功能 / 模型长表。未调用真实模型服务或付款，未进行云端预览或部署。

同日 PR #333 review 补充：免费卡片改为零元价格、永久免费说明、一行功能概括和对比
锚点链接；年付大字先呈现折合月价，下一行说明真实年扣款，用深绿标签突出节省金额。
中英文分别以无头 Chrome 检查 1280 / 1440 / 390 宽，桌面两卡等高、免费内容间距均匀，
月付 / 年付字号一致，无横向溢出；点击对比链接跳到正确锚点。新增八张截图仍存放在
同一目录，文件名为 `{zh,en}-review-{1280,1440,390}-cards.png` 和
`{zh,en}-review-1440-comparison-models.png`，宽度和布局数值另存 `review-layout-metrics.json`。
官网截图使用无头浏览器直接访问本机开发服务器，不操作用户窗口或 Finder；长表可把
无头视口高度加大，完整截图后裁剪，避免超出视口的裁切偏移。

同日新模型与角色系统本地验收：无头 Chrome 在 `127.0.0.1:5173` 检查中文、英文的
1440 与 390 宽对比表，50 个功能行包含 5 个角色行，两列并排且没有横向溢出。
四张截图保留在 `/private/tmp/skycut-models-characters-2026-11-07/`：
`{zh,en}-1440-comparison.png` 为完整对比表，`{zh,en}-390-characters-models.png`
为角色与模型区，手机以 2 倍像素密度保存；布局测量另存 `layout-metrics.json`。
截图已经复核，未操作用户窗口或 Finder；该官网更新在 0.18.62 发布、图片放大修好之后合并部署。

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
- 只有首页、文档、隐私三类 × 四语言 = **12 个 canonical URL** 进入 `sitemap.xml`（已发布的文章另加，见下面「文章栏目」）。
  每项都列四种语言与英文 `x-default`，与 HTML 的 reciprocal hreflang 对齐。
  根目录英文副本 canonical 指向 `/en/`，不重复进入 sitemap。
- **hreflang 的中文不带地区**（2026-11-11）：`HREFLANG_TAGS.zh = 'zh'`。所有中文设备（含繁体）都进这一个中文版（见上面「设备语言」），
  写成 `zh-CN` 的话台湾、香港的中文搜索会被 Google 送去英文的 `x-default`。`<html lang>` 和 JSON-LD 的 `inLanguage` 说的是页面用什么写的，仍是 `zh-CN`。
- 404 为 `noindex,follow`，不进 sitemap；canonical 指向自己的 `/404.html`，不能指成首页。
  可收录的页面的 robots meta 是 `index,follow,max-snippet:-1,max-image-preview:large,max-video-preview:-1`（`INDEX_DIRECTIVES`，和 Sky Studio 的指南一样）。
- **`robots.txt` 对 AI 爬虫全部放开**（用户 2026-11-11 定：搜索 / 回答用的和训练用的都放，让模型认识 SkyCut 也是曝光；`/api/` 照旧屏蔽）。
  名单在 `site-config.mjs` 的 `AI_CRAWLERS`，只写运营方有公开说明的 token，别的照旧落在 `*` 那一组：
  回答 / 搜索用的 OAI-SearchBot、ChatGPT-User（[OpenAI](https://developers.openai.com/api/docs/bots)）、Claude-SearchBot、Claude-User
  （[Anthropic](https://support.claude.com/en/articles/8896518-does-anthropic-crawl-the-web)）、PerplexityBot、Perplexity-User
  （[Perplexity](https://docs.perplexity.ai/guides/bots)）、DuckAssistBot、MistralAI-User、Meta-ExternalFetcher、Applebot；训练用的 GPTBot、ClaudeBot、
  Google-Extended、Applebot-Extended、CCBot、meta-externalagent、Amazonbot。**爬虫找到点名自己的那一组就不再看 `*`**，所以每一组都要重复
  `Disallow: /api/`（守卫数三组各一条）。加减名单只改 `AI_CRAWLERS`。
- **`lastmod` / `dateModified` 只写真改过的那一天**（2026-11-11 起）：`content/page-revisions.json` 给 12 个页面各记一份静态 HTML 的指纹和日期，
  sitemap 的 `lastmod` 和 JSON-LD `WebPage.dateModified` 都从它来。**改了页面（文案、价格、对比表、结构化数据、导航）就在同一次改动里跑
  `npm run stamp:pages`**：只有指纹变了的页面换成当天，没变的保留原日期；`--date=YYYY-MM-DD` 记另一个真实的日子。指纹不算日期本身和页脚的年份。
  漏了这一步 `tests/geo.test.mjs` 会红并说出是哪几页。不许用构建时间、不许手改日期；两个分支都动了同一页时合并后重新跑一遍。
- **结构化数据只写页面上看得见的、有出处的**（2026-11-11 补全）：`SoftwareApplication` 加 `featureList`（就是对比表里的功能名，按页面语言）、
  `applicationSubCategory`、`isAccessibleForFree`、`installUrl`、界面语言 `inLanguage`（`en` / `zh-Hans` / `es`，照 App 的 `Resources/*.lproj`），
  offers 加 `category` 和 `availability`；首页加 `FAQPage`（问答就是页面上那几条，一条不多）；`Organization` 加 `alternateName`、`logo`、`sameAs`
  （和 Sky Studio 自己 `shared/brandEntities.ts` 发的同一组：Wikidata `Q139824875`、YouTube、TikTok）；文档页安装视频的 `VideoObject` 加
  `uploadDate: 2026-11-06`（PR #329 合并并部署的那天，[Google 要求](https://developers.google.com/search/docs/appearance/structured-data/video)这一项）。
  **故意不写的**：`softwareVersion`（官网和发版分开部署，写了就会像文档页那句 0.18.47 一样过期；要写得先定「发版时谁改官网」）、`screenshot`
  （没有真实的 App 截图素材）、评分 / 评论 / 下载量、首屏循环视频和三段演示的 `VideoObject`（装饰性的静音片段，不是能看的视频页）、
  《南极》短片的 `VideoObject`（没有可核实的首发日期）。守卫钉着这几项不许凭空出现。
- **对外的东西一个字不提 GitHub**（用户 2026-11-11 定）：`check:seo` 把构建出来的每个 HTML、两份 llms、sitemap、robots 都搜一遍，出现 `github`（不分大小写）就红；
  `tests/seo.test.mjs`、`tests/guides.test.mjs` 在渲染那一层也拦。功能表里给测试用的合同链接（`feature-matrix.js` 的 `sources`）不上页面，不受影响。
- **搜索结果里的标题和摘要是正常句子**（2026-11-11 协调者定）：文档页、隐私页的 `<title>` 用 `content/seo.js` 的 `titles`（说清这是什么页），页面上的大标题不变；
  四种语言的摘要带标点。首页可见文案仍然不用标点。首页问答多了「SkyCut 是什么」「多少钱」两条，价格从 `pricing.js` 取。文档页不再写具体版本号
  （原来写着 0.18.47，早就过期）。
- **IndexNow**（2026-11-11 协调者定：做，部署后手动跑）：key 是公开的，在 `site-config.mjs` 的 `INDEXNOW_KEY`，对应 `public/<key>.txt`。
  **部署成功之后**在 `website/` 跑 `npm run indexnow`（把 sitemap 里的地址交给 IndexNow；`-- --only=/guides/` 只交文章，`-- --dry-run` 只看不交）。
  脚本先去线上读 key 文件，读不到就停（所以部署前跑不了）；构建和 CI 从不调它。Bing 和用 Bing 索引的 ChatGPT 搜索靠它尽快知道新页面。
- **`/llms.txt` 和 `/llms-full.txt`**（[llmstxt.org](https://llmstxt.org)，2026-11-11）：`scripts/llms.mjs` 在构建时生成、写进 `public/`，
  **不手写**。只有英文一份（助手回答时自己翻译；四种语言各写一份只会各自过期），文件里链到三种其他语言的首页，并写明中文站的人民币价格。
  正文是带标点的英文事实句（是什么、给谁用、系统要求、没有 Intel / Windows 版、Free 和 Pro 各有什么、价格、怎么下载和购买、和 Sky Studio 的关系）；
  价格、系统要求、功能表、模型名都从 `pricing.js`、`site-config.mjs`、`feature-matrix.js`、`ai-models.js` 和英文文案取，改了那些就跟着变。
  `llms-full.txt` 再加逐行的 Free / Pro 对比、角色、本机与云端模型、上手四步和隐私说明。两份都列出**已发布且有英文版**的文章。不写版本号、不写评价性的词、不链仓库。
  提交的那两份必须等于生成的（`tests/geo.test.mjs`；过期就跑 `npm run build`）。**没有哪家大引擎确认读 llms.txt**（Google 明说不需要，
  [日志研究](https://ahrefs.com/blog/llmstxt-study/)里 97% 的文件没被读过）：它便宜、无害、给会读的助手一份干净的事实，不是排名手段。
- 分享图片是四张 1200 × 630 PNG，沿用暖白 / 森林绿和 Outfit 字体，分别对应页面语言，
  带 Sky Lu 与 Sky Studio 家族信息；所有 OG / Twitter 图片链接都是正式域名的绝对地址。
  `npm run build:social` 重建 SVG 与 PNG，需要 Pillow、fontTools 与简体中文字体；
  可通过 `--cjk-font` 传入字体，默认使用 macOS 黑体。普通 `npm run build` 只复制已生成
  的公共图片，不依赖 Python。当前工具进程若以 x86 运行而 Pillow 为 arm64，可使用
  `arch -arm64 python3 scripts/build-social-images.py`。
- `npm run check:seo` 在 Vite 构建后读取实际 `dist`，核对 12 个语言页面、根目录副本、
  404、JSON-LD、图片、构建资源、robots 与 sitemap；源模板测试不能代替这个产物检查。
  `tests/seo.test.mjs` 另外核对路由摘要、实体关系、语言互链、真实 PNG 尺寸与 JSON 安全序列化。
  2026-11-11 起两边都加了：robots 里的 AI 爬虫名单与三组 `/api/`、llms 两份、hreflang 的 `zh`、摘要指令、`lastmod` 与 `dateModified` 同一天、
  首页 `FAQPage` 与看得见的问答一一对应、`featureList`、安装视频的 `uploadDate`，以及文章页（见下）。`tests/geo.test.mjs`、`tests/guides.test.mjs` 是新的两份；
  十处修复逐个撤掉，对应的测试都会红（反向验证见第一轮报告）。
- 最终合并部署后再验证正式域名 HTTP 状态、实际分享预览，并在 Google Search Console
  提交 `https://skycut.app/sitemap.xml`；本地完成不代表已经部署、提交或被搜索引擎收录。

实现口径参考 [Google 多语言页面](https://developers.google.com/search/docs/specialty/international/localized-versions)、
[Google sitemap](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap)、
[站点名称](https://developers.google.com/search/docs/appearance/site-names) 与
[Schema.org 软件应用](https://schema.org/SoftwareApplication)。

## 文章栏目（Guides）

2026-11-11 用户定：在官网开一个文章栏目，用文章把相关的搜索引进来（「让 Claude / Codex 剪视频」「CapCut 替代」「Mac 自动上字幕」这一类）；
题目由我们按证据定，第一篇连同栏目页面先给协调者看质量，再批量写。做法参考 Sky Studio 的指南（它的 `docs/agents/seo.md`「Guides」），
但官网是纯静态站，文章是仓库里的文件、构建时生成，不做后台。

- **地址**：`/<语言>/guides/`（栏目页）和 `/<语言>/guides/<slug>/`；一篇文章一个英文 slug，各语言共用。**某种语言有了第一篇文章才生成它的栏目页、
  导航和页脚才出现「Guides」入口**；没有文章的语言什么都不变。语言菜单里，这篇没有的语言指到那种语言的栏目页，栏目页也没有就指到首页。
- **文章多两种语言：繁体中文 `zh-hant`（台湾用语，不是逐字转换）和日文 `ja`**（2026-11-11 协调者定，照 Sky Studio 指南的经验：这两种语言的窄题点击率最高）。
  **只给文章用，官网页面还是四种**（`GUIDE_ONLY_LANGUAGES`）。这两种语言的文章页借一种官网语言的东西（`siteLanguage`）：`zh-hant` 的导航、页脚、文档链接指到 `/zh/`，
  `ja` 指到 `/en/`；价格照借的那一边以外的规矩走 —— **只有简体中文文章写人民币，其余语言（含繁中、日文）都写美元**并在文中注明。导航和页脚的文字在
  `content/guide-shell.js`。hreflang：一篇文章同时有简体和繁体时写 `zh-Hans` / `zh-Hant`（各管各的文字），只有简体时还是 `zh`；日文 `ja`；`x-default` 是英文版。
  语言菜单在文章页列出这篇真有的语言（最多六种），官网页面仍是四种。`/zh-hant`、`/ja` 这两个光秃秃的地址由 `vercel.json` 302 到各自的栏目页
  （**这一条只能在部署那一次验证**）。`src/language.js` 碰到这两种语言的地址不做 `?lang=` 跳转（它们没有可换的官网页面）。
  **App 界面只有英文、简体中文、西班牙文**：繁中文章的按钮名用简体中文界面上的原文、括号里解释，日文和德文文章用英文界面的名字，并在文中说明。
- **内容**：一篇一个文件夹 `content/guides/<slug>/`：`index.js` 放 slug、类型、日期、出处，每种语言一个文件（`en.js`、`zh-hant.js`……），登记进 `content/guides/index.js`；
  栏目自己的界面文字在 `content/guide-copy.js`（六种语言）。**各语言版本结构必须一样**（节数、每节的块、步骤数、表格行列、问答数、价格占位符），测试逐篇比。
  固定字段：`type`（`guide` 教程 / `list` 清单 / `alternatives` 替代品 / `compare` 对比）、`published` / `updated`、`asOf`（别家事实是哪个月核对的）、
  `sources`（每条别家事实的出处：名称 + 一句话 + https 地址 + 核对日期；**页面上只列名称和核对日期，不带链接**，地址只留在文件里），每种语言的 `title`（≤ 60）、`description`（≤ 155）、
  `heading`、`answer`（开头先给答案的那一段）、`sections`、`faq`。正文是一小套写法（`scripts/guide-markdown.mjs`）：段落、列表、步骤、表格、提示词、备注，
  行内只有 `**粗体**`、`` `代码` ``、`[文字](链接)`，其余一律当文字转义，没有 HTML。
- **试用怎么写**（照[收费方案](../plans/2026-10-27-paid-plans-and-sky-studio-key.md)第 6、20 条）：默认 7 天，从这个账号第一次用 SkyCut 查授权算起，每个账号一次、每台 Mac 一次。
  文章和栏目的下载框写成「第一次把 SkyCut 连上 Sky Studio 账号时开始 7 天 Pro 试用」，不写「新账号都有 7 天」。
- **草稿与发布**：`published: null` 就是草稿。草稿**只在** `SKYCUT_GUIDE_DRAFTS=1` 时生成（本机审稿：`SKYCUT_GUIDE_DRAFTS=1 npm run dev`），带「Draft」标记、
  `noindex`、没有 JSON-LD、不进 sitemap；平常的构建（CI、Vercel）里它不存在，导航也没有入口。**发布 = 在上线那次改动里把 `published` / `updated`
  写成真实上线的日子**：`npm run publish:guides -- --date=YYYY-MM-DD` 给草稿盖日期并重盖页面日期、重新生成；一批改动写了某天、部署却拖到另一天（还没上过线）时
  `npm run publish:guides -- --redate=旧:新` 把文章和同一批的页面日期一起挪过去。以后改文章就手改 `updated`。不许写将来的日子（测试拦）、不许补写过去的日子。
- **发布前的硬规矩**（`scripts/guide-model.mjs` 的 `guideProblems`，构建时不过就报错，`tests/guides.test.mjs` 逐条有反例）：
  1. 标题、摘要长度；开头必须有真答案；每节有内容；问答成对；`asOf` 和每条出处齐全。
  2. **价格不许手写**：正文里出现 `$19` 这种就拒，只能写 `{{pro.monthly}}`、`{{pro.yearly}}`、`{{free.price}}`，渲染时从 `content/pricing.js` 取（按文章语言的币种）。
  3. **只链我们自己的页面**（本站路径、`skylu.ai`、`skystudioai.com`）；别家产品只点名、不给链接，正文里不出现裸网址（同 Sky Studio 的 G3）。
     **对外不提 GitHub**（用户 2026-11-11 定：仓库以后转私有）：正文和出处名称里出现 GitHub、源码仓库就拒；别家的项目写「项目页」「README」。
  4. **没有量过的最高级不许用**（smoothest、fastest、#1……）；「best」只许出现在清单类文章里。
  5. 系统要求每篇都有：结尾的下载框固定写「只支持 Apple silicon、macOS 15 及以上，没有 Windows 和 Intel 版」。
  写别家要公允、可核实：只写它自己的官方页面 / 仓库说的，出处记进 `sources`，页面底部写「别家的事实核对于某年某月」和「SkyCut 是本文发布方的产品」。
  不编测评数据、不编用户评价；SkyCut 的功能、价格、限制照产品写（教程里的界面名称照 App 的英文字符串表）。
- **页面**（`scripts/guide-page.mjs`，样式 `src/styles/guides.css`，只加载 `base` / `responsive` / `guides` 三份样式，不带首页的 3D 和演示）：
  一栏 760 的阅读宽度，先是答案框，三节以上自动出目录，然后各节、问答、深绿的下载框（下载按钮 + 上手文档）、脚注。署名 Sky Lu（链创始人页，`rel="author"`）、
  发布和更新日期、阅读时间。页面外壳（导航、页脚、语言菜单）和别的页面共用 `template.mjs` 的 `shell`。
- **SEO**：`seo.mjs` 的 `headTags` 是所有页面共用的一份 head。文章页 `og:type=article`、`article:published_time`，hreflang 只列这篇真有的语言，
  `x-default` 是英文版（没有英文版就是第一种）。JSON-LD：`Article`（`datePublished`、`dateModified`、作者 Person、发布方 Organization，这两个节点写全，
  因为回答引擎一次只读一页）、`BreadcrumbList`（首页 → Guides → 文章）、`FAQPage`（就是页面上的问答）。栏目页是 `CollectionPage` + `ItemList`。
  已发布的文章和栏目页进 `sitemap.xml`，`lastmod` = `updated`。
- **已有的文章**（2026-11-11）：`edit-video-with-claude-code`（英、简中、繁中、日、德、西）、`edit-video-with-codex`（英、简中、繁中、日）、
  `claude-code-vs-codex-for-video-editing`（对比，英、简中、日）、`remove-pauses-and-filler-words`（英、简中、繁中、日）、
  `auto-subtitles-on-mac`（英、简中、繁中、日）、`translate-subtitles-on-mac`（英、简中、繁中、西）、
  `ai-voiceover-in-your-own-voice`（英、简中、繁中、日）、`video-editing-mcp-servers`（清单，英、简中、繁中、日）。
  **对比那篇只写量到的**：数字来自[两个客户端各 8 个任务的实测](../reports/2026-11-11-mcp-guide-final-measurement.md)，各跑一次、测试素材，文中写明；
  `tests/guides.test.mjs` 把文章表格里的每个秒数和调用次数同那份报告逐个对，报告没变而文章的数字变了就红。声音那篇不写积分数字（App 在每一步收费前显示价格）。选题证据和后面的题目在第一轮报告里。
  清单那篇写了五家别的工具：只写它们自己页面上的事实、不排名次、写明我们没做过对比测试。**文章先发文字版**（用户定），不配录屏。
  新增 `capcut-alternatives-for-mac`（替代品，繁中、日、英）、`ai-video-editors-for-mac`（清单，繁中、日、英）和 `skycut-vs-descript`（对比，英）。
  前两篇各列五个其他编辑器；Descript 对比只比较两款产品。官方出处分别保存在各篇 `index.js`，不写未实测的快慢与精度，明确免费水印、硬件、界面语言和 AI 数据流限制。
  `screen-record-mac-with-system-audio` 和 `upscale-video-to-4k-on-mac`（教程，英、繁中、日）按录屏生命周期、画质提升、导出设置和实际界面撰写。
  区分录屏原档 / 放大素材与 Free 时间线导出的水印；放大需积分、源范围含余料最多 30 秒、源最高 30 fps，手动完成先比较、AI 完成自动换源。4K 成片另需核对 Auto 首段画布与实际输出尺寸，不能承诺不存在的固定比例 4K 控件。

## 样式表的先后

2026-11-11 起的规矩，来由见
[首页在手机和 iPad 上版面全乱](../bugfixes/2026-11-11-website-phone-layout-lost-to-stylesheet-order.md)。

- **构建不保留样式表挂的顺序。** Vite 按「哪些页面共用」把样式表分块，页面先加载共用的那块。
  现在所有页面都挂 `base.css` 和 `responsive.css`，它俩成一块、排在最前；首页 / 文档 / 隐私的
  `home` + `showcases` + `pricing` 是另一块，文章页的 `guides` 又是一块。
- 所以**每份样式表自带自己的平板 / 手机规则**，写在文件末尾、它们要覆盖的规则后面。
  `responsive.css` 只调 `base.css` 管的东西（页眉、容器、文档页、页脚）；首页的在 `home.css` 末尾。
  不许指望「某个文件排在另一个文件后面」来让特异性相同的规则生效。
- 给某类页面换一组样式表、加新的样式表之后，分块会全站重算：看一眼别的页面在手机和 iPad 宽度下的样子。
- 守卫：`tests/css-cascade.test.mjs`（`responsive.css` 的选择器不许出现在页面自己的样式表里；
  按模板顺序和按构建的顺序排都没有覆盖规则在前）；`npm run check:seo` 在构建之后按每个页面实际加载的
  样式块再核对一遍；`scripts/check-hero-browsers.mjs` 每一格带版面哨兵（桌面首屏两栏，iPad 和手机一栏）。

## 小字读得清

2026-11-11 起的规矩，来由见
[官网的小字](../bugfixes/2026-11-11-website-small-text-contrast-headings-font-shift.md)。

- **手机上（≤ 600 px）看得见的字不小于 12 px。** 演示区的编辑器窗口是缩小的示意图：读的字放大到 12 px，
  放不下的（片段名、字幕条里的字）在手机上不显示，别再往下缩字号。新加的小字要么在手机档给到 12 px，
  要么在手机档 `display:none`；手机上整块收起来的部分登记在 `tests/legibility.test.mjs` 的 `HIDDEN_ON_PHONES`。
- **演示区的灰绿小字用 `--show-quiet`**，它在用到的每种底色上都 ≥ 4.5:1。新加一种文字颜色，
  要在 `tests/legibility.test.mjs` 的 `QUIET_TEXT` 里登记它压在哪块底色上（或写进 `NOT_QUIET_TEXT`
  说明它不是压在已知底色上的字）。要表示「还没轮到 / 结束了」，别把整行的不透明度降到字读不清，
  也别在脚本里改状态字的不透明度（样式表的检查看不见）。
- **示意图里的标签不是标题。** 编辑器窗口里的「素材库」「检查器」是 `p.show-panel-title`；
  页面的标题层级不许跳级（h2 后面不许直接 h4）。
- **行高写死，别留 `normal`。** `normal` 取字体自己的度量，网页字体换上来那一下高度会变；
  首屏的网格里一行变高，3D 场景就跟着挪。
- **演示播放时版面不跳**：手机上对话窗的步骤说明固定三行高，结束语占同样的高度；用户那句话逐字打出来时，
  气泡里一直放着整句（没打到的部分在 `.show-untyped` 里、不可见），气泡从第一个字起就是最终的大小。
  会逐步出现的文字都这样做：先占好最终的位置，再显示。
- 守卫：`tests/legibility.test.mjs`（按样式表算手机上的字号、演示区的对比度、四语言各页的标题层级、
  首屏标签的行高、脚本不改状态字的不透明度、打字时气泡里留着整句）。浏览器里量的那一半是手动的：

  ```sh
  npm run build
  npx -y -p playwright@1.65.0 node scripts/check-legibility-browsers.mjs --engines chromium,webkit,firefox
  ```

  它看手机上 8 个页面有没有不到 12 px 的字、标题跳不跳级，演示区静止和每一步的对比度，
  手机上浮层出不出预览框、对话窗高度变不变（打字的那 1.8 秒里每 0.2 秒量一次，再加每一步），以及挡掉网页字体前后首屏的框一不一样。
  和首屏那个脚本一样：全程无头、只在 Mac 上、Playwright 不是依赖、不进 CI（两个脚本共用 `scripts/pinned-playwright.mjs`）。

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

首屏质感与渐进增强验收（2026-11-11）：合入当天的 main（含 GEO 与 Guides）后 110 项网站测试
（首屏新增 12 项）、`npm run stamp:pages`（四个首页记为当天）、本地生产构建、12 个语言页面的
SEO 产物审计、`scripts/check-guards.sh` 通过。`scripts/check-hero-browsers.mjs` 在无头 Chromium、
WebKit、Firefox 上 63 项（36 格、9 项版面框、18 项回退行为）全部通过；临时让减少动态效果不换回静图，
脚本变红。静图与实时第一帧平均每通道差 0.6 级，版面框不动。
性能在本地构建上用无头 Chromium（真 GPU）各量 5 次取中位数，改前 → 改后：桌面 LCP 120 → 92 ms、
TBT 47 → 5 ms、CLS 0；手机（CPU 4 倍降速 + 慢 4G）LCP 3556 → 1248 ms、TBT 173 → 75 ms、CLS 0.0017 不变。
JS 增加 4.7 kB（gzip），CSS 少 0.9 kB；静图一次访问只下一张（桌面 2x 屏 82 kB 的 AVIF，手机 33 kB）。
对比图、视频和原始记录在 `/private/tmp/skycut-hero-3d/`。用户正在录屏，全程无头，没有开过窗口；
未创建云端预览或部署。真的 Safari、iPhone、iPad 和 Edge 没有实测。

人工：桌面、iPad、手机宽度；主标题最多两到三行；语言、菜单、播放、下载、三种登记；
实时场景与烤好的静图（没有 WebGL、关 JavaScript）、在系统设置里切换减少动态效果、暂停、滚出视口停止渲染；
浏览器控制台和网络错误；
首屏四段真实画面轮播、当前卡片移到最前、播放头/时间码同步、完整 360° 与背面透光、
暂停后画面和转台一起停止、手机/桌面切换仍为同一播放进度；
三个 AI 演示的阶段定位、重播、自动 / 手动切换七种字幕、暂停与后台恢复、
720p 到 1080p 换源之后保持同一播放位置；真实手机 / iPad 硬件仍需最后验收。
正式配置表格后由用户用自有邮箱核对实际新增、重复登记合并选择和退订 / 删除流程。
品牌邮箱两域名实际收发另行验收；模拟测试不能当成真实写表或投递证据。
