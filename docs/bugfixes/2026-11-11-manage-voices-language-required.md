# 2026-11-11 manage_voices 建声音 / 加录音非要 AI 给 language，方案写的是可选、自动识别

## 症状

AI 调 `manage_voices`（`create` 或 `add_reference`）不带 `language`，当场回「language is required.」，什么都没做。
[SkyCut 声音方案](../plans/2026-11-09-voice-features.md) 4.6 写的是 `language` 可选、不给就自动识别；同一段录音在设置里的新建声音对话框里，
「语言」那一行是本机识别好、预选上的。AI 这一路只能自己猜（从文件名、从对话用的语言）或者多问用户一句，猜错了声音就记成了别的语言——
这一版一段录音的语言改不了，只能删了重建。用户还没撞上（声音库的工具 2026-11-10 才合进 main），协调的会话对照方案核对时发现的。

## 根因

- 声音 PR 6（#362）做 `manage_voices` 时，「这段声音说的是哪种语言」的两段式检测还写在 `TranscriptHarvester.detectSourceLocale` 里面，
  只有生成字幕够得着。那一刀把 `language` 做成必填，文档里记了一句「这一刀要 AI 给，本机检测随声音库界面接」。
- 声音 PR 8（#367）做界面时把候选和裁决原样挪进了 `SpokenLanguageProbe`、给对话框接上（`VoiceSampleLanguage`），**没有回头把工具也接上**：
  那句「随界面接」没有登记成待办，也没有任何一条检查对着方案的「可选」——工具的检查每一条都带着 `language`，说明书和参数说明照着实现写成了必给。
- 所以三处一起错：实现（`requiredString("language")`）、给 AI 的话（说明书「create needs file, name and language」）、文档。

## 修复

- `SkyStudioVoiceRecordingLanguage`（新文件，`Sources/SrtFlow/SkyStudio/`）定下录音的语言：
  - AI 给了：核对写法、照它的，**不识别、不拿识别的结果盖掉**（识别只在这台 Mac 装了的语言里裁决，认错的正是没装的那一种；AI 多半是照用户说的填的）。
    写错的照旧报错，不悄悄改成识别；给空的算没给。
  - 没给：在**做好的参考录音**上识别，和对话框同一份——`SkyStudioVoiceServices.detectLanguage` 的默认值就是 `VoiceSampleLanguage.detect`
    （→ `SpokenLanguageProbe`：macOS 26、只在已装的转写语言里裁决、不为它下载模型、探针是参考录音的前 20 秒）。不另写候选 / 裁决。
  - 识别不出来（把握不够、一个模型都没装、macOS 15）：**不猜**，一样都不问、不传，回 `reason: language_undetected` 和一句 AI 能照做的话
    ——「Call manage_voices again with language (…ISO 639-1…); ask the user if you are not sure. Nothing was sent.」照 `AIHarvestFailure` 的说法，
    不叫它去点界面（[案例](2026-09-29-ai-told-to-pick-language-in-panel.md)）。
- `SkyStudioVoiceRecordingTool`：识别放在参考录音做好之后、问授权之前。识别成了什么写进授权的问句（「SkyCut detected the recording's language as
  Chinese (zh); tell the user, and if that is wrong call again with language.」）和结果（`language`、`language_detected: true`；做成之后再加
  `language_note`：认错了只能删了重建）。令牌照旧绑语言：点过头照原样再调（仍不带 `language`）和带上识别出来的 `language` 再调，认的是同一张。
- 给 AI 的话：`language` 的参数说明写明可选、不给就识别（116 字）；说明书 `manage_voices` 的 `create` 一节照新行为写，加一个不带 `language` 的例子。
  名片不讲参数，没动（444 字）。

## 验证

- `scripts/check-voice-recovery.sh` 的 `LibraryLanguageChecks`（真 App 对象 + 假 Sky Studio，识别换成假的、数它被叫了几次）：不给 `language` 时识别一次、
  问句和结果写识别成了什么、没点头之前什么都不传、照原样带令牌再调建成且 `POST /voices` 带识别出来的语言、带上识别出来的 `language` 再调认同一张令牌且不再识别；
  识别不出来回 `language_undetected` 和「带上 language 再调」、话里没有界面的词、什么都没传；给了 `EN`（识别会说 `zh`）照 `en` 建、识别一次都没叫；
  写错的照旧报错；给空的算没给；`add_reference` 同一条路。
- `scripts/check-mcp.sh` 的 `SkyStudioVoiceChecks`：参数定义只有 `action` 必给、`language` 的说明写着 optional 和不给会怎样、`create` 一节的几句、
  有一个例子不带 `language`。
- `checks/sky-studio-wiring.sh`（拆出去的 `voice-library-ui.sh`）：`SpokenLanguageProbe` 只有生成字幕和 `VoiceSampleLanguage` 两处调；
  `VoiceSampleLanguage.detect` 只有对话框和 `SkyStudioVoiceServices` 两处用；工具里没有 `requiredString("language")`、识别在做参考录音之后问授权之前；
  新文件里不许自己识别、给了就在识别之前回去。
- 反向验证（2026-11-11，每一处临时改坏、跑、看红、`git checkout` 恢复，恢复后工作区和提交一致）：

  | 临时改成 | 红了什么 |
  | --- | --- |
  | 工具改回 `requiredString("language")`（修复前） | `check-voice-recovery`：抛「language is required.」；扫描守卫 1 条 |
  | 给了也拿识别的结果盖掉 | `check-voice-recovery` 6 条（照给的建、`POST /voices` 的语言、识别一次都不叫、写错的不改成识别……）；扫描守卫 1 条 |
  | 识别不出来的那句改成「去设置里的新建声音对话框选」 | `check-voice-recovery` 3 条（要说带上 language 再调、不许出现 Settings / dialog） |
  | 识别不出来就当成英文 | `check-voice-recovery`：「不许猜」那一条 |
  | 识别成了什么不写进问句和结果 | `check-voice-recovery` 5 条（问句、结果、加录音的问句……） |
  | 参数说明和说明书换回修复前 | `check-mcp` 10 条 |
  | 新文件里直接调 `SpokenLanguageProbe`、默认的识别换成永远 nil | 扫描守卫 3 条 |

- 自动化够不着的（真模型在真录音上识别得对不对）写进了 [声音库](../architecture/voice-library.md)第八节的人工回归。

## 教训 / 防回归

- **分两刀做的功能，前一刀留的「先这样、等后面接」要登记成后一刀的待办**，不能只写在文档的一句括号里：后一刀接上公共件的那个 PR，
  要回头把每一个等着它的入口都接上。这次公共件（`SpokenLanguageProbe`）挪出来了、只接了一个入口。
- **照方案核对参数表**：方案 4.6 的表里写着「可选，自动识别」，实现、说明书、检查三处都照着「必给」写，互相对得上，所以谁也不红。
  检查的期望值要从方案来，不能照实现抄。
- 长期约束（给了不盖、不猜、同一份识别、识别在问之前、识别成了什么要说出来）写在 [声音库](../architecture/voice-library.md)第八节第 3 条。
