#!/usr/bin/env bash
# checks/docs-index-drift.sh 的一节：每个代号对应的那句话（哪里不对、为什么不许、怎么改）。
#
# **不单独跑**：由 docs-index-drift.sh 用 `source` 装进来，只定义 explain，用主文件的 INDEX / BUG_DIR / BUG_INDEX 和
# config.sh 的几个数。代号是 lines.sh、judge.sh 和主文件报出来的；自测（self-test.sh）按「[代号]」认红在哪一条上，
# 所以代号改名要连自测的场景一起改。话里不写反引号（双引号里它是命令替换），代码样的字用「」括起来。

# explain <A|B|F> <行号，没有写 0> <代号> <值 1> <值 2> <值 3>
explain() {
  local tag="$1" nr="$2" code="$3" d1="$4" d2="$5" d3="$6" file="" where
  case "${tag}" in
    A) file="${INDEX}" ;;
    B) file="${BUG_INDEX}" ;;
  esac
  where="${file}"
  if [ "${nr}" != "0" ]; then
    where="${file} 第 ${nr} 行"
  fi
  local one_link="链接只许「[字](相对路径.md)」这一种，可以带「#锚点」"
  local entry_shape="顶格的「- [标题](路径.md) — 一句话」"
  case "${code}" in
    # ── 整份文件：字符和链接的写法（lines.sh 第 1、2 步）──
    ctrl)
      echo "${where}：有制表符、回车或别的控制字符 —— 两份索引里只用空格和换行（缩进用空格，行尾不带回车）" ;;
    nul)
      echo "${d1} 里有 NUL 字节：awk 读到它就把这一行截断，后面的内容守卫看不见 —— 删掉它" ;;
    invisible)
      echo "${where}：有看不见的字符（零宽空格、不换行空格、全角空格、文字方向控制符之类）—— 文字是它的链接看不见也点不到，删掉它" ;;
    fence)
      echo "${where}：有代码围栏（反引号或波浪线，套在引用、列表里的也算），或者连着两个以上的反引号、三个以上的波浪线 —— 索引里不放代码块，代码只写成一对反引号的行内代码：围栏里的路径看着像索引，其实点不开" ;;
    tick)
      echo "${where}：反引号不成对 —— 行内代码不许跨行（跨了行，守卫和 Markdown 对「哪一段是代码」的看法就不一样了）" ;;
    html)
      echo "${where}：行内代码以外出现了「<」—— 索引里不许写 HTML（a 标签、注释、自动链接）：注释里的链接没人看得见，a 标签里的死链守卫不查；要写尖括号就放进反引号" ;;
    blank_code)
      echo "${where}：有一段空的行内代码（一对反引号里只有空格）—— 拿它当链接的文字，链接就看不见" ;;
    math)
      echo "${where}：行内代码以外出现了「\$」—— 有的渲染器把两个「\$」之间当公式，里面的链接就不是链接了；要写就放进反引号" ;;
    entity)
      echo "${where}：行内代码以外出现了 HTML 实体（「&#8203;」「&nbsp;」这一类）—— 它能写出看不见的字；直接写那个字，或放进反引号" ;;
    title)
      echo "${where}：第一行要是「# 标题」—— 文件开头不许放 front matter（两道「---」之间的内容渲染出来不是正文，里面的链接点不开）" ;;
    backslash)
      echo "${where}：行内代码以外出现了反斜杠 —— 转义会让看着像链接的东西不是链接；要写就放进反引号" ;;
    image)
      echo "${where}：「![…](…)」是图片不是链接 —— ${one_link}" ;;
    link_text)
      echo "${where}：链接的文字里没有看得见的字 —— 至少要有一个字母、数字或汉字（行内代码里的也算）；只有空格、细空格、盲文空白这类空白的文字看不见，点不到的链接等于没有" ;;
    target)
      echo "${where}：链接 (${d1}) 不是规定的写法 —— ${one_link}；路径只用字母、数字、「.」「_」「-」「/」，不以「/」开头、不带「./」、「../」只许写在最前面，不带标题、不用尖括号、不链网址" ;;
    bracket)
      echo "${where}：方括号只许用在链接里 —— ${one_link}；引用式链接和它的定义（「[字][名]」「[名]: 路径」）、脚注、任务框「- [ ]」、套在链接里的链接、带括号的路径都不许：守卫只认一种链接，别的写法它既查不了死链也不算索引。正文里要写方括号就放进反引号" ;;
    codeblock)
      echo "${where}：这一行会被当成代码块（里面的链接点不开）—— 缩进的行只许接在列表项后面（续行或嵌套的列表），空行、标题、表格、普通段落后面不许；列表记号后面只空一格" ;;
    # ── 小节的形状（lines.sh 第 3–6 步）──
    long)
      echo "${where} 有 ${d1} 字节，超过 ${ENTRY_MAX_BYTES}：索引小节里每一行（条目、表格行、开头的说明、小标题）只写「链接 + 一句话」，摘要和细节写进它指向的文档" ;;
    intro)
      echo "${where}：这一节条目以外的行（开头的说明、小标题、表头）到这里是 ${d1} 行，超过 ${INTRO_MAX_LINES}：说明只写怎么用这份索引，摘要写进文档" ;;
    entry_form)
      echo "${where}：条目只有一种写法 —— ${entry_shape}：链接紧跟在「- 」后面，接着是空格、破折号、空格和一句话" ;;
    entry_links)
      echo "${where}：一条索引正好一个链接（开头那一个）—— 一句话里不再链别的文档；要链就给那份文档单独写一条" ;;
    bare_entry)
      echo "${where}：这一行以链接开头却不是条目 —— 条目写成${entry_shape}；说明里的链接别放在行首" ;;
    marker)
      echo "${where}：索引条目只有一种写法 —— ${entry_shape}；别的列表记号（+、*、1.）和不以链接开头的「- 」都不算条目，每条 ${ENTRY_MAX_BYTES} 字节的上限也就管不到它" ;;
    indent)
      echo "${where} 是缩进的行：在索引里它是上一条的续行或嵌套的列表，摘要会借它长回去 —— 条目写成顶格的一行，细节写进它指向的文档" ;;
    quote)
      echo "${where}：索引小节里不许用「>」引用 —— 引用里的条目不算条目，上限、顺序、重复都管不到它；条目写成${entry_shape}" ;;
    rule)
      echo "${where}：分隔线、标题下划线（「---」「===」「--- | ---」）不许出现在索引小节里 —— 表格的分隔行只许紧跟在以「|」开头的表头下面" ;;
    after)
      echo "${where} 接在索引条目（或表格）后面，既不是条目也不是小标题：紧跟着时它是上一条的续行，隔了空行就是夹在索引里的一段摘要 —— 并进那一条的一句话，或写进它指向的文档；说明写在这一节的条目前面，表格后面空一行" ;;
    glued)
      echo "${where}：表头前面要空一行（或紧跟小标题）—— 紧跟在一条「- [」索引或一行说明后面，在 Markdown 里它是那一段的续行" ;;
    table_head)
      echo "${where}：以「|」开头的行不成表格 —— 表头下面要紧跟分隔行（「| --- | --- |」），两行的列数一样、行尾都是「|」，行内代码里不写「|」。不成表格的竖线行在 Markdown 里只是一段普通的话，摘要会借它塞回来" ;;
    table_row)
      echo "${where}：表格行的列数和表头对不上、行尾不是「|」，或者行内代码里写了「|」" ;;
    row_links)
      echo "${where}：表格的每一行正好一个链接（一行 = 一条索引：链接 + 一句话）—— 没有链接的行是上一行的续行，两个链接就拆成两行" ;;
    table)
      echo "${where}：${BUG_INDEX} 是纯列表，不许表格 —— 条目写成${entry_shape}（表格里的条目进不了顺序和重复检查）" ;;
    entry_in_free)
      echo "${where}：以链接开头的列表项是索引条目的写法，这一节却不设单条上限 —— 条目放进索引小节（那里每条 ${ENTRY_MAX_BYTES} 字节）；规则里要提一份文档，把链接写在句子中间" ;;
    pointer_shape)
      echo "${where}：「${POINTER_SECTION#"## "}」一节只留指路的话 —— 只许普通的一行或「- 」开头的一行，不许表格、引用、缩进、小标题、别的列表记号" ;;
    free_missing)
      echo "守卫登记的不设单条上限的小节「${d1}」在 ${INDEX} 里没有、或不止一个：改了标题就同步改 checks/docs-index-drift/config.sh 的 FREE_SECTIONS，不然那一节会被当成索引小节来管" ;;
    index_missing)
      echo "守卫登记的索引小节「${d1}」在 ${INDEX} 里没有、或不止一个：去掉标题，它下面的条目就并进上一节 —— 改了标题就同步改 checks/docs-index-drift/config.sh 的 INDEX_SECTIONS" ;;
    pointer_missing)
      echo "${INDEX} 里没有「${d1}」一节、或不止一个：守卫失去目标，Bug 案例的条目会混进别的小节 —— 改了标题就同步改 checks/docs-index-drift/config.sh 的 POINTER_SECTION" ;;
    case_entry)
      echo "${where}：这份索引的条目只列同文件夹的案例 —— 链接写「YYYY-MM-DD-<slug>.md」（或「TEMPLATE.md」），不带路径、不带「#锚点」；现在写的是 (${d1})" ;;
    entry_date)
      echo "${where}：条目的文字要以文件名里的日期开头（「${d1%"${d1#??????????}"} 标题」）—— 索引不按日期排，日期靠每条自己带着" ;;
    # ── 链接对着磁盘（judge.sh）──
    escape)
      echo "${where}：链接 (${d1}) 指到仓库外面去了" ;;
    dead)
      echo "${where} 指向了不存在的 ${d1}：死链比没有索引更坏 —— 它会让人以为查过了。只认普通文件，大小写也要一字不差；${BUG_INDEX} 里的链接按 ${BUG_DIR}/ 解析（同文件夹写 xxx.md，别的文件夹写 ../architecture/xxx.md）" ;;
    unindexed_case)
      echo "${d1} 没有在 ${BUG_INDEX} 里当条目列着：只读 AGENTS.md 的代理顺着它找案例，漏一行等于这份案例不存在 —— 补一行「- [日期 标题](${d2}) — 一句教训」，按文件名里日期后面那一段的字母序插；插错了守卫会说该排在谁上面" ;;
    unindexed)
      echo "${d1} 没有出现在 ${INDEX} 的索引里：只读 AGENTS.md 的代理永远打不开它 —— 按「文档目录职责」补一行到对应的索引小节（要「[字](路径.md)」这样点得开的链接：行内代码、注释、代码块里的路径不算）" ;;
    no_index_link)
      echo "${INDEX} 没有链到 ${BUG_INDEX}：Bug 案例的索引从入口断了，只读 AGENTS.md 的代理一份案例都找不到 —— 「${POINTER_SECTION#"## "}」一节要链着它" ;;
    stray_case)
      echo "${where}：这里不许链 ${BUG_DIR}/ 下的案例 (${d1})，不管前面是什么记号 —— 案例的条目只进 ${BUG_INDEX}（按文件名里日期后面那一段插，链接写同文件夹的 xxx.md）；AGENTS.md 的索引小节和「${POINTER_SECTION#"## "}」一节只许链 INDEX.md 和 TEMPLATE.md，改某块代码该读的案例链在必读表里" ;;
    intro_case)
      echo "${where}：说明里不许链 ${BUG_DIR}/ 下的文件 (${d1}) —— 案例只当条目列（${entry_shape}），才进顺序和重复检查" ;;
    dup)
      echo "${where} 又列了一次 ${d1}（第 ${d2} 行已经有了）：同一份案例列了两次 —— 多半是解冲突时两边的改动都留下了；留一条，把两边的改动并进那一条" ;;
    dup_agents)
      echo "${where} 又把 ${d1} 当了一次条目（第 ${d2} 行已经有了）：同一份文档在 ${INDEX} 的索引小节里只列一次 —— 留一条，把两边的话并进那一条" ;;
    template_first)
      echo "${where}：模板那一行（TEMPLATE.md）留在最上面，排在所有案例前面" ;;
    order)
      echo "${where}的 ${d1} 该排在第 ${d2} 行的 ${d3} 上面：整份按文件名里日期后面那一段的字母序排（不看日期；LC_ALL=C 的字节序，这一段相同的再按日期），新案例插到它该在的地方，别都加在模板下面 —— 两个同时开着的 PR 都加在同一处，后合的那个必撞" ;;
    order_last)
      echo "${where}的 ${d1} 该排在最后：整份按文件名里日期后面那一段的字母序排（不看日期；LC_ALL=C 的字节序，这一段相同的再按日期）" ;;
    # ── docs/ 下的文件（主文件第 1 步）──
    name)
      echo "${d1}：docs/ 下文档的路径只许字母、数字、「.」「_」「-」（和分隔用的「/」）—— 索引里的链接只认这样的路径，带空格、括号、中文的文件名链不上" ;;
    case_name)
      echo "${d1}：${BUG_DIR}/ 下只放「YYYY-MM-DD-<slug>.md」、TEMPLATE.md 和 INDEX.md，不建子文件夹 —— ${BUG_INDEX} 按文件名里日期后面那一段排，别的名字排不了" ;;
    symlink)
      echo "${d1} 是符号链接：docs/ 下的文档只许是普通文件 —— 符号链接不算文档（不占上限），索引也链不到它" ;;
    ext)
      echo "${d1}：文档的后缀只许小写的「.md」—— 别的写法（.MD、.markdown、.mdx）守卫当它不是文档，漏了索引也不红" ;;
    size)
      echo "${INDEX} 有 ${d1} 字节，超过上限 ${d2}（${SIZE_BASE_BYTES} + ${SIZE_PER_DOC_BYTES} × ${d3} 份 ${BUG_DIR}/ 以外的文档）：每个会话一开就整份读它 —— 必读表右列只留链接和一两条硬约束、检查入口每个脚本一行、索引每条一句话，细节挪进文档（docs/testing/check-catalog.md 或对应的架构文档），Bug 案例的条目只进 ${BUG_INDEX}；必读表里的旧案例链接只许撤一种：同一行链着的架构文档已经写了那条规矩、并且那份架构文档里链着这份案例（案例照旧留在 ${BUG_INDEX}）；别抬上限" ;;
    *)
      echo "${where}：守卫自己认不出的代号「${code}」（检查脚本写错了）" ;;
  esac
}
