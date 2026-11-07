# Windows 版 SkyCut：讨论记录（暂缓）

- 日期：2026-11-07。用户、Claude、Codex（在 cmux 里）讨论了一轮。用户逐条答完问题后定：**Windows 版日后再讨论，现在都待定**，先把讨论记下来。
- 状态：只有讨论。没写代码，没建 Windows 环境，也没在 Windows 上编译或实测过任何东西。这不是排期，也不是对外的兼容承诺。
- 怎么读：下次讨论从第三节「还没定的」开始。第四节是 Codex 的技术草稿，Claude 审过，和第二节冲突时以第二节为准。
- 数字的口径：
  - 代码行数按 2026-11-07 的 main（`4339db7`）统计。
  - 版本、许可、文件大小是当天从上游读到的元数据，出处见第五节。
  - 标「预算」的是还没打包实测的估计。
  - 过一段时间再讨论时，版本和大小要重新查。

## 一、用户定的目标

- 只专注做 Windows 版 SkyCut，功能和 Mac 版一模一样。
- 一个安装包包含全部东西，装完打开就能用，不再额外下载什么。用户可能缺的东西都要考虑进去，不能出现「还缺某某」。
- Mac 自带、Windows 没有的，用免费开源的替代，或者我们自己重写。
- 开发只有一台 M1 Mac，测试要有办法。

## 二、已经定的（2026-11-07）

用户答完问题后说「别的按照你的建议来」，所以下面这些算定了。没定的是配音、翻译，以及第三节列的几件。

1. **不做第二套代码。**
   - 抽成能在 Windows 上编译的 Swift 模块的，是不依赖苹果界面和系统的部分：时间线模型与编辑规则、联动、撤销、工程文件、导出计划、音频引擎的渲染核心、字幕与文字规则、MCP 工具逻辑。
   - Mac 保留 SwiftUI 外壳，Windows 另做外壳和平台层。
   - 理由：同一条规则只有一处实现，两套代码迟早漂。
2. **Mac 的新功能照常做，不冻结。** 慢下来的原因不是人手：代码由 Codex 写，额度够。原因有三个：
   - 一块代码正在搬进共享模块时，要改它的新功能会撞车，得错开几天。
   - 搬代码难免碰出 bug，用户天天用 Mac 版，会先撞上。
   - 共享模块建好以后，新功能的逻辑只写一份，但界面要 Mac 和 Windows 各做一遍、各测一遍。

   做法：代码按小 PR 一块一块搬；共享模块建好之后，新逻辑直接写进共享模块。Codex 草稿第十一节末尾「Mac 不继续加新功能」那句作废。
3. **两边打通：工程能在 Mac 和 Windows 上互相打开。**
   - **字体随包带一套开源的**，Mac 和 Windows 都带：
     - 选字体时这套排在最前面，标「两边都能用」，新工程默认用它。
     - 本机的系统字体照样能选。只有 Mac 才有的（苹方、冬青黑体等），旁边标一句「只在 Mac 上有」。
     - 随包带多少还没定，见 3.3。
   - **另一边打开工程缺字体时，提示一次**：列出缺哪些，推荐换成哪个（比如苹方 → 思源黑体），可以选「替换」或「先不换」。
     - 选「先不换」：暂时用替代字体显示，工程里记的仍是原字体，回到 Mac 上照样是原样。
     - 选「替换」：字宽会变，字幕折行可能跟着变。
   - **AI 打开工程不弹框**（AI 那一路不许弹窗），在工具结果里说缺了哪些字体。
   - **素材跟着工程走**：工程从 Mac 拷到 Windows 时素材一起拷，SkyCut 按相对位置重新找回来。
   - **生成的东西存在工程里**：字幕和词的时间、译文、配音音频、识别框，哪边生成的，到另一边打开都一样。两边的识别、翻译、配音模型不同，所以新生成的结果允许不一样。
4. **字幕识别：Windows 用 whisper.cpp 加 Whisper large-v3-turbo 的 Q5_0 压缩版，随包带上。**
   - 这个模型 574 MB，MIT 许可，约 99 种语言。Mac 继续用苹果的语音识别。
   - 风险在逐词时间：它没有苹果的准，生成字幕的切法要重新调。
   - 在没有独立显卡的电脑上，转写速度要实测。
5. **签名：先不签名，直接发。**
   - Mac 那种自签证书在 Windows 上没用。Mac 上有用，是因为录屏等权限按签名记账；Windows 的权限不按签名记。
   - Windows 也不认自签证书：要装进受信任的根证书才认，得用管理员权限，也不该让用户做。自签和没签一样。
   - 不签名的后果：用户双击安装包，会看到「Windows 已保护你的电脑」，点「更多信息 → 仍要运行」就能装，只拦这一次。偶尔有杀毒软件误报，可以免费提交给微软复核。
   - 上线时再决定加不加微软商店（见 3.7）。
6. **ARM 先不做。**
   - 第一版只出 x64。
   - ARM 的 Windows 笔记本能转译运行 x64 程序（Prism），只是剪辑和 AI 这种重活会慢一些。
   - 原生 ARM 版以后再说。
7. **支持 Windows 10 和 Windows 11。** Windows 10 的一般支持在 2025-10-14 已经结束，我们照样支持。Windows 10 的测试环境从哪来，见 3.8。
8. **Pro 的台数不分 Mac 还是 Windows，一共 2 台，价格不变。** 一台 Mac 加一台 Windows 正好够。要改三处，等 Windows 版快发布时再改：
   - 官网文案「2 台 Mac」改成「2 台电脑」。
   - 体验版「每台 Mac 一次」改成「每台电脑一次」。
   - Sky Studio 服务器要认 Windows 的机器号。机器号在 Windows 上从哪取、怎么去重，要和 Sky Studio 另定合同。Mac 机器号的算法和盐不变。
9. **测试：**
   - **用用户房间里那台 Windows 电脑。** 它是 Windows 11，还没激活，没有独立显卡，能从 Mac 登录。它正好代表最低配的用户。
   - **这台电脑保持「干净」。** 不装开发工具，编译放在 GitHub Actions 的 Windows runner 上（仓库公开，所以免费）。它只用来装和测，每次测到的都是普通用户装完的样子。
   - **开 OpenSSH 服务端，保持开机、保持登录。** 性能和录屏在它自己的屏幕上验，不在远程桌面里验：远程桌面会换掉显示设备、DPI 和声音路由。
   - **NVIDIA 显卡那条加速路线，发布前测一天。** 借一台或租一台云电脑都行。
   - **这台 M1 不开 Windows 虚拟机。** 它只有 16 GB 内存，硬盘只剩约 12 GB（98% 满）。
   - **MCP 冒烟沿用 `scripts/gui-smoke/mcpclient.py`。** 它用读线程加队列，断线时明确失败。不用旧的 `scripts/gui-smoke/mcp-client/client.py`：它用 `select.select` 读管道，在 Windows 上不能用。
