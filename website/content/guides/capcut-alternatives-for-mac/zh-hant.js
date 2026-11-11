// 繁體中文：以台灣讀者的選購情境寫作，不逐字轉換簡體稿。
export default {
  title:'Mac 上的 CapCut／剪映替代軟體：6 種選擇',
  description:'想換掉 CapCut 或剪映？比較 iMovie、Final Cut Pro、DaVinci Resolve、Premiere、Descript 和 SkyCut，依免費剪片、後製及 AI 工作流程選擇。',
  heading:'Mac 上的 CapCut／剪映替代軟體怎麼選',
  answer:'如果你在 Mac 上找 CapCut 或剪映的替代軟體，先想清楚要換掉哪一段工作流程。只想免費剪片，可以先試 iMovie；需要調色、特效與聲音後製，可以看 DaVinci Resolve；偏好 Apple 的磁性時間軸，可以看 Final Cut Pro；已有 Adobe 工作流程，可以看 Premiere；以訪談、課程口播的逐字稿為主，可以看 Descript。若你想讓 Claude 或 Codex 操作 Mac 上的多軌時間軸，再自己接手修改，SkyCut 是另一個選擇。SkyCut 是本文發布方的產品，只支援 Apple silicon 與 macOS 15 以上，免費版影片匯出有浮水印，因此不適合只找「免費、無浮水印、Windows」替代品的人。',
  sections:[
    {heading:'先分清楚：替代剪輯工作，還是替代整套範本',blocks:[
      'CapCut 的官方頁面列有特效、關鍵影格和自動字幕，也有免費與付費方案。換一套軟體時，應該列出你真正會用到的功能：直式構圖、字幕、子母畫面、音樂，還是每週重複做的口播剪輯。不要只比較功能名稱的數量。',
      '本篇把 CapCut 與剪映使用者的換軟體需求放在一起討論，沒有把兩者的方案、素材授權或帳號權益視為相同，也沒有測試工程互轉。請保留原始影片、字幕檔和舊工程，先用新軟體完成一支短片，再決定是否搬移後續工作。',
    ]},
    {heading:'6 種選擇：平台、收費與適合的工作',blocks:[
      {
        "table": {
          "head": [
            "軟體",
            "平台與工作位置",
            "收費方式"
          ],
          "rows": [
            [
              "iMovie",
              "Mac 桌面 App",
              "免費"
            ],
            [
              "Final Cut Pro",
              "Mac 桌面 App",
              "Mac 買斷或 Apple Creator Studio 訂閱"
            ],
            [
              "DaVinci Resolve",
              "Mac／Windows／Linux 桌面軟體",
              "免費版與付費 Studio 版"
            ],
            [
              "Adobe Premiere",
              "Mac／Windows 桌面軟體",
              "訂閱"
            ],
            [
              "Descript",
              "Mac／Windows App 與網頁；素材走上傳流程",
              "免費方案與按人訂閱；有媒體時數及 AI 點數額度"
            ],
            [
              "SkyCut",
              "Apple silicon Mac；本機工程與時間軸",
              "Free 匯出有浮水印；Pro 訂閱"
            ]
          ]
        }
      },
      {
        "table": {
          "head": [
            "軟體",
            "適合考慮的原因"
          ],
          "rows": [
            [
              "iMovie",
              "基本剪接、標題、轉場與子母畫面；有一鍵增強"
            ],
            [
              "Final Cut Pro",
              "磁性時間軸、自動字幕、Magnetic Mask；部分功能需要 Apple silicon"
            ],
            [
              "DaVinci Resolve",
              "剪輯、調色、Fusion、Fairlight；文字剪輯和多項 AI 功能在 Studio"
            ],
            [
              "Adobe Premiere",
              "文字剪輯、字幕翻譯，以及 Adobe 工作流程"
            ],
            [
              "Descript",
              "以逐字稿剪口播，搭配場景、圖層和字幕"
            ],
            [
              "SkyCut",
              "Claude／Codex 操作時間軸，自己也能剪；AI 剪輯需要 Pro"
            ]
          ]
        }
      },
      'SkyCut 是本文發布方的產品。我們沒有做過這些軟體之間的比較測試，這份比較不是排名；別家的功能與方案依各自官方頁面整理。表中列有字幕或 AI，不表示支援所有語言、機型與版本，請依自己的素材確認。桌面 App 不代表每個 AI 功能都在本機執行，雲端處理與素材條款要另外確認。',
    ]},
    {heading:'照你的換軟體原因縮小範圍',blocks:[
      {list:[
        '**只是要免費剪好一支影片。** 先試 iMovie 的基本功能。需要更多調色和聲音處理時，再評估 Resolve 免費版；不要把 Studio 的 AI 功能當成免費版附贈。',
        '**要持續做較完整的後製。** 以磁性時間軸為主可看 Final Cut Pro，以調色、合成和混音為主可看 Resolve，已經使用 Adobe 工具則可評估 Premiere。這是依工作需求分流，並非品質評分。',
        '**主要剪訪談或課程口播。** 看 Descript 的逐字稿剪輯是否符合你的修改方式，並用自己的錄音確認語言支援、文字校正和額度。',
        '**已經習慣用 Claude 或 Codex 交代工作。** 可以試 SkyCut：讓助手先列剪輯方案、排片與加字，再到同一條時間軸調整。設定方式見 [Claude Code 教學](/zh-hant/guides/edit-video-with-claude-code/)。',
      ]},
    ]},
    {heading:'SkyCut 適合誰，限制是什麼',blocks:[
      'SkyCut 適合想在 Mac 上把「請 AI 剪」和「自己改一刀」接在一起的人。它有本機多軌剪輯、畫面文字與字幕；Pro 讓 Claude 或 Codex 透過 App 內建的本機 MCP 伺服器操作。它不是 CapCut 的範本或工程相容替身。',
      {list:[
        '只支援 Apple silicon Mac、macOS 15 以上，沒有 Windows 或 Intel 版。App 介面只有英文、簡體中文、西班牙文，沒有繁體中文介面。',
        '免費版可以手動剪輯，但影片匯出帶 Sky Studio 浮水印。Pro 提供 AI 剪輯與無浮水印匯出，月繳 {{pro.monthly}} 或年繳 {{pro.yearly}}，均為美元；稅金另計。',
        '自動從聲音產生字幕需要 macOS 26；macOS 15 可以匯入、編輯及翻譯字幕。不要因為 App 能安裝，就認定全部功能都能用。',
        '工程與素材留在 Mac；外部 AI 助手會收到工具回傳的影格或逐字稿等內容，雲端生成另需網路與積分。助手服務由你自備，費用另計。',
      ]},
    ]},
    {heading:'換軟體前，用一支短片確認這四件事',blocks:[
      {list:[
        '**匯出。** 用預計交付的解析度與格式匯出一次，確認浮水印、字型和字幕有沒有符合需求。',
        '**素材。** 試自己的手機影片、螢幕錄影和音樂；核對範本、音樂與 AI 素材是否允許你的用途。',
        '**可修改性。** 故意改錯一個剪點，再試還原、改字幕和替換畫面，確認能接手修正。',
        '**總成本。** 分開看軟體授權、AI 用量、外部助手與素材訂閱；付費方案的名稱相似，不表示內容一樣。',
      ]},
    ]},
    {heading:'結論：依你要保留的工作方式選擇',blocks:[
      '免費的基本剪片先試 iMovie；已有明確後製需求，再在 Final Cut Pro、Resolve 和 Premiere 之間挑符合習慣的一套。若重點是逐字稿，試 Descript；若重點是讓自己的 Claude／Codex 操作可手動修改的 Mac 時間軸，試 SkyCut。',
      '如果你想進一步比較 AI 到底幫忙哪一步，可以接著看 [Mac AI 影片剪輯軟體的選法](/zh-hant/guides/ai-video-editors-for-mac/)。',
    ]},
  ],
  faq:[
    ['SkyCut 是免費、無浮水印的 CapCut 替代品嗎？','不是。SkyCut 免費版可以手動剪輯，但影片匯出有浮水印；AI 剪輯與無浮水印影片匯出需要 Pro。若免費是首要條件，可以先試 iMovie，再用實際匯出確認需求。'],
    ['可以直接把 CapCut 或剪映工程搬到 SkyCut 嗎？','本篇沒有驗證工程互轉，也不承諾相容。請保留舊工程和原始素材，先用原始影片在新軟體試做；輸出一支影片並不等於保留可修改的時間軸。'],
    ['哪個適合只用 Windows 的人？','表中的 Resolve、Premiere 與 Descript 有 Windows 版。SkyCut 沒有 Windows 版，也沒有 Intel Mac 版。'],
    ['SkyCut 有繁體中文介面嗎？','沒有。App 介面支援英文、簡體中文和西班牙文；本文使用繁體中文，不代表 App 已有繁體中文介面。'],
    ['AI 字幕可以在 macOS 15 用嗎？','SkyCut 從聲音自動產生字幕需要 macOS 26。macOS 15 能匯入、編輯、翻譯和匯出字幕，支援語言依 macOS 可提供的模型而定。'],
  ],
};
