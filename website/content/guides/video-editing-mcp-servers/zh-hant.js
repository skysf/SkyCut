// 繁體中文（台灣用語）。其他工具的說法都來自它們自己的頁面，出處見 index.js。
export default {
  title:'影片剪輯 MCP 伺服器怎麼選：Claude 和 Codex 可用的 6 種',
  description:'讓 Claude 或 Codex 透過 MCP 剪輯影片的六種方法，依支援的系統、伺服器在哪裡執行、時間軸能不能親手修改來比較。',
  heading:'給 Claude 和 Codex 用的影片剪輯 MCP 伺服器怎麼選',
  answer:'影片剪輯 MCP 伺服器沒有唯一的「最好」，哪一個適合取決於你在哪裡剪。想讓 Claude 或 Codex 在一個你自己也能動手操作的原生 Mac 剪輯軟體裡工作，就用我們製作的 SkyCut。已經在用 DaVinci Resolve Studio 剪片的，有社群製作的伺服器可以操控它。工作從螢幕錄影開始的，Tella 提供代管的伺服器，Mac、Windows 和網頁都能用。只是批次處理檔案的話，以 FFmpeg 為基礎的技能連剪輯軟體都不需要。下面的表格依支援的系統、伺服器在哪裡執行、有沒有能親手修改的時間軸，比較六種選擇。',
  sections:[
    {heading:'影片剪輯 MCP 伺服器是做什麼的',blocks:[
      'MCP（Model Context Protocol）是讓 AI 助理接上工具的通用協定。影片剪輯 MCP 伺服器把剪輯軟體的動作（加入片段、修剪、加字幕、輸出）變成 Claude 或 Codex 可以呼叫的工具：助理規劃怎麼剪，剪輯軟體負責執行。',
      '這些伺服器在實際使用上有三個差別：能在哪些電腦上執行，素材是否留在你自己的機器上，以及結果是不是一條你能打開來親手修的時間軸。',
    ]},
    {heading:'六種選擇一覽',blocks:[
      {table:{head:['選擇','支援的系統','伺服器在哪裡執行','能親手修改的時間軸'],rows:[
        ['SkyCut','Apple 晶片的 Mac，macOS 15 以上','本機，內建在 App 裡','有，原生多軌時間軸'],
        ['Palmier Pro','Apple 晶片的 Mac，macOS 26','本機，App 開啟時執行','有，助理在 App 的時間軸上剪'],
        ['ChatCut Desktop','macOS 13 以上，Windows 10 以上','本機，和桌面 App 在同一台電腦上','有，在桌面 App 裡'],
        ['Tella','Mac、Windows 和網頁','代管，需要登入','有，在 Tella 的編輯器裡'],
        ['DaVinci Resolve 加社群伺服器','macOS、Windows、Linux','本機，透過 Resolve 的腳本介面','有，在 Resolve 裡'],
        ['以 FFmpeg 為基礎的技能','裝了 FFmpeg 的任何電腦','沒有伺服器，也沒有剪輯軟體','沒有，每改一次就算出一個新檔案'],
      ]}},
      '我們是 SkyCut 的開發者，沒有拿其他工具和它做過比較測試。關於其他工具的那幾列，寫的是它們自己頁面上的說法；這張表不是排名。',
    ]},
    {heading:'怎麼選',blocks:[
      {list:[
        '**你用 Apple 晶片的 Mac，想要完整的剪輯軟體再加上 AI。** SkyCut 和 Palmier Pro 都在本機執行，讓助理在真正的時間軸上工作。SkyCut 需要 macOS 15 以上，Palmier Pro 需要 macOS 26。',
        '**你需要 Windows 或 Intel Mac。** ChatCut Desktop 和 DaVinci Resolve 有支援。SkyCut 不支援。',
        '**你已經在用 DaVinci Resolve 剪片。** 社群伺服器操控的就是 Resolve 本身，專案原地不動。外部腳本需要付費的 Studio 版。',
        '**你的影片主要是螢幕錄影。** Tella 是螢幕錄影和剪輯工具，它的伺服器還包含錄製和發布。它是代管的，所以工作會經過 Tella 的服務。',
        '**你只是要批次轉檔、裁切或上字幕。** 包裝了 FFmpeg 的技能在終端機裡就能做，不必安裝其他東西。',
      ]},
    ]},
    {heading:'決定之前要確認的事',blocks:[
      {list:[
        '**素材去了哪裡。** 本機伺服器在你自己的電腦上執行，代管伺服器處理的是存在那個服務裡的素材。不論哪一種，都要看清楚 App 本身會上傳什麼；也要記得，工具回傳的內容會交給助理。',
        '**你能不能接手。** 結果是剪輯軟體裡的時間軸，你就能親手修某一刀；結果只是算好的檔案，每改一處都要重新算一次。',
        '**復原怎麼做。** 問清楚助理的修改是否會進入剪輯軟體正常的復原紀錄，能不能把一整輪操作一次退回去。',
        '**動手之前會問什麼。** 看有沒有辦法讓助理在刪除檔案、花錢生成之前停下來。',
        '**支援哪些助理。** SkyCut、Palmier Pro、ChatCut 和 Tella 都寫明支援 Claude 和 Codex。Resolve 那個伺服器的安裝程式可以設定 Claude 桌面版、Claude Code 和 Codex 指令列版。',
      ]},
    ]},
    {heading:'SkyCut 是怎麼做的',blocks:[
      {list:[
        '伺服器在本機，隨 App 一起安裝。專案和素材留在 Mac 上。',
        '每一次工具呼叫是一步復原，**撤销这一轮**（復原這一輪）可以把專案恢復到助理開始之前。',
        '**请求批准**（請求核准）模式下，助理要做超出預設範圍的事之前會停下來；付費生成在任何模式下都有每日額度。',
        'Claude 桌面版、Claude Code 和 Codex 都是一個按鈕就能連接。步驟請看[用 Claude Code 剪片](/zh-hant/guides/edit-video-with-claude-code/)和[用 Codex 剪片](/zh-hant/guides/edit-video-with-codex/)。',
        'AI 剪輯屬於 SkyCut Pro，每月 {{pro.monthly}} 或每年 {{pro.yearly}}（美元）；第一次把 SkyCut 連上你的 Sky Studio 帳號時，會開始 7 天的 Pro 試用。App 介面目前是英文、簡體中文和西班牙文，沒有 Windows 版和 Intel 版。',
      ]},
    ]},
  ],
  faq:[
    ['剪輯影片用哪個 MCP 伺服器最好？','看你的電腦和剪輯軟體。Apple 晶片的 Mac 上，SkyCut 和 Palmier Pro 給助理一條原生的時間軸；Windows 上可以看 ChatCut Desktop 或 DaVinci Resolve；螢幕錄影類的可以看 Tella。'],
    ['這些除了 Claude，Codex 也能用嗎？','SkyCut、Palmier Pro、ChatCut 和 Tella 兩者都寫明支援。DaVinci Resolve 的社群伺服器除了 Claude，也可以設定給 Codex 指令列版。'],
    ['素材會離開我的電腦嗎？','SkyCut 把專案和素材留在 Mac 上，只把工具回傳的內容（例如畫面和逐字稿）傳給助理。其他工具：本機伺服器代表助理連到的是你自己電腦上的剪輯軟體，代管伺服器處理的是存在那個服務裡的素材。App 本身會上傳什麼，請看各家的條款。'],
    ['有能在 Windows 上用的嗎？','有。ChatCut Desktop、Tella 和 DaVinci Resolve 都能在 Windows 上執行。SkyCut 只支援 Apple 晶片的 Mac 與 macOS 15 以上。'],
    ['一定要用 MCP 伺服器嗎？','只處理檔案的話不用。Claude 或 Codex 可以直接執行 FFmpeg 來裁切、合併和轉檔。想要一個能在時間軸上檢查和修改的剪輯時，MCP 伺服器才派得上用場。'],
  ],
};