10. **Codex 的额度够用**，不用为额度排期。

## 三、还没定的（下次从这里开始）

### 3.1 配音（用户还没想好）

| 来源 | Mac 现在 | Windows 可选 | 随包大小 | 说明 |
| --- | --- | --- | --- | --- |
| Kokoro（开源，Apache-2.0） | CoreML 版，用到时从我们的 R2 下载，约 333 MB（含注音模型和词典） | ONNX 版随包：FP32 325.5 MB、FP16 163.2 MB、量化 92.4 MB，另有声音文件 28.7 MB | 0.1–0.35 GB | 支持英语、中文、日语、西班牙语、法语、意大利语、葡萄牙语、印地语。我们自己写的 Swift 注音能复用，但英语词典以外的词那段（`KokoroBartG2P`）要从 CoreML 换成 ONNX 推理 |
| 系统声音 | macOS 自带的声音（没下载 Kokoro 时用） | Windows 自带的声音 | 0 | Windows 有哪些声音，取决于装了哪些语言包，不能保证 |
| Sky Studio 云端 | 声音和克隆，扣积分 | 同一套 | 0 | 要联网，要 Key |

- **Claude 的倾向：**随包带 Kokoro，列出 Windows 自带的声音，再加 Sky Studio 云端。
- **不带 eSpeak NG。**它开源、语种多，但声音很机器，不如不给。Codex 提过拿它当多语种的保底。

### 3.2 翻译（用户还没想好）

用户说可以接受走云端、收费，也问有没有小的开源模型能在本地跑，太大就算了。

| 方案 | 大小 | 许可 | 质量与代价 |
| --- | --- | --- | --- |
| Sky Studio 云端，扣积分 | 0 | — | 质量最好；要在 Sky Studio 加一个翻译接口 |
| M2M100 418M（CTranslate2 INT8） | 约 0.5–1 GB（原始权重 1.936 GB） | MIT | 一个模型覆盖约 100 种语言、能两两互译，质量明显不如苹果的 |
| Opus-MT，一对语言一个模型 | 每对原始约 300 MB（en→zh 是 312 MB），INT8 约 80 MB | 要按模型逐个核（en→zh 是 Apache-2.0） | 中英这类常用的几对质量不错；语言一多，要的模型就多 |
| 小型开源大模型（如 Qwen 的 1–4B） | 1–2.5 GB | 按模型核 | 质量更好，在没有显卡的电脑上慢 |
| MADLAD-400 3B | 原始 11.8 GB | Apache-2.0 | 太大 |
| NLLB | — | CC-BY-NC，不能商用 | 排除 |

**Claude 的建议：先做实验。**

- 如果 1 GB 以内能把常用的几对翻好，就随包带上，免费离线用。其余语言和要求更高质量的走云端。
- 效果不够好，就只走云端。

翻译离线还是云端，也决定了「装完就能用」覆盖到哪一步：离线是现在 Mac 版就有的能力。

### 3.3 字体随包带多少

下面的数字是 2026-11-07 从 GitHub 读到的单个文件大小，全部是 OFL 许可。

| 字体 | 文件 | 大小 |
| --- | --- | ---: |
| 思源黑体（Noto Sans CJK），简繁日韩、全部字重在一个可变字体里 | `NotoSansCJK-VF.otf.ttc` | 32.7 MB |
| 　只要简体中文的可变字体 | `NotoSansSC-VF.otf` | 15.1 MB |
| 　只要简体中文的一个固定字重 | `NotoSansSC-Regular.otf` / `-Bold.otf` | 8.3 / 8.5 MB |
| 思源宋体（Noto Serif CJK），简繁日韩、全部字重 | `NotoSerifCJK-VF.otf.ttc` | 57.5 MB |
| 霞鹜文楷（手写感），一个字重 | `LXGWWenKai-Regular.ttf`（v1.530） | 25.9 MB |
| 得意黑（标题字） | v2.0.1 压缩包（里面有几种格式，单个文件更小） | 5.8 MB |
| 拉丁字母的标题 / 正文字体，每款一个可变字体（Inter 0.88、Montserrat 0.74、Playfair 0.30、Oswald 0.17、Bebas Neue 0.06 MB 等） | Google Fonts 的 `ofl/` | 每款 0.1–0.9 MB，20 款约 10 MB |

- **核心一套约 45 MB**：思源黑体全套加约 20 款拉丁字体，够字幕、新工程默认和常用标题。
- **加上思源宋体、霞鹜文楷、得意黑，约 130 MB。**
- 安装包里会压缩一些，实际增量略小于这个数。

**Claude 的建议：**

- 核心那套两边都随包。Mac 的 DMG 因此大约多 45 MB。
- 其余字体：
  - Windows 也随包，守住「不用再下载」。
  - Mac 做成按需下载，像音乐库一样。在 Mac 上打开一个用了这些字体的工程时，后台自动下载，不弹替换。
- 用户也可以定成两边都全带，或者两边都只带核心。

要用 R6 探针核对一件事：libass（烧录用的）能不能从可变字体里选出粗体。不能的话，就改带几个固定字重的文件，每个约 8 MB，上面的大小要重算。

### 3.4 声音场景（用户倾向：Mac 不变，Windows 单独做一份）

- **Mac 现在的做法：**用苹果自带的效果单元，链是 AUNBandEQ / AUDistortion / AUReverb2 / AUDelay（见 [声音场景](../architecture/sound-scenes.md)）。
- **可以这样做：**Mac 一点不动，Windows 用我们自己写的效果器。
  - 均衡、削波、延迟都有标准公式，拿同一段测试信号在两边渲染、对着调，能做到非常接近。
  - 室内、室外的混响是苹果不公开的算法（AUReverb2），只能近似：混响长短和亮度调得像，但听起来不会完全一样。我们在合成音效里已经有一个 Freeverb，可以拿来当底子。
- **两边共用：**场景列表、滑杆、参数换算、效果在链里的位置、余音越过段尾、响度补偿。
- **代价：**
  - 同一个工程里用到混响的场景，Mac 和 Windows 听起来略有不同，成片也一样。
  - 以后加一个场景或调一个场景，两边各做一遍，各听一遍。
- 用户在讨论中提出这条，还没最后拍板。另一条路是两边都换成我们自己的效果器，这样两边一样，但 Mac 现在的声音会变，要用户重新听一遍点头。

