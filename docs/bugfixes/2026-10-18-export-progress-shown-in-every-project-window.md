# 2026-10-18 别的工程的导出显示在每个工程窗口里，还能从这里停掉

## 症状

AI 多开补测（测试版 0.18.42，屏幕亮着）：主窗口是用户的 p1，AI 在后台剪 p3。

- 在 p1 的导出面板上导出一条，导着的时候 AI `export_video project=p3`：AI 那条照设计排队（`queued`、`queue_position` 1），面板那条导完它自己开始。
  可这时 **p1 的面板里显示「Exporting… 0%」和一个停止键** —— 导的是 p3；导完，p1 的面板里又挂着 p3 的成片「Short while panel.mp4 ✓ 在访达里显示」
  和 p3 的响度，像是 p1 导出来的。
- 之前一个工程导出时，另一个工程窗口的预览条上也有一个停止键（13×13 的 `stop.circle`）、工具栏上有进度条 —— 都是别的工程的导出。

点 p1 面板或窗口里的停止，停掉的是 p3 的 AI 导出：用户以为停的是自己的，AI 那边只看到任务被取消。方案板 4 定的是「停止 / 撤销按工程」，这里一个窗口能停所有工程的导出。

## 根因

导出器全 App 只有一个（`VideoEditExporter.shared`，一次只导一条），它的 `isExporting` / `progress` / `finishedURL` / `errorMessage` 不知道是哪个工程的。
多开之前只有一个工程，「导出器的状态」就是「这个工程的导出」；第 ① 刀加了工程窗口时，文档里写的是「B 窗口的工具栏也显示 A 的导出进度、导出按钮也灰着」，
当成可以接受的现状；后面几刀让 AI 在后台剪、在后台导，这个现状就变成了：用户窗口里的进度、成片是别人的，停止键能停别人的。

## 修复

- 导出器记下这次导的是哪个工程（`owner`：工程代号 + 名字，`export(for: project, …)`；面板和 AI 两条开始导出的路都传），`belongs(to:)` 问是不是这个工程的
  （`Sources/SrtFlow/VideoEditExporter.swift`）。
- 编辑窗口：工具栏的进度条、预览条上的停止只在导的是这个工程时出现；别的工程在导时工具栏的「导出」照样能点开面板（`Sources/SrtFlow/VideoEditView.swift`，同行改、不加行）。
- 导出面板：底栏「这次导出怎么样了」搬进自己的小视图 `VideoEditExportStatus`（面板 423 → 376 行）：进度、报错、成片和响度只给这个工程看；
  别的工程在导时写一行「“名字”正在导出… 42%。它导完，这个工程才能导出」，导出键是灰的，没有停止键（`Sources/SrtFlow/VideoEditExportSheet.swift`、
  `Sources/SrtFlow/VideoEditExportStatus.swift`）。新文案三张表都配了。
- AI 的导出照旧排队（`AIWorkQueue` 看的还是「导出器空不空」）；AI 停自己工程的导出走 `cancel_job` 和横幅 / 侧边栏的停止，不受影响。

## 验证

- 扫描守卫 `checks/open-projects-wiring.sh` 第 14 条：编辑窗口和导出面板里不许只看 `exporter.isExporting` 就显示进度 / 停止；状态视图要先问
  `exporter.belongs(to: project)`；每个 `exporter.export(` 都要带 `for: project`。反向验证：预览条上的停止改回只看 `isExporting`、AI 的导出去掉 `for: project`、
  状态视图不问是谁的，三处各自当场红，恢复后绿。
- 界面文案覆盖（`scripts/check-localization-coverage.sh`）：996 条在 en / es / zh-Hans 每张表里都有。
- 真机：合进去之后出测试版，重放「面板在导 p1、AI 排着 p3」和「两个工程窗口、一个在导」，看两个窗口的工具栏、预览条和面板，结果写进这次补测的报告。

## 教训 / 防回归

- **单例的状态在多开之后要问「是谁的」**：导出器、转写槽、翻译宿主这类全 App 一个的东西，状态读出来给界面看之前，先确认读的人是不是它的主人。
  能共用的是「忙不忙」（导出键灰不灰、要不要排队），不能共用的是「进度、成片、停止」。
- 文档里写「B 窗口也显示 A 的进度」时，要追问一句「那 B 窗口里的停止停的是谁」—— 显示和动作是两件事。
