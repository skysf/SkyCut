// 繁體中文（台灣用語，不是逐字轉換）。App 沒有繁體介面，文中按鈕名稱用簡體中文介面上的原文。
export default {
  title:'如何用 Claude Code 剪片（Mac 教學）',
  description:'Claude Code 自己打不開剪輯軟體。在 Mac 上把它連到 SkyCut，它就能在真正的時間軸上剪輯、上字幕、輸出，每一步你都看得到、改得了。',
  heading:'如何在 Mac 上用 Claude Code 剪片',
  answer:'Claude Code 可以剪輯影片，前提是給它一個能操控的剪輯軟體。在 Mac 上安裝 SkyCut，填入你的 Sky Studio Key，再到 SkyCut 的設定裡按 Claude Code 旁邊的**连接**（連接）。接著 Claude 會透過 SkyCut 內建的本機 MCP 伺服器，在真正的多軌時間軸上工作：看素材、剪掉口播裡的停頓、加標題和字幕、輸出成品；每一步你都看得到，可以調整，也可以復原。SkyCut 只支援 Apple 晶片的 Mac 與 macOS 15 以上，沒有 Windows 版和 Intel 版。',
  sections:[
    {heading:'Claude Code 剪片：做得到與做不到的事',blocks:[
      'Claude Code 是在終端機裡工作的 AI 代理。它能讀檔案、執行指令，但它自己看不了影片、聽不了聲音，也沒辦法排列片段。要剪輯，就需要一個替它做這些事的工具。這類工具有兩種。',
      {list:[
        '**指令列工具。** Claude 寫 FFmpeg 指令，或執行包裝了 FFmpeg 的技能（skill）。適合裁切、合併、轉檔這類檔案處理。每改一次都要重新算出一個檔案，沒有時間軸可以讓你打開來親手修。',
        '**Claude 能操控的剪輯軟體。** 軟體透過 MCP（Model Context Protocol，讓 AI 助理接上工具的通用協定）把時間軸開放出來。Claude 呼叫這些工具，每一處修改都落在時間軸上，你可以播放、拖曳、自己改。',
      ]},
      'SkyCut 屬於第二種：原生的 Mac 剪輯軟體，內建 MCP 伺服器。以下就用它示範。',
    ]},
    {heading:'需要準備什麼',blocks:[
      {list:[
        '一台 Apple 晶片（M1 以上）的 Mac，系統為 macOS 15 以上。需要語音轉文字的功能（例如剪掉停頓、產生字幕）需要 macOS 26。',
        'SkyCut，免費下載。App 介面目前有英文、簡體中文和西班牙文，沒有繁體中文；本文的按鈕名稱照簡體中文介面寫。',
        'SkyCut Pro。AI 剪輯是 Pro 的功能。第一次把 SkyCut 連上你的 Sky Studio 帳號時，會開始 7 天的 Pro 試用；每個帳號一次，每台 Mac 一次。',
        'Claude Code，已安裝並用你自己的 Claude 方案登入。SkyCut 不包含 AI 訂閱。',
      ]},
      {note:'Claude 桌面版和 Codex 在同一個地方連接，用法相同。瀏覽器裡一般的 ChatGPT 對話無法連接，因為 SkyCut 的 MCP 伺服器是在你自己的 Mac 上執行。'},
    ]},
    {heading:'五個步驟完成設定',blocks:[
      {steps:[
        ['安裝 SkyCut','下載 SkyCut，打開磁碟映像檔，把 SkyCut 拖到「應用程式」。[安裝說明](/zh/docs/#video)（簡體中文）裡有這一步的短片。'],
        ['填入 Sky Studio Key','登入 Sky Studio，點右上角的頭像，選 SkyCut，建立一組 Key。回到 SkyCut，打開「设置」（設定）裡的 Sky Studio，把 Key 貼上。這一步會開通 Pro 並開始試用。'],
        ['連接 Claude Code','在 SkyCut 打開**设置 → 连接 AI**，按 Claude Code 旁邊的**连接**。SkyCut 會替你執行 `claude mcp add`，把自己的 MCP 伺服器登記到 Claude Code，並允許 SkyCut 的工具，這樣 Claude 不必每呼叫一個工具就停下來問你。'],
        ['開一個新的 Claude Code 工作階段','Claude Code 在工作階段開始時載入 MCP 伺服器。開一個新的工作階段，輸入 `/mcp`，清單裡應該會看到 `skycut`。'],
        ['告訴 Claude 素材在哪裡','告訴 Claude 素材放在哪個資料夾、你想做成什麼。SkyCut 會打開那個資料夾，輸出的成品等新檔案也會存在那裡。'],
      ]},
    ]},
    {heading:'第一次剪片：可以這樣說',blocks:[
      '用平常講話的方式跟 Claude 說就可以。下面每一句都對應 SkyCut 做得到的事，可以在同一個專案上一句接一句地說。',
      {prompt:'在 SkyCut 打開 ~/Movies/interview 這個資料夾，把每段素材看過一遍，告訴我各是什麼內容。'},
      {prompt:'建立一個 16:9 的專案，用最好的三段素材做出粗剪。'},
      {prompt:'把口播那一段裡的長停頓和贅字剪掉。'},
      {prompt:'產生中文字幕，再加一軌英文翻譯。'},
      {prompt:'在開頭三秒加上標題「南極」，然後輸出 1080p 的 MP4。'},
      'Claude 還能替主體構圖、讓音樂對拍、疊加圖層與動畫、配旁白，並檢查成品有沒有問題。如果不想一步步描述，也可以直接指定一種剪輯風格（例如紀錄片或 vlog），讓它自己規劃。',
    ]},
    {heading:'檢查 Claude 剪了什麼',blocks:[
      '這正是要用真正剪輯軟體的原因。Claude 工作時，SkyCut 的工具列會顯示**AI 正在剪辑**，並跳到每一處剛改的地方。你隨時可以按**停止**。',
      {list:[
        '每一次工具呼叫是一步復原，按 ⌘Z 可以把 Claude 的修改一步步退回去。',
        'Claude 做完之後，**撤销这一轮**（復原這一輪）會把專案恢復到這一輪開始之前的樣子。',
        '沒有任何東西被鎖住。你可以親手拖一個片段、改一句字幕的時間、換一個標題，再請 Claude 接著做。',
        'SkyCut 有兩種權限模式。**请求批准**（請求核准）會在 Claude 要做超出預設範圍的事之前停下來問你，例如刪除檔案。**全部权限**（完整權限）直接執行，事後告訴你做了什麼。兩種模式下，付費生成的每日額度都照樣有效。',
      ]},
    ]},
    {heading:'要花多少錢',blocks:[
      {table:{head:['項目','價格（美元）','說明'],rows:[
        ['SkyCut 免費版','{{free.price}}','完整的手動剪輯。輸出帶浮水印。不能讓 AI 剪輯。'],
        ['SkyCut Pro','每月 {{pro.monthly}} 或每年 {{pro.yearly}}','AI 剪輯，輸出無浮水印。第一次連接 SkyCut 時先有 7 天試用。'],
        ['Claude Code','你自己的 Claude 方案','付給 Anthropic，不包含在 SkyCut 裡。'],
        ['雲端生成','選用','生成圖片、影片、音樂和聲音要用 Sky Studio 點數，另外購買。'],
      ]}},
      '價格未含稅。兩個方案各包含什麼，請看[價格表](/en/#pricing)（英文）。',
    ]},
    {heading:'開始之前要知道的限制',blocks:[
      {list:[
        '只支援 Mac：Apple 晶片，macOS 15 以上。SkyCut 無法在 Windows 和 Intel Mac 上執行。',
        'Claude 不像你那樣「看」影片。它透過 SkyCut 的工具擷取畫面、聽音量、讀逐字稿，所以發布之前請自己把成品看過一遍。',
        '專案和素材留在你的 Mac 上；但工具回傳給 Claude 的內容（例如畫面和逐字稿）會作為對話的一部分傳給 Claude。',
      ]},
    ]},
    {heading:'用 Claude 剪片的其他方法',blocks:[
      'SkyCut 不是唯一的路，哪一條適合要看你做什麼。',
      {list:[
        '**以 FFmpeg 為基礎的技能。** 有開源的 Claude Code 技能包裝了 FFmpeg 和 Whisper，在終端機裡執行。適合批次處理檔案，不需要剪輯軟體；沒有時間軸可以檢查。',
        '**其他剪輯軟體的 MCP 伺服器。** 有社群專案透過 DaVinci Resolve 的腳本介面來操控它，支援 macOS、Windows 和 Linux；外部腳本需要付費的 Studio 版。',
      ]},
      '如果你用 Mac，而且希望 Claude 在一個你自己也能親手操作的剪輯軟體裡工作，就選 SkyCut。',
    ]},
  ],
  faq:[
    ['Claude Code 可以自己剪輯影片嗎？','不行。Claude Code 處理的是文字和指令。要修改影片，它需要 FFmpeg，或是一個它能操控的剪輯軟體，例如 SkyCut。'],
    ['Claude 桌面版和 Codex 也能這樣用嗎？','可以。SkyCut 的**设置 → 连接 AI**裡，Claude 桌面版、Claude Code 和 Codex 各有一個連接按鈕。其他用戶端只要支援本機 stdio MCP 伺服器也能用。'],
    ['是免費的嗎？','SkyCut 免費下載，手動剪輯不用錢。讓 Claude 來剪需要 SkyCut Pro：7 天試用結束後每月 {{pro.monthly}} 或每年 {{pro.yearly}}（美元），另外還要你自己的 Claude 方案。'],
    ['Windows 可以用嗎？','不行。SkyCut 只支援 Apple 晶片的 Mac 與 macOS 15 以上。'],
    ['素材會被上傳嗎？','SkyCut 在你的 Mac 上剪輯，專案也留在本機。Claude 會收到工具為你的請求回傳的內容，例如畫面和逐字稿。'],
  ],
};