### 3.5 中日文的分词（字幕在哪儿折行）

Mac 的字幕折行按词边界走（`SubtitleCJKWords`，靠系统的 NaturalLanguage 分词）。Windows 上没有这个分词器，换成 ICU 之类，分出来的词会有出入，同一个工程两边字幕的折行可能不一样。有三条路：

- 两边都换成同一个随包的分词器。Mac 的折行会变，要重新看一遍。
- Mac 不变，接受偶尔折得不一样。
- 把折行点存进工程。但编辑之后要重算，重算出来仍会不同。

### 3.6 音乐、音效库要不要随包

- Mac 上是用到时才从 R2 下载。本机清单有 79 首音乐，341.8 MB（CC-BY 3.0）；63 个音效，11.2 MB（自有）。
- 按「不再额外下载」全带上，安装包要多约 350 MB。
- 也可以照 Mac 那样按需下载：素材库本来就是要浏览、要挑的东西。

### 3.7 微软商店

上线时决定。先要核实四件事：

- 商店里的 App 能不能用我们自己的 Dodo 收款。商店对应用内购买有政策。
- Claude 桌面版、Claude Code、Codex 能不能启动商店装的 App 里带的 `skycut-mcp.exe`。商店 App 的安装目录是受保护的，可能要靠「App 执行别名」。
- 个人开发者注册现在是不是免费。
- 安装包大小有没有问题。商店写明的 MSIX 包上限是 25 GB。

### 3.8 测试机的具体情况

- 型号、CPU、内存、硬盘还剩多少。
- **家庭版还是专业版。**没激活也能在「设置 → 系统 → 系统信息」里看到。这会影响远程测试的方式和「干净安装」怎么测：
  - 家庭版不能被远程桌面登录，也没有 Windows 沙盒和 Hyper-V。
  - OpenSSH 家庭版也能用。
- **没激活的影响：**桌面有水印，个性化设置改不了，截图里会带水印。不影响装软件、系统更新和测试。
- 现在用什么从 Mac 登录它；平时有没有人用；能不能一直开着；能不能正常访问 GitHub。
- **Windows 10 的测试环境从哪来。**GitHub 的 Windows runner 是 Windows Server，不是 Windows 10。可以另找一台 Windows 10，或者在这台上开虚拟机（家庭版没有 Hyper-V，可以用 VirtualBox）。

### 3.9 要等探针结果才能定的技术选择

- **Windows 界面：**优先验证 C# WinUI 3 外壳，经窄 C ABI 调 Swift 核心。Qt Quick 或 Avalonia 用同一个场景比一次（4.4、R3）。
- **预览合成器：**预览要自己写一个 D3D11 合成器，用 FFmpeg 解码。按 AGENTS.md 工程原则第 1 条，自写合成器这类重量级方案要先征得用户同意，开工前要用户点头。
- **安装包格式：**Inno Setup 单个 exe（6.5.2 起上限接近 4 GB）、MSIX，还是完整的 ZIP，看 R10 实测的大小。

## 四、技术方案草稿（Codex，2026-11-07）

这一节是 Codex 只读调查后写的讨论稿，Claude 审过。它没在 Windows 上编译或实测过，和第二节冲突时以第二节为准。

### 4.1 方向

保留一份 Swift 编辑核心，Mac 继续用现有的 SwiftUI / AppKit 外壳。Windows 优先验证的组合是：

- C# + WinUI 3 外壳；
- 窄 C ABI；
- Swift 核心；
- C/C++ 媒体适配层。

「不做第二套代码」具体指：模型、命令、联动、裁切、工程格式这些产品规则不复制。两个系统的窗口、录屏、声音设备、GPU 呈现仍然要各写各的。

```text
Mac SwiftUI/AppKit                   Windows C#/WinUI 3
        │                                   │ 窄 C ABI
        └──────── 共享 Swift 编辑会话 ────────┘
                    │
     工程模型、编辑事务、联动、撤销、时间 / 几何、导出计划
     字幕切条 / 折行规则、文字动画、任务状态、MCP 业务路由
                    │
             小而具体的平台接口
                    │
  Mac 媒体 / 系统适配      Windows C/C++ 媒体 / 系统适配
```

按真实职责逐个建模块：

- `SrtFlowCore`：分词改成明确的接口。
- 编辑核心：TimelineState / EditClip、选区、命令、联动、撤销、文档编解码、工程注册表。
- 渲染计划：每个时刻画哪些源、摆在哪、怎么裁、动画、转场、滤镜、盖一块、叠放顺序。预览和导出读同一份计划。
- 音频核心：增益、环、流的几何、混音、推子、电平、限幅、响度。
- AI 应用层：MCP 参数和路由、任务。
- 平台后端：解码、纹理、文字、录屏、设备、文件身份、密钥、IPC。平台后端不承载联动、裁切这些规则。

**最重要的分离点是 `VideoEditProject`。**它持有播放器、预览、窗口、UndoManager、定时器和界面订阅。不能把它原样编进 Windows，再给缺的 AppKit 类型套一圈假类型。

### 4.2 代码规模（按文件分类的启发式，不是实际可共享率）

| SrtFlow 主目标 | 文件 | 行数 | 占比 |
| --- | ---: | ---: | ---: |
| 逻辑候选（只用 Foundation / 自有模块等） | 317 | 36,243 | 37.45% |
| 界面（导入 SwiftUI 或 AppKit 视图子类） | 159 | 30,271 | 31.28% |
| 平台实现与混合 | 179 | 30,261 | 31.27% |
| 合计 | 655 | 96,775 | 100% |

| 其他目标 | 文件 | 行数 | 现状 |
| --- | ---: | ---: | --- |
| SrtFlowCore | 40 | 6,910 | 已独立，但导入了 NaturalLanguage 和 CoreGraphics |
| SrtFlowMCPKit | 30 | 3,412 | 协议和清单大部分能用，`MCPUnixSocket` 导入了 Darwin |
| SrtFlowKokoro | 14 | 2,536 | 注音规则能复用，4 个文件依赖 CoreML |
| SrtFlowMCP | 3 | 351 | 启动、定位 App 和 IPC 要适配 |

- 逻辑候选里，仍有 80 个文件（11,463 行）直接引用 `VideoEditProject`，81 个文件引用 `TimelineState`，两组有重叠。整个主目标有 194 个文件引用 `VideoEditProject`。所以共享的第一件事是切断对大对象的依赖，不是搬目录。
- 抽完以后，主目标大约有 **4–5 万行**进共享逻辑。这是人工判断，要在 P0、P1 逐个文件确认。
- 主目标里各苹果框架的 import 次数（按文件数）：SwiftUI 150、AppKit 78、CoreGraphics 75、AVFoundation 70、UniformTypeIdentifiers 17、Combine 16、ImageIO 14、CoreText 14、CryptoKit 8、CoreImage 8、ScreenCaptureKit 6、CoreMedia 6、Translation 4，其余都在 2 个以内。

