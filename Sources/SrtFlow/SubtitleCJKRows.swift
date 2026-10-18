import Foundation
import SrtFlowCore

// MARK: - 有中日文的一段字幕折成几行、断在哪（纯值）
//
// 管什么：`SubtitleLineWrap` 量好每个字的墨迹和步进之后，有中日文的段（`SubtitleRowBreaks.isCJK`）交到这里挑折行点：
// 1. 能断的地方和代价问 SrtFlowCore 的 `SubtitleRowBreaks`（文字的规矩：中日文只在词和词之间断、句中的空格和标点后面好断、助词不起头……）；
//    断在一个词中间的那几处只给比一整行还宽的词用（量它的墨迹）。
// 2. 最少几行能放下：每行从第一个字的墨迹左沿到最后一个字的墨迹右沿不到最大宽；一个断不开的东西（一个超长的英文单词）比一行还宽就让它
//    自己一行、溢出，同 libass。
// 3. 这几行里挑代价最小的折法：摊匀（每行偏离平均的比例的平方，乘 2 / 行数 —— 两行时就是生成字幕挑折行点的 2 × imbalance²，
//    `SubtitleBreaks.displayLines`）+ 每个断点的代价；一样好时上面的行短（Netflix：底重）。
// 以前（2026-10-15 起）中日文任意两个字之间都能断、只按宽度摊匀，词被拆在两行（「抖 / 音」「以 / 及」「字 / 节跳动」「Nano / Banana」），
// 句中的空格（去掉的逗号）反而不优先（docs/bugfixes/2026-10-18-subtitle-wrap-splits-chinese-words.md）。
// 不管什么：字多宽（`SubtitleLineWrap.glyphs`）、没有中日文的段（libass 的贪心 + 摊匀，SubtitleLineWrap）、行首行尾的空格（`trimmed`）。

enum SubtitleCJKRows {
    /// 每个字前面要不要断一行（和 `SubtitleLineWrap` 的软断同一个意思，按 `g` 的下标）。
    static func softBreaks(_ g: [SubtitleLineWrap.Glyph], text: String, maxWidth: Double) -> [Bool] {
        let costs = breakCosts(g, text: text, maxWidth: maxWidth)
        let cuts = [0] + g.indices.filter { costs[$0] != nil } + [g.count]
        let rows = Rows(g: g, cuts: cuts, maxWidth: maxWidth)
        guard let count = rows.fewest(), count > 1, let chosen = rows.cheapest(count, costs: costs) else {
            return [Bool](repeating: false, count: g.count)
        }
        var soft = [Bool](repeating: false, count: g.count)
        for cut in chosen { soft[cut] = true }
        return soft
    }

    /// 每个字前面能不能断、代价多少（nil = 不能）：一个字形串只在第一个字形前面断；词中间的只给比一行还宽的词。
    private static func breakCosts(_ g: [SubtitleLineWrap.Glyph], text: String, maxWidth: Double) -> [Double?] {
        let breaks = SubtitleRowBreaks.breaks(in: text)
        var costs = [Double?](repeating: nil, count: g.count)
        for i in g.indices.dropFirst() where !g[i].isSpace && g[i].index != g[i - 1].index {
            guard let found = breaks[g[i].index] else { continue }
            if let word = found.insideWord {
                guard let first = g.firstIndex(where: { $0.index >= word.location }),
                      let last = g.lastIndex(where: { $0.index < NSMaxRange(word) }),
                      g[last].inkRight - g[first].inkLeft >= maxWidth else { continue }
            }
            costs[i] = found.cost
        }
        return costs
    }
}

/// 在这些断点（`cuts`：第一个是 0、最后一个是字数）上分行：放不放得下、最少几行、恰好几行时最省的分法。
private struct Rows {
    let g: [SubtitleLineWrap.Glyph]
    let cuts: [Int]
    let maxWidth: Double

    /// 从 `cuts[x]` 到 `cuts[y]` 这一行（去掉两头的空格）的墨迹宽；只有空格是 nil。
    func width(_ x: Int, _ y: Int) -> Double? {
        var first = cuts[x], last = cuts[y] - 1
        while first <= last, g[first].isSpace { first += 1 }
        while last >= first, g[last].isSpace { last -= 1 }
        return first <= last ? g[last].inkRight - g[first].inkLeft : nil
    }

    /// 这一行放得下：墨迹不到最大宽，或者中间没有能断的地方（断不开的东西自己一行、溢出）。
    func fits(_ x: Int, _ y: Int) -> Bool {
        (width(x, y) ?? 0) < maxWidth || y == x + 1
    }

    /// 最少几行。
    func fewest() -> Int? {
        var rows = [Int?](repeating: nil, count: cuts.count)
        rows[0] = 0
        for y in 1..<cuts.count {
            for x in 0..<y {
                guard let before = rows[x], fits(x, y) else { continue }
                rows[y] = min(rows[y] ?? .max, before + 1)
            }
        }
        return rows[cuts.count - 1]
    }

    /// 恰好 `count` 行、代价最小的分法：返回断在哪几个字前面。
    func cheapest(_ count: Int, costs: [Double?]) -> [Int]? {
        let total = width(0, cuts.count - 1) ?? 0
        guard total > 0 else { return nil }
        let mean = total / Double(count)
        let m = cuts.count
        var best = [[Double]](repeating: [Double](repeating: .infinity, count: m), count: count + 1)
        var from = [[Int]](repeating: [Int](repeating: -1, count: m), count: count + 1)
        best[0][0] = 0
        for row in 1...count {
            for y in 1..<m {
                for x in 0..<y where best[row - 1][x] < .infinity && fits(x, y) {
                    let w = width(x, y) ?? 0
                    var cost = best[row - 1][x] + 2 / Double(count) * (w - mean) * (w - mean) / (mean * mean)
                    if x > 0 { cost += costs[cuts[x]] ?? 0 }
                    cost += 1e-7 * Double(count - row) * w / total   // 一样好时上面的行短（底重）
                    if cost < best[row][y] {
                        best[row][y] = cost
                        from[row][y] = x
                    }
                }
            }
        }
        guard best[count][m - 1] < .infinity else { return nil }
        var result: [Int] = []
        var y = m - 1
        for row in stride(from: count, to: 0, by: -1) {
            let x = from[row][y]
            if x > 0 { result.append(cuts[x]) }
            y = x
        }
        return result.reversed()
    }
}
