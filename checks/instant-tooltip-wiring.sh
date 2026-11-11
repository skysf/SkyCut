#!/usr/bin/env bash
# 扫描守卫：全 App 的提示只能走 `.instantHelp`，不许再用系统的 `.help`。
#
# 由来：系统 tooltip 有约 1 秒首次延迟，延迟归私有的 NSToolTipManager 管，没有
# 公开 API 能调。产品要求是「鼠标一放上去就出现，并且写着快捷键」，所以提示
# 改由 InstantTooltip.swift 自己画。留一处 `.help(` 就是留一个「这个按钮的提示
# 慢一秒、还不显示快捷键」的洞，而这种洞肉眼扫一遍 UI 根本发现不了。
#
# 长期约束见 docs/architecture/instant-tooltips.md。
set -euo pipefail
cd "$(dirname "$0")/.."

# **不要用 `git ls-files`**：新写的文件常常还没 add，会被静默跳过（no-hardcoded-fps
# 那条守卫踩过这个坑）。用文件系统枚举，未跟踪的文件也在保护范围内。
SWIFT_FILES=$(find Sources/SrtFlow -name '*.swift' | sort)

FAIL=0

# ---- 1. 不许再出现系统 tooltip ----
#
# 匹配 `.help(` 而不是 `help(`：`ToolbarIcon(icon:help:)` 那种参数标签是合法的。
# 注释行要排掉 —— InstantTooltip.swift 的文档注释里正写着「为什么不用 .help」，
# 守卫扫到自己的说明文字就报错，只会逼着后人把解释删掉。
HITS=$(printf '%s\n' "${SWIFT_FILES}" | xargs grep -n '\.help(' \
    | grep -vE ':[0-9]+:[[:space:]]*//' || true)
if [ -n "${HITS}" ]; then
    echo "✗ 还有地方在用系统的 .help(（有 1 秒延迟，也不显示快捷键）：" >&2
    printf '%s\n' "${HITS}" >&2
    echo "  改用 .instantHelp(\"…\", shortcut: …)，见 docs/architecture/instant-tooltips.md" >&2
    FAIL=1
fi

# ---- 2. 快捷键不许和提示分家 ----
#
# `.keyboardShortcut` 只剩两种合法用法：`.defaultAction`（对话框默认按钮，
# 等价符由它提供、键帽由 `.instantHelp(shortcut: .defaultAction)` 显示），
# 以及 SrtFlowApp.swift 里的菜单命令（菜单自己会画快捷键，没有 hover 一说）。
# 其余一律要走 `HelpShortcut` —— 分开写，提示上的 ⌘B 和真正生效的键迟早对不上。
STRAY=$(printf '%s\n' "${SWIFT_FILES}" \
    | grep -v 'Sources/SrtFlow/SrtFlowApp.swift' \
    | grep -v 'Sources/SrtFlow/InstantTooltip.swift' \
    | xargs grep -n 'keyboardShortcut(' \
    | grep -v 'keyboardShortcut(.defaultAction)' || true)
if [ -n "${STRAY}" ]; then
    echo "✗ 快捷键没有和提示绑在一起（提示里的键帽会和真正生效的键漂移）：" >&2
    printf '%s\n' "${STRAY}" >&2
    echo "  改成 .instantHelp(\"…\", shortcut: .command(\"B\")) 之类，让两者只有一个来源。" >&2
    FAIL=1
fi

# ---- 3. 提示文案的翻译 ----
#
# 「每条提示都要在 en / zh-Hans 两张表里有」已经并进全局守卫
# `scripts/check-localization-coverage.sh`（它连 Text/Label/Button 一起扫，还能
# 认出换行写的调用）。这里不再重复一份 —— 同一条规则维护两处，迟早各走各的。

# ---- 4. 字面量必须走查表那条重载 ----
#
# 2026-08-12 的第二次事故：`instantHelp` 有两个重载（`LocalizedStringKey` 和
# `S: StringProtocol`），而**字符串字面量在重载决议里优先选默认字面量类型
# `String`** —— 于是全 App 的 `.instantHelp("…")` 一直走的是 verbatim 那条，
# 从头到尾没查过表。表里补再多译文也没用，中文界面照样显示英文。
# 系统的 `.help` 靠 `@_disfavoredOverload` 压住这个坑，这里改用参数标签
# `verbatim:`：无标签的门只剩 `LocalizedStringKey`，字面量无处可去。
INSTANT="Sources/SrtFlow/InstantTooltip.swift"
if ! grep -q 'func instantHelp(_ text: LocalizedStringKey' "${INSTANT}"; then
    echo "✗ 无标签的 instantHelp 必须收 LocalizedStringKey（那是查表的那条）" >&2
    FAIL=1
fi
if ! grep -q 'func instantHelp<S: StringProtocol>(verbatim text:' "${INSTANT}"; then
    echo "✗ 不查表的那条必须带 verbatim: 标签（去掉标签，字面量就会被它抢走）" >&2
    FAIL=1
fi
if grep -qE 'func instantHelp<[^>]*>\(_ ' "${INSTANT}"; then
    echo "✗ 又出现了无标签的泛型 instantHelp：字面量会优先选它（String），永远不查表" >&2
    FAIL=1
fi
LITERAL_VERBATIM=$(printf '%s\n' "${SWIFT_FILES}" | xargs grep -n 'instantHelp(verbatim: "' || true)
if [ -n "${LITERAL_VERBATIM}" ]; then
    echo "✗ 字面量走了 verbatim（那是给路径/素材名的，写死的文案要能翻译）：" >&2
    printf '%s\n' "${LITERAL_VERBATIM}" >&2
    FAIL=1