### 4.3 类型依赖：不要一律重写

| 类型 / 机制 | 主目标文件数 | 处理 |
| --- | ---: | --- |
| CGSize / CGRect / CGPoint | 110 / 59 / 54 | 开源 Foundation 里就有这些几何值，不用一见 CG 前缀就重写。去掉多余的 CoreGraphics import 即可；C ABI 上不直接暴露 Swift 的内存布局 |
| CMTime | 26 | 不进共享接口。抽出时间值、帧值和换算合同，两头各自转换；保留现有的截断、边界和接缝容差，别趁机全改成四舍五入 |
| CGImage / CGAffineTransform | 14 / 9 | 图像换成带尺寸、行距、像素格式、色域和所有权的缓冲；矩阵换成自己的纯值 |
| Color / NSColor / NSFont | 40 / 5 / 3 | 界面颜色留在外壳；工程里存 RGBA 和字体描述 |
| ObservableObject / Published | 49 / 49 | Windows 上默认没有 Combine。共享模型用值，加上带版本号的变化事件；Mac 和 C# 各自接界面订阅 |
| UndoManager | 4 | 共享的命令、事务、逆操作管撤销语义；Mac 的 UndoManager 只接菜单和系统交互 |
| AVAudioPCMBuffer / AVPlayer | 9 / 14 | 只留在 Mac 的媒体层 |

- **Observation 在 Windows 的 Swift 里有**，以 `swiftObservation.dll` 的形式出现，但它不会自动接到 C# 的属性通知。
- Foundation 的 `Process` 有 Windows 分支。URLSession、ICU、文件权限、Locale、Unicode 正则要实际核对。

**怎么分小 PR 搬，且不碰坏 Mac：**

1. 建 Windows 的编译和检查入口，固定工具链，Mac 的语言模式不变。
2. 让 SrtFlowCore 独立：把分词做成接口，去掉多余的 CoreGraphics import。
3. 逐族抽纯值：时间、摆放、关键帧、渐变、链接组、段的显隐。
4. 抽联动和编辑命令，把 `perform` / `liveApply` 收尾那一处接过去，然后才抽工程会话和撤销。
5. 依次迁移文档与重链接、导出计划、音频、MCP 业务。
6. 每一步跑 `scripts/check-local.sh`，CI 的 `check-all` 同时等 Mac 和新加的 Windows 检查。现有的 Mac 检查不能因为 Windows 暂不支持就跳过。
7. 搬代码时同步改手写的源文件清单和接线守卫，确认生产路径真的调用了新模块。

### 4.4 Windows 界面技术比较

体积指安装目录里界面和运行库那一部分的预算，不含媒体库、Swift、模型和字体。

| 方案 | 成熟度与维护 | 部署与体积预算 | 判断 |
| --- | --- | --- | --- |
| Swift + WinUI 3（swift-winrt） | 语言统一，但 WinRT 绑定、构建、IDE 的责任都在我们身上。swift-winrt 仍在维护（BSD-3），配套的 swift-winui 已于 2025-10-16 归档 [S05] [S06] | 60–150 MB，另加 Swift | 只作探针候选 |
| **C# WinUI 3 + Swift（C ABI）** | 微软主推的路线，文档和样例多，AI 代理好维护；要定好 ABI 和生命周期 | .NET 与 Windows App SDK 都自包含，140–250 MB [S07] | **优先验证** |
| Qt Quick / QML + C++ + Swift | GPU 场景图适合时间线；C++ / QML / Swift 三种边界更复杂；LGPLv3 / GPLv3 逐模块选 [S08] [S09] | 70–160 MB | 第二候选 |
| Avalonia（C#）+ Swift | MIT，自绘和 Skia 适合密集图形；能在 Mac 上开发外壳 [S10] | 90–180 MB | 想在 M1 上调界面时，值得同场比较 |
| WebView2 + Canvas | JS 与原生之间的消息、输入法、拖放、GPU 资源共享容易有成本；固定版运行时超过 250 MB [S11] | 250 MB 以上 | 不选 |

- 哪个方案都没证明过 60fps。R3 用同一场景比：500 个可见块、共 2000 块、8 条轨、带缩略图和波形。目标是 60Hz 下交互帧 p95 ≤ 16.7 ms，没有持续超过 50 ms 的停顿。
- 不逐块把 JSON 从 Swift 发给 C#，也不每帧序列化整条时间线：一次提交一个命令，按版本号批量返回变化。音视频帧不经过托管数组来回复制。
- C ABI 至少要规定：不透明的工程句柄、版本、UTF-8 加长度、谁分配谁释放、错误码、取消句柄、回调的寿命和调用线程。Swift 的 MainActor 不能当成就是 WinUI 的 DispatcherQueue。

### 4.5 苹果框架的替代

许可要锁定版本、配置和转换产物后出 SBOM 再定。模型的许可不能从推理库的许可推出来。FFmpeg 启用 GPL 组件就按 GPL 分发，不用 `--enable-nonfree` [S12]。SkyCut 是 AGPL-3.0，GPL 组件（如 x264）兼容。

