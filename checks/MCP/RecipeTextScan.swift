import Foundation

// 剪辑风格卡的文字怎么切成段和句、哪些说法算「每日预算」「确认码」：RecipeContractChecks 拿它查卡里的话（2026-11-13 从那边拆出来，
// 审查 D6R-03：换个说法（spending cap）就认不出预算，嵌套列表把父项的条件和子项的动作切成两段，两种都漏掉了教 AI 越过每日预算的话）。
// 这是**受限的文字扫描**：认得出的写法才查得到，扫不出来不等于卡里的话对得上合同。所以切法和词表各自带着坏话（必须抓到）和
// 合规的话（不许误报），在 runRecipeTextScanSelfChecks 里先过一遍；改切法、改词表时先让这些例子说话，再看卡。
// 切法：标题、空行隔开的段、列表的每一项各算一段，续行（不管缩不缩进）接在上一行后面；**嵌套的列表项带着上面每一层父项的话**，
// 段落后面的列表项带着那一段（「超了每日上限：」下面一项「带 confirm_token 再调」要算成一句）。句子在段里按句号 / 问号 / 叹号切，
// 冒号、分号不切，所以父项结尾的「…：」和子项的第一句连成一句。标题不带给下面：标题是名字不是条件（同一节里分开写的两条不算一句）。
// 不管什么：卡里该写什么、合同是什么（RecipeContractChecks）。

/// 卡里的段：标题、空行隔开的段、列表的每一项各算一段；续行接在上一行后面；嵌套的列表项、段落后面的列表项前面带着父项的话。
func recipeBlocks(_ text: String) -> [String] {
    var blocks: [String] = []
    // 还开着的父项：段落记 -1（它后面的列表项都带着它），列表项记它的缩进（缩进更深的才是它的子项）。
    var parents: [(indent: Int, text: String)] = []
    // 续行接到哪一段；接的那一段就是 parents 最上面那一层时，父项的话也一起长。
    var current: Int?
    var currentIsParent = false
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        if trimmed.isEmpty {
            current = nil
        } else if trimmed.hasPrefix("#") {
            parents = []
            blocks.append(trimmed)
            current = nil
        } else if recipeListItem(trimmed) {
            while let last = parents.last, last.indent >= indent { parents.removeLast() }
            blocks.append((parents.map(\.text) + [trimmed]).joined(separator: " "))
            parents.append((indent, trimmed))
            current = blocks.count - 1
            currentIsParent = true
        } else if let open = current {
            blocks[open] += " " + trimmed
            if currentIsParent, !parents.isEmpty { parents[parents.count - 1].text += " " + trimmed }
        } else if let last = parents.last, last.indent >= 0, indent > last.indent {
            // 列表项里空行之后缩进的又一段：还是那一项的话。
            blocks.append((parents.map(\.text) + [trimmed]).joined(separator: " "))
            parents[parents.count - 1].text += " " + trimmed
            current = blocks.count - 1
            currentIsParent = true
        } else {
            parents = [(-1, trimmed)]
            blocks.append(trimmed)
            current = blocks.count - 1
            currentIsParent = true
        }
    }
    return blocks
}

