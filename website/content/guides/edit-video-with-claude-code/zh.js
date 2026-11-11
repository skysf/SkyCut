// 简体中文。界面名称照 App 的简体中文界面：连接 AI、撤销这一轮、请求批准、全部权限。
export default {
  title:'怎样用 Claude Code 剪视频（Mac 教程）',
  description:'Claude Code 自己打不开剪辑软件。在 Mac 上把它连到 SkyCut，它就能在真正的时间线上剪辑、加字幕、导出，每一步你都看得见、改得了。',
  heading:'怎样在 Mac 上用 Claude Code 剪视频',
  answer:'Claude Code 能剪视频，前提是给它一个能操控的剪辑软件。在 Mac 上装好 SkyCut，填入你的 Sky Studio Key，然后在 SkyCut 的设置里点 Claude Code 旁边的**连接**。之后 Claude 通过 SkyCut 自带的本机 MCP 服务器，在真正的多轨时间线上干活：看素材、剪掉口播里的停顿、加标题和字幕、导出成片；每一步你都看得见，可以调整，也可以撤销。SkyCut 只支持 Apple 芯片的 Mac 和 macOS 15 或更新的系统，没有 Windows 版和 Intel 版。',
  sections:[
    {heading:'Claude Code 剪视频：能做什么，不能做什么',blocks:[
      'Claude Code 是在终端里工作的 AI 智能体。它能读文件、跑命令，但它自己看不了视频、听不了声音，也没法摆放片段。要剪辑，就得有一个替它做这些事的工具。这样的工具有两类。',
      {list:[
        '**命令行工具。** Claude 写 FFmpeg 命令，或者运行一个封装了 FFmpeg 的技能。适合裁剪、拼接、转码这类对文件的处理。每改一次都要重新渲染一个文件，没有时间线可以让你打开来亲手修。',
        '**Claude 能操控的剪辑软件。** 软件通过 MCP（Model Context Protocol，给 AI 助手接工具的通用协议）把时间线开放出来。Claude 调用这些工具，每一处改动都落在时间线上，你可以播放、拖动、自己改。',
      ]},
      'SkyCut 属于第二类：一个原生的 Mac 剪辑软件，自带 MCP 服务器。下面就用它来做。',
    ]},
    {heading:'需要准备什么',blocks:[
      {list:[
        '一台 Apple 芯片（M1 或更新）的 Mac，系统是 macOS 15 或更新。要转写语音的功能（比如剪掉停顿、生成字幕）需要 macOS 26。',
        'SkyCut，免费下载。',
        'SkyCut Pro。AI 剪辑是 Pro 的功能。第一次把 SkyCut 连上你的 Sky Studio 账号时，开始 7 天 Pro 体验；每个账号一次，每台 Mac 一次。',
        'Claude Code，已经装好并用你自己的 Claude 套餐登录。SkyCut 不包含 AI 订阅。',
      ]},
      {note:'Claude 桌面版和 Codex 在同一个地方连接，用法一样。浏览器里的普通 ChatGPT 对话连不上，因为 SkyCut 的 MCP 服务器跑在你自己的 Mac 上。'},
    ]},
    {heading:'五步连上',blocks:[
      {steps:[
        ['安装 SkyCut','下载 SkyCut，打开磁盘映像，把 SkyCut 拖到「应用程序」。[上手文档](/zh/docs/#video)里有这一步的短视频。'],
        ['填入 Sky Studio Key','登录 Sky Studio，点右上角的头像，选 SkyCut，创建一个 Key。回到 SkyCut，打开设置里的 Sky Studio，把 Key 粘贴进去。这一步会开通 Pro 并开始体验。'],
        ['连接 Claude Code','在 SkyCut 里打开**设置 → 连接 AI**，点 Claude Code 旁边的**连接**。SkyCut 会替你运行 `claude mcp add`，把自己的 MCP 服务器登记到 Claude Code，并放行 SkyCut 的工具，这样 Claude 不用每调一个工具都停下来问你。'],
        ['新开一个 Claude Code 会话','Claude Code 在会话开始时加载 MCP 服务器。新开一个会话，输入 `/mcp`，列表里应该能看到 `skycut`。'],
        ['告诉 Claude 素材在哪','告诉 Claude 素材放在哪个文件夹、你想做成什么。SkyCut 会打开那个文件夹，导出的成片等新文件也存在那里。'],
      ]},
    ]},
    {heading:'第一次剪：可以这样说',blocks:[
      '用平常的话跟 Claude 说就行。下面每一句都对应 SkyCut 做得到的事，可以在同一个工程上一句接一句地说。',
      {prompt:'在 SkyCut 里打开 ~/Movies/interview 这个文件夹，把每段素材看一遍，告诉我各是什么内容。'},
      {prompt:'新建一个 16:9 的工程，用最好的三条素材搭一个粗剪。'},
      {prompt:'把口播那一段里的长停顿和口头禅剪掉。'},
      {prompt:'生成中文字幕，再加一条英文译文轨。'},
      {prompt:'在开头三秒加一个标题「南极」，然后导出 1080p 的 MP4。'},
      'Claude 还能给主体取景、让音乐踩点、叠加图层和动画、配旁白，并检查成片里有没有问题。如果不想一步步描述，可以直接点一种剪辑风格（比如纪录片或 vlog），让它自己规划。',
    ]},
    {heading:'检查 Claude 剪了什么',blocks:[
      '这正是要用真正的剪辑软件的原因。Claude 干活时，SkyCut 的工具栏会显示**AI 正在剪辑**，并跳到每一处刚改的地方。你随时可以点**停止**。',
      {list:[
        '每一次工具调用是一步撤销，按 ⌘Z 可以把 Claude 的改动一步步退回去。',
        'Claude 做完之后，**撤销这一轮**会把工程恢复到这一轮开始之前的样子。',
        '什么都没有锁住。你可以亲手拖一个片段、改一句字幕的时间、换一个标题，再让 Claude 接着做。',
        'SkyCut 有两种权限模式。**请求批准**会在 Claude 要做超出默认范围的事之前停下来问你，比如删除文件。**全部权限**直接执行，事后告诉你做了什么。两种模式下，付费生成的每日额度都照样生效。',
      ]},
    ]},
    {heading:'要花多少钱',blocks:[
      {table:{head:['项目','价格','说明'],rows:[
        ['SkyCut 免费版','{{free.price}}','完整的手动剪辑。导出带水印。不能让 AI 剪辑。'],
        ['SkyCut Pro','每月 {{pro.monthly}} 或每年 {{pro.yearly}}','AI 剪辑，导出无水印。第一次连接 SkyCut 时先有 7 天体验。'],
        ['Claude Code','你自己的 Claude 套餐','付给 Anthropic，不包含在 SkyCut 里。'],
        ['云端生成','可选','生成图片、视频、音乐和声音要用 Sky Studio 积分，另外购买。'],
      ]}},
      '价格不含税。两个方案各包含什么，见[价格表](/zh/#pricing)。',
    ]},
    {heading:'开始之前要知道的限制',blocks:[
      {list:[
        '只支持 Mac：Apple 芯片，macOS 15 或更新。SkyCut 不能在 Windows 和 Intel Mac 上运行。',
        'Claude 不像你那样「看」视频。它通过 SkyCut 的工具抽帧、听电平、读转写文字，所以发布之前请自己把成片看一遍。',
        '工程和素材留在你的 Mac 上；但工具返回给 Claude 的内容（比如画面帧和转写文字）会作为对话的一部分发给 Claude。',
      ]},
    ]},
    {heading:'用 Claude 剪视频的其他办法',blocks:[
      'SkyCut 不是唯一的路，哪条合适要看你做什么。',
      {list:[
        '**基于 FFmpeg 的技能。** 有开源的 Claude Code 技能封装了 FFmpeg 和 Whisper，在终端里运行。适合批量处理文件，不需要剪辑软件；没有时间线可以检查。',
        '**其他剪辑软件的 MCP 服务器。** 有社区项目通过 DaVinci Resolve 的脚本接口来操控它，支持 macOS、Windows 和 Linux；外部脚本需要付费的 Studio 版。',
      ]},
      '如果你用 Mac，并且希望 Claude 在一个你自己也能亲手操作的剪辑软件里干活，就选 SkyCut。',
    ]},
  ],
  faq:[
    ['Claude Code 自己能剪视频吗？','不能。Claude Code 处理的是文字和命令。要改视频，它需要 FFmpeg，或者一个它能操控的剪辑软件，比如 SkyCut。'],
    ['Claude 桌面版和 Codex 也能这样用吗？','能。SkyCut 的**设置 → 连接 AI**里，Claude 桌面版、Claude Code 和 Codex 各有一个连接按钮。其他客户端只要支持本机 stdio MCP 服务器也可以用。'],
    ['是免费的吗？','SkyCut 免费下载，手动剪辑不花钱。让 Claude 来剪需要 SkyCut Pro：7 天体验结束后每月 {{pro.monthly}} 或每年 {{pro.yearly}}，另外还要你自己的 Claude 套餐。'],
    ['Windows 能用吗？','不能。SkyCut 只支持 Apple 芯片的 Mac 和 macOS 15 或更新的系统。'],
    ['素材会被上传吗？','SkyCut 在你的 Mac 上剪辑，工程也留在本机。Claude 会收到工具为你的请求返回的内容，比如画面帧和转写文字。'],
  ],
};
