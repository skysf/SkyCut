# 2026-10-28 检查器 Upscale 那一节还写着「fal.ai」

## 症状

upscale 改走 Sky Studio（#268）之后，选中一个画面段，右边检查器「Upscale」那一节标题的右边还是一行灰色小字「fal.ai」。面板、对比窗口、状态行都已经写的是 Sky Studio 和积分，只有这一处还说送去 fal。

是收费方案第 6 刀真积分测试（测试版 0.18.50）时，看面板截图才发现的，还没发版。

## 根因

#268 换提供方时，按「花钱、Key、报价、文案里的 fal」逐个搜过 upscale 的代码。但这个标签是 `Text(verbatim: "fal.ai")`：不走字符串表，也不是一句话，按词搜英文文案、对字符串表都漏掉了它。自检够不着界面上的这一行字，守卫只钉了接线和账，没钉「界面上说送去哪」。

## 修复

`Sources/SrtFlow/VideoEditInspector+Upscale.swift`：标签改成 `Text(verbatim: "Sky Studio")`。产品名不翻译，照旧 verbatim。

## 验证

- `checks/sky-studio-wiring.sh` 第 8 条加了两条：
  - 检查器那一节和 `Sources/SrtFlow/Upscale/` 下的文件里（去掉注释后）不许再出现带 `fal.ai` 的字符串；
  - 检查器标题旁写的是 Sky Studio。
- 反向验证：把这个文件换回修改前的版本，两条都红；恢复后转绿。
- 增量构建通过。下一版测试版装上后在检查器里看一眼。

## 教训 / 防回归

- 换提供方要搜的不只是文案和字符串表，还有 `verbatim` 写死的名字。产品名、服务名常常 verbatim，按「要翻译的话」去搜是搜不到的。
- 界面上说「送去哪、花谁的钱」的地方要有守卫，钉住名字和提供方一起换。