/// 列表项的开头：`- `、`* `、`+ `、`1. `、`1) `。
func recipeListItem(_ trimmed: String) -> Bool {
    trimmed.range(of: #"^([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil
}

/// 卡里的句子：段（recipeBlocks）里再按句号 / 问号 / 叹号切，去掉重复的（父项的话会跟着每个子项再出现一次）。
/// 冒号、分号不切：「超了每日上限：回 needs_confirmation」这种写法要算在同一句里。
func recipeSentences(_ text: String) -> [String] {
    var seen = Set<String>()
    return recipeBlocks(text)
        .flatMap { $0.replacingOccurrences(of: #"([.!?])\s+"#, with: "$1\n", options: .regularExpression).components(separatedBy: "\n") }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
}

/// 讲每日预算 / 积分上限的说法：daily、budget（daily_budget_exceeded 也算）、limit、cap、ceiling、quota、allowance（2026-11-13 补后四种，审查 D6R-03）。
/// cap 要整词：caption、capitals 不算。
func recipeMentionsBudget(_ text: String) -> Bool {
    text.range(of: #"(?i)daily|budget|\blimits?\b|\bcaps?\b|\bcapped\b|\bceilings?\b|\bquotas?\b|\ballowances?\b"#,
               options: .regularExpression) != nil
}

/// 讲确认码那一套：needs_confirmation、confirm_token。
func recipeMentionsConfirmation(_ text: String) -> Bool {
    text.range(of: #"\b(needs_confirmation|confirm_token)\b"#, options: .regularExpression) != nil
}

/// 同一句里既讲每日预算、又讲确认码的句子：每日硬上限之外不发码（SkyStudioJobGate.decide），两件事写成一句就是教 AI 拿码越过预算。
func recipeBudgetConfirmationSentences(_ text: String) -> [String] {
    recipeSentences(text).filter { recipeMentionsBudget($0) && recipeMentionsConfirmation($0) }
}

/// 把 needs_confirmation 说成某一个原因的句子（「needs_confirmation means / is a / = …」）：它是「要用户点头」，原因有好几种
/// （读点名文件夹以外的文件、付费规格超出草稿、一次性费用……），原因写在结果的 question 里（审查 D6R-07）。
func recipeDefinesConfirmation(_ sentence: String) -> Bool {
    sentence.range(of: #"(?i)\bneeds_confirmation\b[\s)"'`]*(means|=|stands for|signals|indicates|is\s+(a|an|the|when|for|only)\b)"#,
                   options: .regularExpression) != nil
}

/// 把「SkyCut 会问」说满的句子：说 SkyCut 问 / 会问，同一句里却既没有 needs_confirmation、也没有 if / when / unless / may / might。
/// 越档问不问看实际返回的：全部权限、用户点名过这个规格、这个工程批准过的都直接起任务（SkyStudioJobGate.decide，审查 D6R-07）。
func recipeClaimsSkyCutAsks(_ sentence: String) -> Bool {
    sentence.range(of: #"(?i)\bSkyCut\s+(then\s+|always\s+|will\s+)?asks?\b"#, options: .regularExpression) != nil
        && sentence.range(of: #"(?i)needs_confirmation|\b(if|when|unless|may|might)\b"#, options: .regularExpression) == nil
}

/// 切法和词表自带的例子：坏话必须抓到、合规的话不许误报（审查 D6R-03：以后改检查不会又漏）。
func runRecipeTextScanSelfChecks() {
    wordingSelfChecks()
    checkEqual(recipeBlocks("- a\n  b\nc"), ["- a b c"], "continuation lines join their block, indented or not")
    checkEqual(recipeBlocks("- a\n  - b\n- c"), ["- a", "- a - b", "- c"], "a nested item carries its parent; a sibling does not")
    checkEqual(recipeBlocks("1. a\n   - b\n     - c\n   - d"), ["1. a", "1. a - b", "1. a - b - c", "1. a - d"],
               "every level of parents is carried, and only the open ones")
    checkEqual(recipeBlocks("p:\n- a\n\n- b"), ["p:", "p: - a", "p: - b"], "a paragraph is carried into the list after it")
    checkEqual(recipeBlocks("- a\n\n  - b"), ["- a", "- a - b"], "a blank line inside a list keeps the parent")
    checkEqual(recipeBlocks("- a\n\nq\n- b"), ["- a", "q", "q - b"], "a new paragraph closes the list above it")
    checkEqual(recipeBlocks("# T\n\n- a"), ["# T", "- a"], "a heading is a name, not carried into what follows")
    checkEqual(recipeBlocks("* a\n+ b\n2) c"), ["* a", "+ b", "2) c"], "every list marker starts an item")
    checkEqual(recipeSentences("A b. C d? E! F: g; h."), ["A b.", "C d?", "E!", "F: g; h."],
               "sentences end at . ? ! but not at : or ;")

    let bad = [
        ("a spending cap", "Over the spending cap, retry with confirm_token."),
        ("a nested list", "- Over the daily limit:\n  - retry with confirm_token."),
        ("a loose nested list", "- Over the daily limit:\n\n  - retry with confirm_token."),
        ("a paragraph leading a list", "Past the daily credit limit:\n- call again with confirm_token."),
        ("a numbered parent", "11. Over the budget:\n    - the result is needs_confirmation."),
        ("a wrapped line", "Over the credit ceiling the result is\nneeds_confirmation."),
        ("the error code itself", "daily_budget_exceeded: ask the user, then call again with confirm_token."),
        ("a quota", "Past today's quota, needs_confirmation asks the user."),
        ("caps", "Credit caps are lifted with confirm_token.")
    ]
    for (name, text) in bad {
        check(!recipeBudgetConfirmationSentences(text).isEmpty, "the scan catches the daily budget tied to the confirmation (\(name)): \(text)")
    }
    let fine = [
        ("siblings", "- daily_budget_exceeded: stop there.\n- needs_confirmation: ask the user and call again with confirm_token."),
        ("separate sentences", "Over the daily limit, stop. needs_confirmation: ask the user, then call again with confirm_token."),
        ("a closed paragraph", "When the result is daily_budget_exceeded, stop.\n\n- needs_confirmation: ask the user."),
        ("a heading", "## Daily budget\n\nneeds_confirmation: ask the user."),
        ("caption and capitals", "Captions and elegant capitals stay; on needs_confirmation, call again with confirm_token."),
        ("no token past the cap", "daily_budget_exceeded is the hard limit: no token or permission mode gets past it.")
    ]
    for (name, text) in fine {
        check(recipeBudgetConfirmationSentences(text).isEmpty, "the scan does not flag what keeps them apart (\(name)): \(text)")
    }
}

/// needs_confirmation 的两种说满（审查 D6R-07 的坏例子）和不该误报的写法。
private func wordingSelfChecks() {
    for bad in ["needs_confirmation means a request beyond the low-cost draft in ask_for_approval mode.",
                "needs_confirmation is a request beyond the draft.", "A result of needs_confirmation = over the draft."] {
        check(recipeDefinesConfirmation(bad), "the scan catches needs_confirmation defined as one cause: \(bad)")
    }
    for fine in ["needs_confirmation, whatever the reason: ask the user the result's question.", "needs_confirmation: ask, as above.",
                 "needs_confirmation is not an error."] {
        check(!recipeDefinesConfirmation(fine), "the scan does not flag: \(fine)")
    }
    for bad in ["Quote it first; in ask_for_approval mode that goes beyond the draft, so SkyCut asks the user.",
                "Remake only the shots you keep: SkyCut will ask the user."] {
        check(recipeClaimsSkyCutAsks(bad), "the scan catches \"SkyCut asks\" stated as a certainty: \(bad)")
    }
    for fine in ["If the call returns needs_confirmation, SkyCut asks the user.", "SkyCut asks only when the call returns that status.",
                 "The opening line asks a question."] {
        check(!recipeClaimsSkyCutAsks(fine), "the scan does not flag: \(fine)")
    }
}