| import（主目标文件数） | Windows 上用什么 | 许可 | 随包增量（预算） | 能不能和 Mac 一样 |
| --- | --- | --- | --- | --- |
| SwiftUI 150 | C# WinUI 3（备选 Qt Quick / Avalonia） | 各自条款 | 见 4.4 | 功能和交互对等，控件像素不同 |
| AppKit 78 | WinUI / Win32：窗口、多工程、菜单、对话框、剪贴板、拖放 | 系统 API | 1–5 MB | 操作语义一致 |
| CoreGraphics 75 | Foundation 几何值 + 自己的矩阵和轮廓 + D3D11 / Direct2D 或 CPU 栅格化 | 系统 + 自有 | 1–10 MB | 固定坐标、预乘、色域、采样规则后可比 |
| AVFoundation 70 | libavformat / libavcodec / libswresample、D3D11VA、WASAPI 或 miniaudio、自己的呈现时钟 | FFmpeg 按构建是 LGPL 或 GPL；miniaudio 可选 MIT-0 [S12] [S13] | FFmpeg 共享库 + CLI 共 80–180 MB | 时间和结构能一致；解码、重采样、变速要做参考测试 |
| UniformTypeIdentifiers 17 | 共享的类型 / MIME 表 + Win32 文件关联 | 系统 | 很少 | 语义一致 |
| Combine 16 | 共享的变化事件，Windows 上接 INotifyPropertyChanged | 自有 | 很少 | 状态变化相同 |
| ImageIO 14 | WIC 保底 + FFmpeg；需要时补 libheif / libtiff / lcms2 | 各自 [S59] [S65] [S66] | 5–30 MB | EXIF 朝向、ICC、透明、HEIC 不能漏 |
| CoreText 14 | 画面文字用 HarfBuzz + FreeType；字幕用 libass；DirectWrite 只给界面 | MIT / FTL / ISC [S15] [S16] [S17] | 5–20 MB，字体另算 | 要逐像素一样，两边得用同一字体文件和同一套排版绘制 |
| CryptoKit 8 | swift-crypto 或 BCrypt（主要是 SHA-256） | Apache-2.0 / 系统 [S38] | 2–10 MB 或 0 | 用标准测试向量逐字节核对 |
| CoreImage 8 | LUT / 模糊 / 马赛克用共享参数 + HLSL，另有 CPU 参考 | 自有 | 计入图形 | 纯黑保护、格子原点、偶数框、边缘外延、预乘必须相同 |
| ScreenCaptureKit 6 | Windows.Graphics.Capture + WASAPI loopback + 麦克风，FFmpeg 编码 | 系统 [S18] | 很少 | 来源、区域、时长、恢复、收尾对等 |
| CoreMedia 6 | 共享的帧和时间值，边界上换成 100 ns 或 QPC | 自有 | 很少 | 保留截断合同 |
| Translation 4 | 见 3.2 | — | 见 3.2 | 译文不会和苹果的逐字相同 |
| CoreML（Kokoro） | ONNX Runtime，CPU 保证能用，DirectML 只作可选加速 | ORT 是 MIT，Kokoro 是 Apache-2.0 | ORT 官方 zip 约 83 MB（未裁剪） | 同一份源权重能接近，不保证逐采样相同 |
| Security 2 | 凭据管理器 / DPAPI | 系统 | 很少 | 密钥不明文放进 APPDATA |
| AudioToolbox 2 | 共享 DSP + WASAPI；保音调变速用 SoundTouch 或自己写；声音场景见 3.4 | SoundTouch 是 LGPLv2.1 [S14] | 1–5 MB | 苹果效果单元的参数相同，不等于听起来相同 |
| Vision 1 | ONNX Runtime + 模型：文字识别 RapidOCR / Paddle，人脸 YuNet，人 NanoDet，分类 MobileNet，显著性另选 | Apache-2.0 / MIT，按具体权重核 [S33] [S34] | 80–250 MB 起 | 结果和苹果的不同，要单独做质量验收；不用 Windows.Media.Ocr（依赖装了哪些语言包） |
| Speech 1 | whisper.cpp + 随包模型（见第二节第 4 条） | MIT | 574 MB | 文字和词时间都和苹果不同 |
| PDFKit 1 | PDFium（不带 V8 / XFA） | BSD 式 [S36] | 10–30 MB | 抽出的文字顺序要回归 |
| NaturalLanguage 1（Core 里另有 1） | ICU 的文本边界 / 字典（见 3.5） | Unicode 许可 [S35] | 25–50 MB，别和 Swift 自带的 ICU 重复打包 | 中日文分词和苹果不同 |
| IOKit 1 | Windows 的机器号（见第二节第 8 条） | 系统 + 服务器合同 | 很少 | 计数语义要单独设计 |
| Accelerate 1 | 自己的 FFT，或 KissFFT | 自有 / BSD-3 [S60] | 不到 1 MB | 缩放、窗函数会影响节拍检测，要参考向量 |
| 其他（os、Darwin、Synchronization、CoreVideo、Observation、QuartzCore） | ETW、WinSDK / CRT / Job Object / 命名管道、Swift 自带模块、D3D11 纹理 | 系统 / 自有 | 很少 | 信号、PID、权限、终止的语义不同，不能机械替换 |

### 4.6 预览、声音、文字的要点

**预览是最大的未知数。**

- Mac 的预览用 AVPlayer 和系统合成，导出走 FFmpeg 滤镜图，Windows 上没有能整套替换的东西。
- 做法：先把两边共用的渲染计划抽出来，Windows 先用 FFmpeg 软解加软件参考合成，证明所有效果和时间账都对，再做 D3D11 呈现、硬解和 GPU 合成的快路径。
- 解码用随包的 FFmpeg，CPU 解码永远可用，D3D11VA 不行就退回 CPU。编码用 libx264 打底，NVENC / QSV / AMF 只是加速选项。
- 不依赖用户去商店买 HEVC 扩展，也不依赖 Media Foundation。Windows N 版不一定装了媒体组件，要专门测 [S61]。
- 没有能用的显卡时，WARP（系统的软件 D3D）能保证有画面，但保证不了 4K 多轨 60fps [S19]。
- MLT、GStreamer、libplacebo 在 P0 当备选评估，前提是能直接用共享的渲染计划，不为了复用引擎再建一套时间线。

**声音不只是把输出换成 WASAPI。**

- 环、增益、混音、电平是我们自己写的，能共享。
- 但 `AudioSegmentReader` 用 AVAudioFile / AVAudioConverter 读和重采样，`AudioTimeStretchReader` 用 AVAudioUnitTimePitch 做变速，`VideoEditSoundSceneDSP.swift` 用苹果的效果单元做声音场景，混音和离线渲染也接在 AVAudioEngine 的图上。
- Windows 用 FFmpeg 解码和重采样，变速用 SoundTouch 或自己写，设备用 WASAPI / miniaudio。
- 音频回调里不碰 C# 的 GC，不分配、不加锁、不发界面通知。主时钟从声音设备的采样计数来。

**文字和字幕。**

- Windows 的字幕预览可以直接用 libass 画同一份 ASS，和烧录天然一致。折行照旧由我们算好，写成 `\N`，用 WrapStyle 2。
- 画面文字的编辑光标、墨迹框、字距、字体回退、老虎机数字、动画、旋转、点击范围，仍然要从 CoreText 移植过来。

### 4.7 系统集成与 MCP

