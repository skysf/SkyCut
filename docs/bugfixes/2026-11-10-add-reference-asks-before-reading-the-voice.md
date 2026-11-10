# 2026-11-10 给声音加一种它已经有的语言：先问授权、传了录音才被拒；问句里写的是 id

## 症状

T 的免费冒烟（声音 PR 6 合并之后，独立测试 App + 本机假 Sky Studio）撞出两处，都在 `manage_voices action=add_reference`：

1. `language` 是这个声音**已经有**的语言：照样先回 `needs_confirmation` 问授权（录音在点名文件夹外时还先问读文件）；用户点头后本机做参考录音、
   `/uploads` 传上去，然后 `POST /voices/{id}/references` 才被 Sky Studio 拒（409 `reference_exists`）。白问了用户一次，白传了一段录音。
2. 授权的问句写的是「add a Chinese recording to voice_9b1deb4d…」——声音的 id，用户看不出是哪个声音。

## 根因

`SkyStudioVoiceRecordingTool` 加一种语言时**从来不读那个声音**：参数里只有 id，问句就拿 id 拼（`doing`），有没有这种语言要等服务器在建的那一刻说。
PR 6 写这条路时只排了「授权在传之前问」这一个顺序，没把「先确认这件事做得成」排在问之前。检查也只走了「新语言、点头、建成」那一条路：
已有语言的情形只在错误的话（服务器的 `reference_exists` 换成什么话）里测过，测的是报错的措辞，不是**什么时候**报。

## 修复

- `add_reference` 读到 Key 后先 `GET /voices/{id}`——在问授权、问读别处的文件、做参考录音、上传**之前**：已经有这种语言就当场说
  「The voice "Sky" already has a recording in English: one per language. To replace it, delete the voice and create it again. Nothing was sent.」；
  没有这个声音、声音库用不了，照声音库的错误说（都是什么都没传）。
- 问句写声音的名字：「add a Chinese recording to the voice "Sky"」。令牌照旧绑 id（名字能改，id 不变）。
- 「已经有这种语言」那句话只有一处（`SkyStudioVoiceLibraryErrors.referenceExists`）：服务器回的 409 和本机先查出来的说同一句。

## 验证

- `scripts/check-voice-recovery.sh` 的 `LibraryChecks` 新加 `addReferenceChecks`（真 App 对象 + 假协议 `VoiceLibraryHTTP`）：夹具里的声音「Sky」已经有英文，
  再加英文 → 报上面那句（带名字、「Nothing was sent」），没有 `/uploads`、没有 `POST …/references`；加中文 → 问授权，问句里是「to the voice "Sky"」、没有 id。
- 反向验证（2026-11-10，每处单独撤掉、跑 `scripts/check-voice-recovery.sh`、再恢复）：

  | 临时撤掉 | 结果 |
  | --- | --- |
  | 问之前查「已经有这种语言」那一步 | 红：`a language the voice already has is refused before anything is asked`（照样先回了授权的问句） |
  | 问句写名字（改回写 id） | 红：`the consent question names the voice, not its id`（问句里又是 `voice_9b1deb4d…`） |

## 教训 / 防回归

- 要问用户之前，先把本机查得到的前提查完（这件事做不做得成），别让用户点了头、传完东西才被服务器拒。
- 问句里写人看得懂的名字；令牌绑不会变的 id。
- 长期约束写进了 [声音库](../architecture/voice-library.md)第八节第 3 条。
