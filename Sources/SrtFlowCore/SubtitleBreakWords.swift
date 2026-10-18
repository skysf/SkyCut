import Foundation

// 断句、折行时看哪些词（SubtitleBreaks 的词表，2026-09-30 从那个文件搬出来，它顶到 400 行了）：
// 英文里适合当一条开头的、不许留在末尾的；中文里不许起头的助词、句末语气词、适合起头的连词、不许收尾的连词介词。
// 2026-10-18 起字幕折行（SubtitleRowBreaks）也用这一套，并补了折行才用到的几样：方位词、量词、数词、日文的助词。
// 规则的出处见 docs/architecture/subtitle-generation-style.md、docs/bugfixes/2026-10-18-subtitle-wrap-splits-chinese-words.md。

enum SubtitleBreakWords {
    /// 英文里适合当一条开头的词：连词、关系词，以及不紧贴前面那个词的介词（Netflix：在连词、介词前面断）。
    /// 「of」「to」不算：「bottom / of the world」「going / to walk」反而拆散了一个意思。
    static let goodStarts: Set<String> = [
        "and", "but", "or", "so", "because", "that", "which", "who", "whom", "whose", "when", "where",
        "while", "if", "unless", "until", "since", "although", "though", "as", "than", "whether",
        "in", "on", "at", "for", "with", "from", "into", "onto", "about", "after", "before",
        "between", "through", "during", "without", "like"
    ]
    /// 英文里不许留在一条末尾的词：冠词、限定词、介词、连词（含从句连词：「…my box until / it's…」
    /// 的 until 该起头，不该收尾）、物主代词、助动词、主语代词。
    static let danglingEnds: Set<String> = [
        "all", "each", "every", "some", "any", "no", "such",
        "because", "when", "where", "while", "if", "unless", "until", "since", "although", "though",
        "whether", "than",
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "from", "into", "onto", "about",
        "by", "as", "and", "or", "but", "so", "that", "which", "who", "my", "your", "his", "her", "its",
        "our", "their", "this", "these", "those", "is", "are", "was", "were", "be", "been", "am", "will",
        "would", "can", "could", "should", "have", "has", "had", "do", "does", "did", "not", "very",
        "i", "you", "he", "she", "we", "they", "i'm", "you're", "we're", "they're", "it's", "there's"
    ]
    /// 中文里不许起头的字（助词、语气词）。
    static let particles: Set<Character> = ["的", "了", "吗", "呢", "吧", "啊", "着", "过", "们", "地", "得", "么", "呀", "嘛"]
    /// 中文的句末语气词：转写常常不给标点，它后面就是句号该在的地方。
    static let sentenceFinalParticles: Set<Character> = ["呢", "吗", "吧", "啊", "呀", "嘛"]
    /// 中文里适合当一条开头的词（连词、话题转换的词）。
    static let chineseGoodStarts = [
        "如果", "因为", "所以", "但是", "而且", "然后", "虽然", "可是", "不过", "并且", "或者", "于是",
        "同时", "无论", "只要", "只有", "即使", "就算", "最后", "首先", "其次", "接着", "另外", "其实",
        "现在", "然而", "因此", "以及", "还有"
    ]
    /// 中文里不许留在一条末尾的词（连词、介词、代词、副词、能愿动词：开了头、话没说完）。只认整词 —— 「现在」不算「在」。
    /// 「以及」起的那一行是 2026-10-18 折行时补的（「…GPT Image 以及 / 字节跳动的…」）。
    static let chineseDanglingEnds = [
        "如果", "因为", "所以", "但是", "而且", "然后", "虽然", "可是", "不过", "并且", "或者", "于是",
        "就是", "还是", "只是", "在", "把", "被", "和", "跟", "与", "对", "从", "向", "给", "让", "为", "将", "比",
        "我", "你", "他", "她", "它", "我们", "你们", "他们", "她们", "这", "那", "这个", "那个", "这些", "那些", "一个",
        "以及", "及", "或", "而", "并", "还有",
        "怎么", "如何", "怎样", "为什么", "是否", "能否", "可以", "应该", "必须", "正在", "已经", "会", "要", "能", "想",
        "还", "也", "都", "就", "才", "很", "最", "更", "不", "没", "没有", "再", "又"
    ]
    /// 中文的方位词：单独一个起头不好（「两个平台 / 上的短视频」），收尾没问题（「照在冰盖上 / 然后」）。
    static let localizers: Set<String> = ["上", "下", "里", "中", "内", "外", "前", "后"]
    /// 中文的数词（含「两」「几」「半」）：留在一行末尾，数和后面的东西就拆开了。
    static let chineseNumerals: Set<Character> = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万", "亿", "两", "几", "半"]
    /// 常见的量词（含时间单位）：跟在数词、指示词后面时，和后面的名词不拆（「两个 / 平台」「这节 / 课」）。
    static let measureWords: Set<String> = [
        "个", "位", "只", "条", "张", "种", "次", "件", "本", "部", "台", "款", "家", "首", "段", "句", "篇", "份", "名", "项",
        "层", "节", "间", "支", "把", "块", "片", "辆", "架", "门", "道", "场", "集", "期", "回", "遍", "分钟", "秒", "天", "年", "月"
    ]
    /// 指示、询问数量的词：后面跟量词时同数词。
    static let quantifiers: Set<String> = ["这", "那", "哪", "每", "几", "多", "某", "各"]
    /// 日文里不许起头的助词、助动词（「…群れを / なして」可以，「…なし / て」不行）。
    static let japaneseRowStarts: Set<String> = [
        "を", "に", "が", "は", "の", "で", "と", "も", "へ", "や", "から", "まで", "より", "ね", "よ",
        "て", "た", "だ", "ない", "ます", "です", "う", "よう"
    ]
}