| 能力 | Windows 上怎么做 |
| --- | --- |
| 工程和素材定位 | 相对路径优先；跨盘、UNC、文件身份、重链接；旧 Mac 的绝对路径留作找回线索 |
| 文件选择、拖放、剪贴板 | 原生对话框、IDataObject / CF_HDROP、自己的剪贴板格式；中文名、长文件列表、Windows 的修饰键都要测 |
| 删到废纸篓 | IFileOperation 进回收站；进不了回收站时不许静默永久删除 |
| 文件类型 | `.skycut` 和老扩展名，按当前用户注册；看得见的叫 SkyCut，身份前缀沿用 SrtFlow |
| 设置和缓存 | `%APPDATA%` 放可迁移的配置，`%LOCALAPPDATA%\SrtFlow` 放缓存和日志；卸载不删工程 |
| 密钥 | 凭据管理器 / DPAPI；备份和日志里不许漏 |
| 机器号 | MachineGuid 代表一次系统安装；SMBIOS UUID 可能重复或为零；虚拟机克隆、换主板、重装、双系统都会影响计数。来源、归一化、失败时怎么办，要和 Sky Studio 定合同 |
| AI 通道 | 优先命名管道：名字带当前用户的 SID，正式版和测试版分开；显式 DACL，拒绝远程，校验客户端身份 [S40] |
| MCP 小程序 | 随包带 `skycut-mcp.exe`：stdio JSON-RPC、UTF-8、stdout 只放协议；不需要 Node / Python |
| 子进程 | 用 Job Object 管自己起的子进程，不按名字结束用户别的 ffmpeg |
| 看门狗 | QPC 心跳、ETW、DbgHelp / Minidump；挂起线程取上下文要极短，不照搬 arm64 读栈帧那一套 |

「连接 AI」在 Windows 上的配置位置：

| 客户端 | 位置 | 注意 |
| --- | --- | --- |
| Claude 桌面版 | `%APPDATA%\Claude\claude_desktop_config.json` 的 `mcpServers` | 商店版要实测；写本地 exe 的绝对路径 [S54] |
| Claude Code | `%USERPROFILE%\.claude.json`（用户范围）、项目里的 `.mcp.json`；优先用 `claude mcp add` | `settings.json` 管权限，和服务登记分开 [S55] |
| Codex | 用户目录的 `.codex/config.toml`，尊重 `CODEX_HOME` | 原生 Windows 和 WSL 的 HOME 不同 [S56] |

不用 `npx` / `uvx` 启动小程序，否则又要 Node / Python，第一次还要联网下载。

### 4.8 模型：已核实的版本和大小

大小是十进制（1 GB = 10^9 字节），指模型仓库里的单个文件。ONNX Runtime 是上游压缩包的大小，最终的运行库会更小。没有下载、也没有跑过这些组件。

| 项目 | 版本 | 大小 | 许可与出处 |
| --- | --- | ---: | --- |
| Swift Windows 工具链 | 6.4.1（2026-10-12）；只作 P0 的基线 | 运行库大小待实际收集 | [S01] |
| whisper.cpp | v1.9.5（2026-10-06） | 运行库自己编译后再量 | MIT [S21] |
| Whisper large-v3-turbo Q5_0 | `ggml-large-v3-turbo-q5_0.bin`，commit `5359861c` | 574,041,195 字节 | MIT [S22] |
| 同一模型未量化 | `ggml-large-v3-turbo.bin` | 1.625 GB | 同上 |
| M2M100 418M | commit `55c2e61b`，`pytorch_model.bin` | 1.936 GB | MIT [S23] |
| Opus-MT en→zh | commit `408d9bc4` | 312 MB | Apache-2.0 [S24] |
| MADLAD-400 3B | commit `fa184c67` | 11.76 GB | Apache-2.0 [S25] |
| NLLB-200 distilled 600M | 只作排除项 | 2.46 GB | CC-BY-NC-4.0 [S26] |
| Kokoro ONNX v1.0 | commit `1939ad2a` | FP32 325.5 MB、FP16 163.2 MB、量化 92.4 MB、55 个声音文件 28.7 MB | Apache-2.0 [S29] [S30] |
| 当前 Mac 的 Kokoro 包 | 本机清单 version 1 | 333.4 MB（含注音模型和词典） | 见 THIRD-PARTY-NOTICES |
| ONNX Runtime | v1.31.1（2026-10-26） | Windows x64 的 zip 82.9 MB | MIT [S31] [S32] |

**Whisper 的注意点：**

- 上游仍把词级时间戳标为 experimental [S20]。
- 探针至少包括：中文、英语、中英混合、粤语、短句、长停顿、片头音效和音乐、噪声、变速素材，以及 L16 这类真素材。
- 词对齐的目标先定成「首尾误差中位数 ≤ 80 ms、p95 ≤ 200 ms」，这是待确认的目标。
- `SubtitleLanguageDetection.minimumConfidence = 0.80` 是照苹果的输出标定的，Whisper 的分数刻度不同，要重新标定。
- 缓存的键要带上引擎、权重 hash、语言和对齐版本。

**Kokoro 的注意点：**

- CoreML 编译好的 `.mlmodelc` 不能直接交给 ONNX Runtime，要从可重现的源权重转换。
- 要核对四样东西和现有管线是否一致：输入 ID、声音向量、随机相位、每个 token 的时长输出。

### 4.9 安装包里有什么、多大（预算）

| 内容 | 大小 |
| --- | ---: |
| Windows 外壳、Swift 核心、原生后端、WinAppSDK / .NET / Swift / CRT / ICU 运行库 | 250–450 MB |
| FFmpeg、编码器、字幕文字、图片、PDF | 100–220 MB |
| Whisper turbo Q5 | 574 MB（核实） |
| 翻译模型（如果离线，M2M100 INT8） | 0.6–1.0 GB |
| Kokoro、声音、注音、词典 | 0.35–0.40 GB |
| 文字识别、检测、分类、显著性 | 0.10–0.40 GB |
| 字体 | 见 3.3（45–130 MB） |
| 音乐 / 音效（如果随包） | 342 + 11 MB |
| 封面、清单、署名、余量 | 50–150 MB |

全部随包、翻译用 INT8 时，预算是安装后占用 3–5 GB、下载 2–4 GB。不带离线翻译、不带音乐库，大约少 1–1.3 GB。量化过的权重压缩不了多少，最终要实际打包量。

### 4.10 「装完就能用」清单

- **运行库全部随包：**
  - Swift 实际要用的全部 DLL，用 PE import 递归扫，再在干净机器上启动验证，不能只拷 `swiftCore.dll`。
  - .NET 和 Windows App SDK 都要自包含，不许偷偷引入另一个要另装的 MSIX 依赖 [S07]。
  - CRT 按微软的再分发条款带上，不从 System32 随便拷 [S41]。
  - ICU、TLS 根证书、图片格式、重采样、字幕字体都要算进依赖闭包。
