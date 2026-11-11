// 简体中文。别家工具的说法都来自它们自己的页面，出处见 index.js。
export default {
  title:'视频剪辑 MCP 服务器怎么选：Claude 和 Codex 可用的 6 种',
  description:'让 Claude 或 Codex 通过 MCP 剪视频的六种办法，按支持的系统、服务器跑在哪里、时间线能不能亲手改来对比。',
  heading:'给 Claude 和 Codex 用的视频剪辑 MCP 服务器怎么选',
  answer:'视频剪辑 MCP 服务器没有唯一的「最好」，哪个合适取决于你在哪里剪。想让 Claude 或 Codex 在一个你自己也能上手操作的原生 Mac 剪辑软件里干活，就用我们做的 SkyCut。已经在用 DaVinci Resolve Studio 剪片的，有社区做的服务器可以驱动它。工作从录屏开始的，Tella 提供托管的服务器，Mac、Windows 和网页都能用。只是批量处理文件的话，基于 FFmpeg 的技能连剪辑软件都不需要。下面的表按支持的系统、服务器跑在哪里、有没有能亲手改的时间线，对比六种选择。',
  sections:[
    {heading:'视频剪辑 MCP 服务器是做什么的',blocks:[
      'MCP（Model Context Protocol）是给 AI 助手接工具的通用协议。视频剪辑 MCP 服务器把剪辑软件的动作（加片段、裁剪、加字幕、导出）变成 Claude 或 Codex 可以调用的工具：助手规划怎么剪，剪辑软件来执行。',
      '这些服务器在实际使用上有三点差别：能跑在哪些电脑上，素材是否留在你自己的机器上，以及结果是不是一条你能打开来亲手修的时间线。',
    ]},
    {heading:'六种选择一览',blocks:[
      {table:{head:['选择','支持的系统','服务器跑在哪里','能亲手改的时间线'],rows:[
        ['SkyCut','Apple 芯片的 Mac，macOS 15 或更新','本机，内置在 App 里','有，原生多轨时间线'],
        ['Palmier Pro','Apple 芯片的 Mac，macOS 26','本机，App 开着时运行','有，助手在 App 的时间线上剪'],
        ['ChatCut Desktop','macOS 13 或更新，Windows 10 或更新','本机，和桌面 App 在同一台电脑上','有，在桌面 App 里'],
        ['Tella','Mac、Windows 和网页','托管，需要登录','有，在 Tella 的编辑器里'],
        ['DaVinci Resolve 加社区服务器','macOS、Windows、Linux','本机，通过 Resolve 的脚本接口','有，在 Resolve 里'],
        ['基于 FFmpeg 的技能','装了 FFmpeg 的任何电脑','没有服务器，也没有剪辑软件','没有，每改一次渲染一个新文件'],
      ]}},
      '我们是 SkyCut 的开发方，没有拿其他工具和它做过对比测试。关于别家的那几行，写的是它们自己页面上的说法；这张表不是排名。',
    ]},
    {heading:'怎么选',blocks:[
      {list:[
        '**你用 Apple 芯片的 Mac，想要完整的剪辑软件再加上 AI。** SkyCut 和 Palmier Pro 都在本机运行，让助手在真正的时间线上干活。SkyCut 需要 macOS 15 或更新，Palmier Pro 需要 macOS 26。',
        '**你需要 Windows 或 Intel Mac。** ChatCut Desktop 和 DaVinci Resolve 支持。SkyCut 不支持。',
        '**你已经在用 DaVinci Resolve 剪片。** 社区服务器驱动的就是 Resolve 本身，工程原地不动。外部脚本需要付费的 Studio 版。',
        '**你的视频主要是录屏。** Tella 是录屏和剪辑工具，它的服务器还管录制和发布。它是托管的，所以工作要经过 Tella 的服务。',
        '**你只是要批量转码、裁剪或加字幕。** 封装了 FFmpeg 的技能在终端里就能做，不用装别的。',
      ]},
    ]},
    {heading:'决定之前要查清的事',blocks:[
      {list:[
        '**素材去了哪里。** 本机服务器跑在你自己的电脑上，托管服务器处理的是存在那个服务里的素材。不管哪种，都要看清 App 本身会上传什么；还要记住，工具返回的内容会交给助手。',
        '**你能不能接手。** 结果是剪辑软件里的时间线，你就能亲手修某一刀；结果只是渲染好的文件，每改一处都要重新渲染。',
        '**撤销怎么做。** 问清楚助手的改动是否进入剪辑软件正常的撤销记录，能不能把一整轮操作一次退回去。',
        '**动手之前会问什么。** 看有没有办法让助手在删文件、花钱生成之前停下来。',
        '**支持哪些助手。** SkyCut、Palmier Pro、ChatCut 和 Tella 都写明支持 Claude 和 Codex。Resolve 那个服务器的安装程序可以配置 Claude 桌面版、Claude Code 和 Codex 命令行版。',
      ]},
    ]},
    {heading:'SkyCut 是怎么做的',blocks:[
      {list:[
        '服务器在本机，随 App 一起安装。工程和素材留在 Mac 上。',
        '每一次工具调用是一步撤销，**撤销这一轮**可以把工程恢复到助手开始之前。',
        '**请求批准**模式下，助手要做超出默认范围的事之前会停下来；付费生成在任何模式下都有每日额度。',
        'Claude 桌面版、Claude Code 和 Codex 都是一个按钮连接。步骤见[用 Claude Code 剪视频](/zh/guides/edit-video-with-claude-code/)和[用 Codex 剪视频](/zh/guides/edit-video-with-codex/)。',
        'AI 剪辑属于 SkyCut Pro，每月 {{pro.monthly}} 或每年 {{pro.yearly}}；第一次把 SkyCut 连上你的 Sky Studio 账号时，开始 7 天 Pro 体验。',
      ]},
    ]},
  ],
  faq:[
    ['剪视频用哪个 MCP 服务器最好？','看你的电脑和剪辑软件。Apple 芯片的 Mac 上，SkyCut 和 Palmier Pro 给助手一条原生的时间线；Windows 上可以看 ChatCut Desktop 或 DaVinci Resolve；录屏类的可以看 Tella。'],
    ['这些除了 Claude，Codex 也能用吗？','SkyCut、Palmier Pro、ChatCut 和 Tella 两者都写明支持。DaVinci Resolve 的社区服务器除了 Claude，也可以配置给 Codex 命令行版。'],
    ['素材会离开我的电脑吗？','SkyCut 把工程和素材留在 Mac 上，只把工具返回的内容（比如画面帧和转写文字）发给助手。其他工具：本机服务器意味着助手连到的是你自己电脑上的剪辑软件，托管服务器处理的是存在那个服务里的素材。App 本身会上传什么，请看各家的条款。'],
    ['有能在 Windows 上用的吗？','有。ChatCut Desktop、Tella 和 DaVinci Resolve 都能在 Windows 上运行。SkyCut 只支持 Apple 芯片的 Mac 和 macOS 15 或更新的系统。'],
    ['一定要用 MCP 服务器吗？','只处理文件的话不用。Claude 或 Codex 可以直接运行 FFmpeg 来裁剪、拼接和转码。想要一个能在时间线上检查和修改的剪辑时，MCP 服务器才有用。'],
  ],
};
