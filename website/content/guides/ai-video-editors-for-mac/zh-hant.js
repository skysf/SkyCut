// 繁體中文：先問 AI 要解決哪個步驟，再選軟體。
export default {
  title:'Mac AI 影片剪輯軟體怎麼選？6 種工作流程比較',
  description:'比較 SkyCut、Final Cut Pro、Resolve、Premiere、Descript 和 Filmora 的 AI 用途、平台與收費方式，分清自動字幕、文字剪輯和 AI 助手操作。',
  heading:'Mac 上的 AI 影片剪輯軟體怎麼選',
  answer:'選 Mac AI 影片剪輯軟體，先決定 AI 要替你做哪一步。想找畫面中的物件、做遮罩或改善聲音，可以從 Final Cut Pro、DaVinci Resolve Studio 或 Premiere 的編輯工具看起；想按照口播逐字稿刪改，可以評估 Descript、Premiere 或 Filmora；想讓 Claude／Codex 直接操作 Mac 上可手動修改的多軌時間軸，可以看 SkyCut。這些不是同一種「自動剪片」，也不能光看 AI 功能數量就排高低。SkyCut 是本文發布方的產品，只支援 Apple silicon、macOS 15 以上，免費版影片匯出有浮水印；它不適合只找免費、無浮水印或 Windows 軟體的人。',
  sections:[
    {heading:'把「AI 剪輯」拆成三種需求',blocks:[
      {list:[
        '**處理一個步驟。** 自動字幕、人物遮罩、去雜音或追蹤。你仍然決定怎麼剪，AI 處理指定的部分。',
        '**按照文字剪。** 先轉寫，再用句子決定留下或刪除哪段口播。要分清「改正逐字稿」和「刪掉影片內容」是否是不同操作。',
        '**交代一個結果。** 請助手整理素材、排片、加字與匯出。這時要確認它會改什麼、能不能先看方案，以及如何復原。',
      ]},
      '同一套軟體可能涵蓋多種方式。以下依官方已描述的功能分類，不表示任何一家只能做表內的一件事，也不把「有助手」當成剪輯品質的保證。',
    ]},
    {heading:'6 款軟體的 AI 角色與費用',blocks:[
      {
        "table": {
          "head": [
            "軟體",
            "平台與工作位置",
            "收費與需要核對的限制"
          ],
          "rows": [
            [
              "SkyCut",
              "Apple silicon Mac；本機多軌時間軸",
              "Free 影片有浮水印；AI 剪輯與無浮水印匯出需要 Pro"
            ],
            [
              "Final Cut Pro",
              "Mac 桌面 App",
              "Mac 買斷或 Creator Studio 訂閱；部分功能需 Apple silicon"
            ],
            [
              "DaVinci Resolve Studio",
              "Mac／Windows／Linux 桌面軟體",
              "免費 Resolve 與付費 Studio 分開；不要把 Studio AI 算進免費版"
            ],
            [
              "Adobe Premiere",
              "Mac／Windows 桌面軟體",
              "訂閱；確認所需功能、版本及生成用量條款"
            ],
            [
              "Descript",
              "Mac／Windows App 與網頁",
              "免費與按人訂閱；媒體時數及 AI 點數隨方案不同"
            ],
            [
              "Filmora",
              "Mac／Windows 桌面軟體",
              "Mac 有訂閱及永久版選項；無浮水印匯出需付費，AI 點數另有額度"
            ]
          ]
        }
      },
      {
        "table": {
          "head": [
            "軟體",
            "AI 可以協助的事"
          ],
          "rows": [
            [
              "SkyCut",
              "Claude／Codex 操作剪輯；本機字幕與翻譯"
            ],
            [
              "Final Cut Pro",
              "Magnetic Mask、物件追蹤、自動字幕、光線與色彩增強"
            ],
            [
              "DaVinci Resolve Studio",
              "文字剪輯、Magic Mask、降噪"
            ],
            [
              "Adobe Premiere",
              "文字剪輯、字幕翻譯"
            ],
            [
              "Descript",
              "Underlord 助手、口播整理、短片製作；另提供 API／MCP"
            ],
            [
              "Filmora",
              "文字剪輯、語音轉文字、音訊降噪"
            ]
          ]
        }
      },
      'SkyCut 是本文發布方的產品。我們沒有做過比較測試，這份比較不是排名。別家的事實來自各自官方頁面；選擇建議是我們依功能作的判斷，不是測試結果。字幕和 AI 功能的語言、機型與版本支援要分別確認，不能由功能名稱推論全都支援。',
    ]},
    {heading:'本機 App、本機 AI 與雲端助手有什麼不同',blocks:[
      '下載到 Mac 的 App，仍可能把某些 AI 工作交給雲端。挑選時要分開問：工程存在哪裡、聲音在哪裡轉寫、助手會收到哪些內容，以及生成素材由誰處理。不能只用「有 Mac 版」推論素材不會離開電腦。',
      'SkyCut 的工程與素材在 Mac，本機 MCP 伺服器把編輯動作交給外部助手呼叫。助手會收到工具回傳的影格、逐字稿等內容；雲端生成另外走服務、花積分。它的本機字幕生成需要 macOS 26，字幕翻譯需要 macOS 15 以上與 macOS 支援的語言模型。',
      'Descript 也提供 Underlord 和 API／MCP，因此「能用對話編輯」不是 SkyCut 獨有。比較時應看你要在本機時間軸逐刀接手，還是以 Descript 的文字、場景與服務流程工作；不要把兩種連線方式當成同一件事。',
    ]},
    {heading:'用你自己的 60 秒素材挑選',blocks:[
      {steps:[
        ['寫出一份相同的任務','例如：保留重點、刪除兩段指定內容、加標題與字幕、輸出直式影片。各家都用同一段素材和交付要求，保留原檔。'],
        ['看 AI 改了什麼','檢查有沒有漏句、錯字、剪掉必要的停頓或改變意思。語音辨識、剪輯判斷和生成畫面要分開評估。'],
        ['故意改一個地方','挪動剪點、修字幕、撤銷一次，再重開工程。這能確認結果是否方便你繼續修改。'],
        ['算完成這支影片的成本','記下編輯器方案、AI 用量、素材與外部助手費用。這是一份自測方法，本篇沒有提供各家的速度、準確率或成本實測。'],
      ]},
    ]},
    {heading:'如果你的需求是 Claude／Codex 操作時間軸',blocks:[
      'SkyCut 的 Pro 讓助手和你操作同一份可修改的工程。你可以先要求列方案，確認後排片；每次工具修改可撤銷，也能用 App 的「撤销这一轮」（復原這一輪）回到本輪開始前。接法見 [Claude Code 教學](/zh-hant/guides/edit-video-with-claude-code/)，其他連線方式可看 [英文 MCP 選型文章](/en/guides/video-editing-mcp-servers/)。',
      {list:[
        '系統要求是 Apple silicon、macOS 15 以上，沒有 Windows 或 Intel 版。App 介面只有英文、簡體中文、西班牙文，沒有繁體中文介面。',
        '免費版適合先手動試剪，影片匯出有浮水印。Pro 月繳 {{pro.monthly}} 或年繳 {{pro.yearly}}（美元、稅金另計）；外部助手自備，雲端生成積分另計。',
        '第一次把 SkyCut 連上 Sky Studio 帳號時開始 7 天 Pro 試用，每個帳號一次、每台 Mac 一次。先用自己的素材確認工作流程再購買。',
      ]},
    ]},
    {heading:'結論：選能解決你卡住那一步的工具',blocks:[
      '已有剪輯習慣，只缺字幕、遮罩或降噪，先看原本軟體的 AI 功能；口播為主，試文字剪輯；想用自己的 Claude／Codex 串起編輯動作並隨時手動接手，再評估 SkyCut。真正值得保留的是你能檢查、修正並穩定交付的流程。',
      '如果你的出發點是換掉 CapCut 或剪映，而不是找更多 AI 功能，可以看 [Mac 的 CapCut 替代軟體](/zh-hant/guides/capcut-alternatives-for-mac/)；若只需要字幕，先看 [Mac 自動字幕教學](/zh-hant/guides/auto-subtitles-on-mac/)。',
    ]},
  ],
  faq:[
    ['AI 剪輯等於輸入一句話就能交片嗎？','不等於。AI 可以處理字幕、遮罩、文字剪輯或一連串操作，但仍要檢查剪點、意思、字詞與素材使用權。本篇沒有測過任何一家能否直接產出可交付的成片。'],
    ['有 Mac 版就表示 AI 都在本機跑嗎？','不是。桌面介面、本機模型、外部 AI 助手和雲端生成是不同層。請逐項確認資料會傳去哪裡。'],
    ['SkyCut 的 AI 剪輯是免費的嗎？','AI 透過 MCP 操作需要 Pro，無浮水印影片匯出也需要 Pro。免費版有手動剪輯與字幕功能，但從聲音產生字幕需要 macOS 26，影片匯出仍有浮水印。'],
    ['Descript 也能接 AI 助手嗎？','能。官方介紹 Underlord，也提供 API／MCP 入口。本篇不把支援助手寫成 SkyCut 的專屬功能，兩者的工作方式需要各自確認。'],
    ['可以在 Windows 或 Intel Mac 用 SkyCut 嗎？','不行。SkyCut 只有 Apple silicon Mac 版，需要 macOS 15 以上。App 的顯示語言為英文、簡體中文、西班牙文。'],
  ],
};
