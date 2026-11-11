// 繁體中文（台灣用語）。App 沒有繁體介面，按鈕名稱用簡體中文介面上的原文，括號裡說明。
export default {
  title:'如何用 Codex 剪片（Mac 教學）',
  description:'Codex 可以剪輯影片，前提是有一個它能操控的剪輯軟體。在 Mac 上把它連到 SkyCut，它就能在真正的時間軸上剪輯、上字幕、輸出。',
  heading:'如何在 Mac 上用 Codex 剪片',
  answer:'Codex 可以剪輯影片，但不是靠它自己：它需要一個能操控的剪輯軟體。在 Mac 上安裝 SkyCut，填入你的 Sky Studio Key，到**设置 → 连接 AI**（設定 → 連接 AI）按 Codex 旁邊的**连接**。SkyCut 會把內建的本機 MCP 伺服器寫進 Codex 的設定，之後 Codex 就能打開你的素材、建立時間軸、修剪、加標題和字幕、輸出；每一處修改你都能在剪輯軟體裡看到，也能復原。SkyCut 只支援 Apple 晶片的 Mac 與 macOS 15 以上，沒有 Windows 版和 Intel 版。',
  sections:[
    {heading:'Codex 可以剪輯影片嗎？',blocks:[
      'Codex 是寫程式用的 AI 代理。它能讀檔案、執行指令，自己看不了影片，也排不了片段。讓它處理影片有兩種方法。',
      {list:[
        '**腳本和指令列工具。** Codex 寫 FFmpeg 指令。裁切、合併、轉檔這類檔案處理可以這樣做；每改一次都要重新算出一個檔案，沒有時間軸可以檢查。',
        '**透過 MCP 操控剪輯軟體。** 剪輯軟體把時間軸做成工具開放出來，由 Codex 呼叫，修改會落在時間軸上，你可以播放，也可以親手改。',
      ]},
      'SkyCut 是內建 MCP 伺服器的原生 Mac 剪輯軟體，所以本文走第二條路。同樣的設定也適用於 Claude，請看[用 Claude Code 剪片](/zh-hant/guides/edit-video-with-claude-code/)。',
    ]},
    {heading:'需要準備什麼',blocks:[
      {list:[
        '一台 Apple 晶片的 Mac，系統為 macOS 15 以上。需要語音轉文字的功能（例如剪掉停頓、產生字幕）需要 macOS 26。',
        'SkyCut，免費下載。App 介面目前是英文、簡體中文和西班牙文，本文的按鈕名稱照簡體中文介面寫。',
        'SkyCut Pro。AI 剪輯是 Pro 的功能。第一次把 SkyCut 連上你的 Sky Studio 帳號時，會開始 7 天的 Pro 試用；每個帳號一次，每台 Mac 一次。',
        'Codex，用你自己的 ChatGPT 方案登入：指令列版、IDE 擴充功能或 ChatGPT 桌面 App 都可以。SkyCut 不包含 AI 訂閱。',
      ]},
      {note:'瀏覽器裡一般的 ChatGPT 對話無法連接。SkyCut 的 MCP 伺服器是在你自己的 Mac 上執行，只有同一台 Mac 上的用戶端才連得到。'},
    ]},
    {heading:'四個步驟連接 Codex',blocks:[
      {steps:[
        ['安裝 SkyCut','下載 SkyCut，打開磁碟映像檔，把 SkyCut 拖到「應用程式」。[安裝說明](/zh/docs/#video)（簡體中文）裡有這一步的短片。'],
        ['填入 Sky Studio Key','登入 Sky Studio，點右上角的頭像，選 SkyCut，建立一組 Key。回到 SkyCut，打開「设置」裡的 Sky Studio，把 Key 貼上。這一步會開通 Pro 並開始試用。'],
        ['連接 Codex','打開**设置 → 连接 AI**，按 Codex 旁邊的**连接**。SkyCut 會先替 `~/.codex/config.toml` 存一份備份，再加入一個 `[mcp_servers.skycut]` 表，並允許 SkyCut 的工具，這樣 Codex 不會每次呼叫都來問你。指令列版、IDE 擴充功能和桌面 App 共用這一份設定，三處都看得到 SkyCut。'],
        ['開一個新的 Codex 工作階段','開一個新的工作階段輸入 `/mcp`，或在終端機執行 `codex mcp list`，清單裡應該有 `skycut`。接著告訴 Codex 素材在哪個資料夾。'],
      ]},
    ]},
    {heading:'第一次剪片：可以這樣說',blocks:[
      '用平常講話的方式說出你想要的結果。下面每一句都對應 SkyCut 做得到的事。',
      {prompt:'在 SkyCut 打開 ~/Movies/demo 這個資料夾，告訴我每段素材裡是什麼。'},
      {prompt:'用這兩段螢幕錄影剪一支 60 秒的直式短影音，保留我講解功能的部分。'},
      {prompt:'把人聲裡的停頓和贅字剪掉，然後產生字幕。'},
      {prompt:'在開頭三秒加一個標題，輸出 1080p 的 MP4，放在同一個資料夾。'},
      'Codex 還能看單張畫面、聽音量、讀字幕、檢查輸出的成品，所以可以請它先自己檢查一遍，你再看。',
    ]},
    {heading:'我們實測過的',blocks:[
      '2026 年 10 月我們自己測過：用 Codex 指令列版連接 SkyCut，選的是一個小而快的模型、低推理強度。一次跑了十二步工具呼叫：打開資料夾和專案、看一張畫面、聽十秒聲音、讀字幕、加一個標題、輸出 480p 的草稿、再看一眼成品。全程約 60 秒，Codex 沒有一次停下來要求工具授權。',
      '那次測的是從連接到輸出能不能走通，不代表美感：剪得好不好，取決於你選的模型，以及你把需求說得多清楚。',
    ]},
    {heading:'檢查與復原',blocks:[
      {list:[
        'Codex 工作時，SkyCut 的工具列會顯示**AI 正在剪辑**，並跳到每一處修改。按**停止**可以叫停。',
        '每一次工具呼叫是一步復原；**撤销这一轮**（復原這一輪）會把專案恢復到這一輪開始之前。',
        '你隨時可以親手修改，再請 Codex 接著做。',
      ]},
    ]},
    {heading:'要花多少錢',blocks:[
      {table:{head:['項目','價格（美元）','說明'],rows:[
        ['SkyCut 免費版','{{free.price}}','完整的手動剪輯。輸出帶浮水印。不能讓 AI 剪輯。'],
        ['SkyCut Pro','每月 {{pro.monthly}} 或每年 {{pro.yearly}}','AI 剪輯，輸出無浮水印。第一次連接 SkyCut 時先有 7 天試用。'],
        ['Codex','你自己的 ChatGPT 方案','付給 OpenAI，不包含在 SkyCut 裡。'],
        ['雲端生成','選用','生成圖片、影片、音樂和聲音要用 Sky Studio 點數，另外購買。'],
      ]}},
      '價格未含稅。兩個方案各包含什麼，請看[價格表](/en/#pricing)（英文）。',
    ]},
    {heading:'開始之前要知道的限制',blocks:[
      {list:[
        '只支援 Mac：Apple 晶片，macOS 15 以上。SkyCut 無法在 Windows 和 Intel Mac 上執行。',
        'Codex 是透過 SkyCut 的工具擷取畫面、讀逐字稿，並不是連續地看影片，所以成品請自己看過一遍。',
        '專案和素材留在你的 Mac 上。工具回傳的內容（例如畫面和逐字稿）會作為對話的一部分傳給 Codex。',
      ]},
    ]},
  ],
  faq:[
    ['Codex 可以剪輯影片嗎？','可以，只要它能操控一個剪輯軟體。連上 SkyCut 之後，Codex 就在你 Mac 上真正的時間軸裡剪。只靠它自己，只能對檔案執行 FFmpeg 這類指令列工具。'],
    ['瀏覽器裡的 ChatGPT 也可以嗎？','不行。MCP 伺服器在你的 Mac 本機，所以要用這台 Mac 上的 Codex：指令列版、IDE 擴充功能或桌面 App。'],
    ['用 Codex 還是 Claude Code？','兩者在同一個地方連接，用的是同一套 SkyCut 工具。用你已經在付費的那個就可以。我們量過兩者做同樣任務的用時，但沒有評比過誰剪得比較好看。'],
    ['是免費的嗎？','SkyCut 免費下載，手動剪輯不用錢。讓 Codex 來剪需要 SkyCut Pro：7 天試用結束後每月 {{pro.monthly}} 或每年 {{pro.yearly}}（美元），另外還要你自己的 ChatGPT 方案。'],
    ['Windows 可以用嗎？','不行。SkyCut 只支援 Apple 晶片的 Mac 與 macOS 15 以上。'],
  ],
};