- **不用会在第一次运行时去下东西的组件**（`pip install`、`npx`、`huggingface download`）。模型从随包的只读路径读。
- **路径和权限：**
  - 程序目录只读也能跑，缓存写当前用户的目录。
  - 不需要管理员。不能指望有创建符号链接的权限，Mac 字体工作目录用软链的做法要改。
  - 中文、带空格、emoji 的用户名都要能跑；UTF-8 与 UTF-16 互转、盘符、UNC、只读目录、超长路径、文件被占用、OneDrive 占位文件都要有用例。
- **显卡和 CPU：**
  - 硬解、D3D、模型加速失败时，各自退回 CPU。
  - 发布产物不用 `-march=native`，否则没有 AVX2 的 CPU 会直接崩。
  - 8 GB 内存时，模型按需加载、用完释放。
- **高分屏：**Per-Monitor DPI V2，在 100 / 125 / 150 / 200% 和混合 DPI 下都要测。触控板捏合和 Ctrl + 滚轮分开测。
- **快捷键：**⌘ 对应 Ctrl，但不能全局机械替换。Ctrl+Alt / AltGr、输入法、系统快捷键要按命令表一条条处理。
- **N 版：**纳入离线安装和编解码检查，不让用户补 Media Feature Pack。
- **卸载：**删掉程序和它自己的缓存、配置、凭据，要有明确的选项；绝不删用户的工程、素材和别的 AI 客户端的东西。

### 4.11 安装格式与签名的事实

- 一个安装包不等于所有东西塞进一个 exe：装完是一个目录，里面有 DLL、模型、字体，这是正常的。装到 `%LOCALAPPDATA%\Programs\SkyCut`，不弹 UAC。
- 普通 NSIS 的单个安装包上限约 2 GB [S63]。Inno Setup 从 6.5.2 起支持接近 4 GB 的单个 Setup.exe，6.7.4 发布于 2026-10-28，许可允许商用 [S44] [S45]。更大的只能走 MSIX（商店写明的上限是 25 GB）[S46]，或者完整的 ZIP。
- 签名相关：
  - EV 证书已经不能保证第一次下载就不被 SmartScreen 拦，和 OV 一样要攒信誉。Azure Artifact Signing（原 Trusted Signing）也不保证 [S42]。
  - Artifact Signing 个人目前只收美国和加拿大；组织的名单里没有中国大陆 [S43]。
  - 商店会重新签名提交的 MSIX；走商店的 MSI / EXE，签名仍是发布者的事 [S42]。
- 第一次离线安装必须完整；之后的更新可以是在线增量，失败能回退。

### 4.12 测试

| 台架 | 能验什么 | 不能据此签收 |
| --- | --- | --- |
| GitHub Actions 的 Windows x64 runner（公开仓库免费 [S47]） | Swift 核心的编译和断言、C ABI、工程往返、命名管道、CPU 解码和合成、离线音频、小样模型、安装包的依赖扫描 | 真显卡的硬解和编码、桌面录屏、声卡、触控板、多显示器 |
| 用户那台没有独显的 Windows 11 | 真性能（低端）、录屏、loopback 和麦克风、设备切换、DPI、安装和卸载、杀毒、SmartScreen、MCP 端到端 | NVIDIA / AMD 的路线 |
| 借或租的 N 卡电脑（发布前） | NVENC、CUDA / DirectML 加速 | — |

- 不用 M1 上的 Windows ARM 虚拟机：没空间，也不能代表 x64。
- 远程桌面上看到的不能当物理屏幕的结果。SSH 只用来构建、跑 CPU / MCP 检查和取日志；截图、UIA、录屏由桌面会话里的代理做。
- **两边结果怎么比，分层来：**
  1. 模型层：同样的命令，比规范化之后的 JSON。
  2. 时间层：用色块、编号帧、脉冲音证明帧数、首尾、接缝、变速、静帧、总采样数完全一致。
  3. 像素层：同分辨率、SDR、同字体、软件参考渲染，导无损中间结果逐帧比。
  4. 声音层：同一份 PCM 加共享 DSP 逐采样比。用苹果效果单元的那几组只能按容差比（见 3.4）。
  5. AI 层：比可重复性，用人工标注集比质量，不要求两个模型结果相同。
  6. 安装层：干净、非管理员、断网、没有 VS / Python / Node / 额外语言包的系统，从正式安装包开始把本地功能全跑一遍，同时扫描加载失败和意外的网络请求。
- 合成的夹具可以进公开仓库。L16 这类用户素材只在本地或私有台架上用，不上传到公开的 Actions。
- 拖动、捏合、输入法、快捷键让路、外部拖放、窗口焦点要用 UIA 和真实输入去测。自绘的时间线要提供 AutomationPeer 和稳定的测试标识 [S64]。

### 4.13 先做的风险探针（P0，2–4 周，都还没做）

| 探针 | 最小产物 | 通过标准，或失败后要决定什么 |
| --- | --- | --- |
| R1 Swift 可移植性 | 在 Windows runner 上编译 SrtFlowCore 并跑 SrtFlowCoreChecks；列出 NaturalLanguage / CoreGraphics 的阻塞；宏、原子、Process、URLSession 各一个最小程序 | 只挪目标就能编、能跑；失败就按 API 列出边界，不大面积打桩 |
| R2 C ABI 与生命周期 | 同一个工程经 C# 建、改、撤销、释放；回调、取消、错误、Unicode、大数据 | 和 Swift 直接调用结果相同；反复建销无持续内存增长 |
| R3 界面选型 | WinUI 和一个备选跑同一个 500 / 2000 块场景，带波形、DPI、捏合、UIA | 公布 p50 / p95 / 最长帧、拖动延迟和内存 |
| R4 解码与合成 | FFmpeg 读 H.264 / HEVC / 透明图 / 旋转素材；软件参考 + D3D 合成层，加转场、LUT、模糊 | 和 Mac 的时间、几何、颜色对得上；硬解和退回 CPU 都跑到；N 版不补包 |
| R5 声音 | WASAPI 输出、离线同 PCM、44.1 → 48k、变速、场景、设备切换 | 分清能共享的混音和苹果效果单元的差异（见 3.4） |
| R6 文字、字体、分词 | 同一字体下的中英日、阿拉伯文、emoji、字体回退、逐词高亮、数字动画、预览和烧录 | 量出 CoreText、FreeType、libass 的差异；libass 能不能从可变字体选字重（见 3.3） |
| R7 Whisper 词时间 | 固定语料 + 人工标注；Q5、未量化、小模型对照；接进真实的字幕联动 | 质量、时间误差、CPU 耗时和内存达标，否则加对齐模型 |
| R8 离线翻译 | 导出 Mac 的语言方向表；M2M100 转成 CT2 INT8 | 实测大小、内存、延迟、质量，列出语言差集（见 3.2） |
| R9 Kokoro 与识别 | ONNX 推理的词时长和注音；文字、人脸、人、分类、显著性各一例 | 每项都有许可清楚的权重和真实输出 |
| R10 离线大包 | 实际的运行库闭包 + 模型，打成用户级的包；在干净的 Win11 / Win10 / N 版上断网安装、卸载 | 不补下载、不要管理员、不缺 DLL；实测大小，决定 exe、MSIX 还是 ZIP |
| R11 录屏、IPC、客户端 | 真桌面录屏 + loopback + 麦克风、崩溃后的残片；命名管道；三个 AI 客户端 | 来源、控制窗口不入镜、收尾都对；真实客户端连得上 |
| R12 工程与云端身份 | Mac 工程到 Windows 重链接、保存，再回 Mac；Windows 机器号和 Sky Studio 的合同 | 不丢字段；不误开体验、不误计台数；Mac 的身份不变 |

