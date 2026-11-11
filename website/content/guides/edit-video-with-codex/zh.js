// 简体中文。界面名称照 App 的简体中文界面：连接 AI、撤销这一轮。
export default {
  title:'怎样用 Codex 剪视频（Mac 教程）',
  description:'Codex 能剪视频，前提是有一个它能操控的剪辑软件。在 Mac 上把它连到 SkyCut，它就能在真正的时间线上剪辑、加字幕、导出。',
  heading:'怎样在 Mac 上用 Codex 剪视频',
  answer:'Codex 能剪视频，但不是靠它自己：它需要一个能操控的剪辑软件。在 Mac 上装好 SkyCut，填入你的 Sky Studio Key，在**设置 → 连接 AI**里点 Codex 旁边的**连接**。SkyCut 会把自带的本机 MCP 服务器写进 Codex 的配置，之后 Codex 就能打开你的素材、搭时间线、裁剪、加标题和字幕、导出；每一处改动你都能在剪辑软件里看到，也能撤销。SkyCut 只支持 Apple 芯片的 Mac 和 macOS 15 或更新的系统，没有 Windows 版和 Intel 版。',
  sections:[
    {heading:'Codex 能剪视频吗？',blocks:[
      'Codex 是写代码的智能体。它能读文件、跑命令，自己看不了视频，也摆不了片段。让它碰视频有两种办法。',
      {list:[
        '**脚本和命令行工具。** Codex 写 FFmpeg 命令。裁剪、拼接、转码这类文件处理可以这样做；每改一次都重新渲染一个文件，没有时间线可以检查。',
        '**通过 MCP 操控剪辑软件。** 剪辑软件把时间线做成工具开放出来，Codex 来调用，改动落在时间线上，你可以播放，也可以亲手改。',
      ]},
      'SkyCut 是自带 MCP 服务器的原生 Mac 剪辑软件，所以本文走第二条路。同样的设置也适用于 Claude，见[用 Claude Code 剪视频](/zh/guides/edit-video-with-claude-code/)。',
    ]},
    {heading:'需要准备什么',blocks:[
      {list:[
        '一台 Apple 芯片的 Mac，系统是 macOS 15 或更新。要转写语音的功能（比如剪掉停顿、生成字幕）需要 macOS 26。',
        'SkyCut，免费下载。',
        'SkyCut Pro。AI 剪辑是 Pro 的功能。第一次把 SkyCut 连上你的 Sky Studio 账号时，开始 7 天 Pro 体验；每个账号一次，每台 Mac 一次。',
        'Codex，用你自己的 ChatGPT 套餐登录：命令行版、IDE 扩展或 ChatGPT 桌面 App 都可以。SkyCut 不包含 AI 订阅。',
      ]},
      {note:'浏览器里的普通 ChatGPT 对话连不上。SkyCut 的 MCP 服务器跑在你自己的 Mac 上，只有同一台 Mac 上的客户端才够得着。'},
    ]},
    {heading:'四步连上 Codex',blocks:[
      {steps:[
        ['安装 SkyCut','下载 SkyCut，打开磁盘映像，把 SkyCut 拖到「应用程序」。[上手文档](/zh/docs/#video)里有这一步的短视频。'],
        ['填入 Sky Studio Key','登录 Sky Studio，点右上角的头像，选 SkyCut，创建一个 Key。回到 SkyCut，打开设置里的 Sky Studio，把 Key 粘贴进去。这一步会开通 Pro 并开始体验。'],
        ['连接 Codex','打开**设置 → 连接 AI**，点 Codex 旁边的**连接**。SkyCut 先给 `~/.codex/config.toml` 存一份备份，再往里加一张 `[mcp_servers.skycut]` 表，并放行 SkyCut 的工具，这样 Codex 不会每次调用都来问你。命令行版、IDE 扩展和桌面 App 共用这一份配置，三处都能看到 SkyCut。'],
        ['新开一个 Codex 会话','新开一个会话输入 `/mcp`，或者在终端里运行 `codex mcp list`，列表里应该有 `skycut`。然后告诉 Codex 素材在哪个文件夹。'],
      ]},
    ]},
    {heading:'第一次剪：可以这样说',blocks:[
      '用平常的话说出你想要的结果。下面每一句都对应 SkyCut 做得到的事。',
      {prompt:'在 SkyCut 里打开 ~/Movies/demo 这个文件夹，告诉我每段素材里是什么。'},
      {prompt:'用这两段录屏剪一条 60 秒的竖屏短视频，保留我讲解功能的部分。'},
      {prompt:'把人声里的停顿和口头禅剪掉，然后生成字幕。'},
      {prompt:'在开头三秒加一个标题，导出 1080p 的 MP4，放在同一个文件夹里。'},
      'Codex 还能看单帧画面、听电平、读字幕、检查导出的成片，所以可以让它先自查一遍，你再看。',
    ]},
    {heading:'我们实测过的',blocks:[
      '2026 年 10 月我们自己测过：用 Codex 命令行版连 SkyCut，选的是一个小而快的模型、低推理强度。一次跑了十二步工具调用：打开文件夹和工程、看一帧画面、听十秒声音、读字幕、加一个标题、导出 480p 的草稿、再看一眼成片。全程约 60 秒，Codex 没有一次停下来要工具授权。',
      '那次测的是从连接到导出能不能走通，不代表审美：剪得好不好，取决于你选的模型，和你把要求说得多清楚。',
    ]},
    {heading:'检查与撤销',blocks:[
      {list:[
        'Codex 干活时，SkyCut 的工具栏显示**AI 正在剪辑**，并跳到每一处改动。点**停止**可以叫停。',
        '每一次工具调用是一步撤销；**撤销这一轮**会把工程恢复到这一轮开始之前。',
        '你随时可以亲手改，再让 Codex 接着做。',
      ]},
    ]},
    {heading:'要花多少钱',blocks:[
      {table:{head:['项目','价格','说明'],rows:[
        ['SkyCut 免费版','{{free.price}}','完整的手动剪辑。导出带水印。不能让 AI 剪辑。'],
        ['SkyCut Pro','每月 {{pro.monthly}} 或每年 {{pro.yearly}}','AI 剪辑，导出无水印。第一次连接 SkyCut 时先有 7 天体验。'],
        ['Codex','你自己的 ChatGPT 套餐','付给 OpenAI，不包含在 SkyCut 里。'],
        ['云端生成','可选','生成图片、视频、音乐和声音要用 Sky Studio 积分，另外购买。'],
      ]}},
      '价格不含税。两个方案各包含什么，见[价格表](/zh/#pricing)。',
    ]},
    {heading:'开始之前要知道的限制',blocks:[
      {list:[
        '只支持 Mac：Apple 芯片，macOS 15 或更新。SkyCut 不能在 Windows 和 Intel Mac 上运行。',
        'Codex 通过 SkyCut 的工具抽帧、读转写文字，并不是连续地看视频，所以成片请自己过一遍。',
        '工程和素材留在你的 Mac 上。工具返回的内容（比如画面帧和转写文字）会作为对话的一部分发给 Codex。',
      ]},
    ]},
  ],
  faq:[
    ['Codex 能剪视频吗？','能，只要它能操控一个剪辑软件。连上 SkyCut 之后，Codex 就在你 Mac 上真正的时间线里剪。只靠它自己，只能对文件跑 FFmpeg 这类命令行工具。'],
    ['浏览器里的 ChatGPT 也行吗？','不行。MCP 服务器在你的 Mac 本机，所以要用这台 Mac 上的 Codex：命令行版、IDE 扩展或桌面 App。'],
    ['用 Codex 还是 Claude Code？','两者在同一个地方连接，用的是同一套 SkyCut 工具。用你已经在付费的那个就行。我们没有发布过两者的质量对比。'],
    ['是免费的吗？','SkyCut 免费下载，手动剪辑不花钱。让 Codex 来剪需要 SkyCut Pro：7 天体验结束后每月 {{pro.monthly}} 或每年 {{pro.yearly}}，另外还要你自己的 ChatGPT 套餐。'],
    ['Windows 能用吗？','不能。SkyCut 只支持 Apple 芯片的 Mac 和 macOS 15 或更新的系统。'],
  ],
};