fi

# ---- 5. 提示面板自己的四条硬约束 ----
#
# 面板不能吃鼠标事件：吃了就会立刻触发下面控件的 hover(false)，
# 提示消失 → 鼠标回到控件 → 又弹出来，肉眼看到的是闪烁。
if ! grep -q 'panel.ignoresMouseEvents = true' Sources/SrtFlow/InstantTooltip.swift; then
    echo "✗ 提示面板必须 ignoresMouseEvents（否则会自己把自己闪没）" >&2
    FAIL=1
fi
# 「立刻出现」的另一半：默认的淡入动画会让它慢半拍。
if ! grep -q 'panel.animationBehavior = .none' Sources/SrtFlow/InstantTooltip.swift; then
    echo "✗ 提示面板必须关掉出现动画（产品要求是「立刻」）" >&2
    FAIL=1
fi
# 锚点层铺在控件上，绝不能吃点击。
if ! grep -q 'override func hitTest(_ point: NSPoint) -> NSView? { nil }' Sources/SrtFlow/InstantTooltip.swift; then
    echo "✗ 提示的锚点层必须 hitTest 返回 nil（否则按钮会按不动）" >&2
    FAIL=1
fi
# NSHostingView 直接当 contentView，会把自己的尺寸约束灌成面板的 contentMinSize
# （一条 24pt 的提示报出 min 高 332），面板被撑高后气泡垂直居中，看上去就是
# 「提示弹在很远的地方」。中间必须垫一层普通 NSView。
# 真实落点由 scripts/check-instant-tooltip-panel.sh 量，这里只挡住写法回潮。
if ! grep -q 'panel.contentView = container' Sources/SrtFlow/InstantTooltip.swift; then
    echo "✗ 提示面板的 contentView 必须是普通容器视图（NSHostingView 会把尺寸约束灌给窗口）" >&2
    FAIL=1
fi

# ---- 6. 提示的根要裁成气泡的形状（森林色「提示外面套一圈直角方框」） ----
#
# 根上的 `.appLanguage()` 带着主题的窗口底色（森林色是整块矩形的暖白），面板是透明的、形状全由内容决定：
# 不裁的话暖白的直角露在圆角气泡外面，窗口服务器的影子 / 描边也按矩形算
#（docs/bugfixes/2026-11-11-tooltip-square-frame-in-forest-theme.md）。裁切必须在 `.appLanguage()` 外面
#（裁在里面，主题的底色照样铺满矩形），并且和气泡的底、描边是同一个形状 `TooltipContent.bubble`。
# 四角真的透不透明由 scripts/check-instant-tooltip-panel.sh 第 6 段离屏渲一张量，这里只挡住写法回潮。
# perl 放进带引号的 heredoc，一个字都不经 shell 展开（shell 陷阱 5）。
read -r -d '' ROOT_PROG <<'PERL' || true
local $/;
my $src = <>;
my $ok = 0;
while ($src =~ /NSHostingView\(/g) {
    my $start = pos($src) - 1;
    my ($depth, $end) = (0, undef);
    for (my $j = $start; $j < length($src); $j++) {
        my $c = substr($src, $j, 1);
        if ($c eq '(') { $depth++ }
        elsif ($c eq ')') { $depth--; if ($depth == 0) { $end = $j; last } }
    }
    next unless defined $end;
    my $args = substr($src, $start, $end - $start + 1);
    $ok = 1 if $args =~ /TooltipContent\(.*?\)\s*\.appLanguage\(\)\s*\.clipShape\(TooltipContent\.bubble\)/s;
}
print $ok ? "ok" : "missing";
PERL
ROOT_CLIP="$(perl -e "${ROOT_PROG}" "${INSTANT}")"
if [ "${ROOT_CLIP}" != "ok" ]; then
    echo "✗ 提示面板的根必须在 .appLanguage() 外面裁成气泡的形状：.clipShape(TooltipContent.bubble)" >&2
    echo "  （不裁的话森林色的暖白底铺满矩形，气泡外面露出一圈直角方框，影子也按矩形算）" >&2
    FAIL=1
fi
# 气泡的形状只许有一份：底、描边、根上的裁切都用 TooltipContent.bubble，不然裁的和画的迟早不是一个形状。
BUBBLE_LITERALS="$(grep -E 'RoundedRectangle\(cornerRadius: 6\)' "${INSTANT}" | grep -cvE '^[[:space:]]*//' || true)"
if [ "${BUBBLE_LITERALS}" -ne 1 ] || ! grep -q 'static let bubble = RoundedRectangle(cornerRadius: 6)' "${INSTANT}"; then
    echo "✗ 气泡的形状只许写一处（static let bubble），现在 RoundedRectangle(cornerRadius: 6) 出现 ${BUBBLE_LITERALS} 处" >&2
    FAIL=1
fi
if ! grep -q 'background(.regularMaterial, in: Self.bubble)' "${INSTANT}" || ! grep -q 'Self.bubble.strokeBorder(' "${INSTANT}"; then
    echo "✗ 气泡的底和描边必须用 TooltipContent.bubble（和根上裁的是同一个形状）" >&2
    FAIL=1
fi

if [ "${FAIL}" -ne 0 ]; then
    exit 1
fi
echo "✓ 提示接线守卫通过（扫描 $(printf '%s\n' "${SWIFT_FILES}" | wc -l | tr -d ' ') 个文件）"