### 4.14 阶段与工作量（有效人周，不是 AI 生成代码的时间）

| 阶段 | 人周 | 结束时拿到什么 |
| --- | ---: | --- |
| P0 风险与合同 | 2–4 | R1–R12 的结论；功能、语言、字体清单；许可和包体；测试台架 |
| P1 共享核心 | 6–10 | 编辑模型、事务、联动、撤销、工程、MCP 核心在 Mac 和 Windows 上同测；Mac 的生产代码调用新模块 |
| P2 Windows 媒体后端 | 10–16 | 预览、seek、音频主时钟、离线混音、字幕 / 文字 / 形状、转场滤镜、优化媒体、导出 |
| P3 Windows 完整外壳 | 7–11 | 工作台、检查器、时间线手势、多工程、快捷键、输入法、文件交互、主题、设置、可访问性 |
| P4 本地智能与语言 | 6–10 | 识别、翻译、配音、文字识别、主体、分类、显著性都接进业务路径 |
| P5 系统、云端、安装 | 4–7 | 录屏与恢复、账号与机器号、AI 客户端、离线单包、签名、更新、卸载 |
| P6 对等验收与硬化 | 6–10 | 完整功能矩阵、真机性能报告、长工程、坏素材、崩溃恢复、两边成片对比 |
| 合计 | **41–68** | 另留 20–30% 缓冲，约 49–88 人周 |

- 一个主要实现者串行推进，按 12–20 个月准备；两个互补的实现者部分并行，约 7–12 个月。
- 这不会因为多开几个 AI 窗口就自动变快：瓶颈在 Windows 真机验证和媒体后端。
- 11-01 那次「6–12 个月」的粗估，没算全部依赖和模型随包、两边一致这些约束。

## 五、出处（访问日期 2026-11-07）

- S01：https://www.swift.org/install/windows/
- S05：https://github.com/thebrowsercompany/swift-winrt
- S06：https://github.com/thebrowsercompany/swift-winui
- S07：https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/self-contained-deploy/deploy-self-contained-apps
- S08：https://doc.qt.io/qt-6/licensing.html
- S09：https://doc.qt.io/qt-6/qtquick-visualcanvas-scenegraph.html
- S10：https://github.com/AvaloniaUI/Avalonia
- S11：https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution
- S12：https://github.com/FFmpeg/FFmpeg/blob/master/LICENSE.md
- S13：https://github.com/mackron/miniaudio
- S14：https://www.surina.net/soundtouch/license.html
- S15：https://github.com/libass/libass/blob/master/COPYING
- S16：https://github.com/harfbuzz/harfbuzz/blob/main/COPYING
- S17：https://freetype.org/license.html
- S18：https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture
- S19：https://learn.microsoft.com/en-us/windows/win32/direct3d11/overviews-direct3d-11-devices-create-warp
- S20：https://github.com/ggml-org/whisper.cpp
- S21：https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.5
- S22：https://huggingface.co/ggerganov/whisper.cpp/blob/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin
- S23：https://huggingface.co/facebook/m2m100_418M
- S24：https://huggingface.co/Helsinki-NLP/opus-mt-en-zh
- S25：https://huggingface.co/google/madlad400-3b-mt
- S26：https://huggingface.co/facebook/nllb-200-distilled-600M
- S29：https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/tree/1939ad2a8e416c0acfeecc08a694d14ef25f2231
- S30：https://huggingface.co/hexgrad/Kokoro-82M
- S31：https://github.com/microsoft/onnxruntime/releases/tag/v1.31.1
- S32：https://github.com/microsoft/onnxruntime/blob/main/LICENSE
- S33：https://rapidai.github.io/RapidOCRDocs/latest/en/model_licenses/
- S34：https://github.com/opencv/opencv_zoo
- S35：https://github.com/unicode-org/icu/blob/main/LICENSE
- S36：https://pdfium.googlesource.com/pdfium/+/refs/heads/main/LICENSE
- S38：https://github.com/apple/swift-crypto
- S40：https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights
- S41：https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files
- S42：https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options
- S43：https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart
- S44：https://jrsoftware.org/files/is6-whatsnew.htm
- S45：https://jrsoftware.org/files/is/license.txt
- S46：https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/app-package-requirements
- S47：https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- S54：https://modelcontextprotocol.io/docs/2026-07-28/develop/connect-local-servers
- S55：https://code.claude.com/docs/en/mcp
- S56：https://learn.chatgpt.com/docs/config-file/config-basic
- S59：https://github.com/strukturag/libheif/blob/master/COPYING
- S60：https://github.com/mborgerding/kissfft/blob/master/COPYING
- S61：https://support.microsoft.com/en-us/windows/experience/platform-variants/media-feature-pack-for-windows-n
- S63：https://nsis.sourceforge.io/Failure_when_compiling_a_big_installer
- S64：https://learn.microsoft.com/en-us/windows/apps/design/accessibility/accessibility-overview
- S65：https://github.com/mm2/Little-CMS/blob/master/LICENSE
- S66：https://gitlab.com/libtiff/libtiff/-/blob/master/LICENSE.md

其他出处：

- 字体大小：GitHub 上的 `notofonts/noto-cjk`（`Sans/Variable/OTC`、`Serif/Variable/OTC`、`Sans/Variable/OTF/Subset`、`Sans/SubsetOTF/SC`）、`lxgw/LxgwWenKai` 的 v1.530 发行、`atelier-anchor/smiley-sans` 的 v2.0.1 发行、`google/fonts` 的 `ofl/`。
- 音乐和音效的数量、大小：本机缓存的清单（音乐 2026-09-22、音效 2026-09-30），不是确认过的最新目录。
