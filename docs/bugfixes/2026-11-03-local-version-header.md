# 2026-11-03 本地构建后缀进入 Sky Studio 版本头，模型目录被拒

## 症状

本机安装的 SkyCut 版本是 `0.18.56-local.20261103.1348.gb129389`，Key 已配置；
MCP 调用 `get_status models=true` 时，模型目录不可用，服务器提示：
`Send X-SkyCut-Version as major.minor.patch, for example 0.18.47.`
原定通过 MCP 完成的动态预览因此停在模型发现，尚未提交付费任务。

## 根因

`SkyStudioAPI.appVersion` 读取完整的 `CFBundleShortVersionString`，共享的 `request`
又把它原样写进 `X-SkyCut-Version`。完整构建来源用于辨认本机产物是必要的，但服务器的
传输合同只接受数字三段，用来执行最低版本限制。

原 `APIChecks` 只注入了 `0.18.49` 这类纯数字版本，从未让带后缀的真实请求走过假协议，
因此显示用版本与传输用版本的差别没有被覆盖。

## 修复

- 在 `SkyStudioAPI.request` 写请求头时统一规范化：完整识别数字三段及可选的
  `-` 本地 / 预发布标识、`+` 构建标识，仅把数字三段送出。授权、模型、报价、上传、
  提交、查询与取消全部经过这一处。
- `appVersion`、实例里保存的完整版本、包内 Info.plist 和所有身份字符串不变；
  验收包仍保留 `local` 后缀，不能靠改成纯数字版本掩盖请求边界的错误。
- 无法完整识别的输入原样保留，交给服务器严格拒绝；不把 `bad input` 换成有效版本。
  `0.0.0` 本身是有效版本，最低版本也可能为 `0.0.0`，不能拿它当坏输入的拒绝保证。
  Bundle 缺键时原有的 `0.0.0` 行为保留，服务器版本校验与最低版本限制不改。
- 回归放在既有 `checks/SkyStudio/APIChecks.swift`：实际调用 `/models`，由假 URLSession
  协议记录发出的 URLRequest；并核对其余 API 在同一请求边界的头和完整来源未变。

## 验证

- `/bin/bash scripts/check-sky-studio.sh`：1,096 项通过；新增 22 种版本输入，每种 10 项断言，
  覆盖真实 `/models` 请求、其他 API 的共用边界和完整构建来源不变。
- 反向验证一：只把请求头写回原来的 `version`，同一检查退出 1，35 项失败，覆盖
  local、预发布、build 和组合后缀；不是编译失败冒充守卫红灯。
- 反向验证二：只把无法识别版本的返回值改成 `0.0.0`，同一检查退出 1，91 项失败，
  明确覆盖坏输入不得伪装成有效版本的审阅要求。
- 两次临时改动均在 `finally` 中恢复；恢复后同一检查再次 1,096 项通过。
- `/bin/bash scripts/check-guards.sh`：全部扫描守卫通过，退出 0。
- `/bin/bash scripts/check-all.sh`：实际跑完 82 项，通过 82、失败 0，退出 0；含完整 App
  arm64 编译、真实媒体 / 导出回归及本次 Sky Studio 1,096 项回归。

所有 API 回归只用假协议，不读生产 Key、不提交付费任务。本机受限沙箱第一次检查在
SwiftPM 编译阶段被拒绝，未计为测试通过；窄范围授权运行后取得上述实际结果。

**总部完成的本机与真实 MCP 验收**（2026-11-03）：

- 复用本次已编好的 arm64 Debug App 与 helper，保留版本
  `0.18.56-local.20261103.1659.gb129389.dirty.versionheader`，未重复 Release 构建。
  `acceptance-build.json` 记录 API diff 的 SHA-256 为
  `49f606531bd28af5a8f2e985606e8b10a7b7f18feac8f4b22b36997cc117ce4d`；
  本执行会话核对当前 API diff，指纹相同。
- 使用既有固定证书签名；requirement 仍是 `com.srtflow.SrtFlow` +
  `certificate leaf = H"76d275650223bc09efe7708900458dbdb0ab90ef"`。
  源包、安装前暂存包、安装后的 `codesign --verify --deep --strict` 均通过；旧 App 已可逆备份。
- 真 App 经 MCP `get_status models=true` 返回完整生产目录；上述 `app_version` 后缀仍在，
  版本格式拒绝和 `skycut_plan.problem` 消失，录屏仍为 `granted`。
  工具数 55、指纹 `c5a2619ff650fe76` 未变，原 p1 工程已保存并恢复。
- 真实 `generate_media quote_only`：Seedream 2K 图片报价 8 积分，H3 frames / 480p / 10 秒
  报价 100 积分，两笔均为 `charged=false`。这是目录与仅报价验收，不是付费生成验收。

签名、安装和真实 MCP 由总部执行并同步证据；本修复工程会话不重复安装、不退出当前 App、
不触碰正在独立工程制作试片的执行会话。全量检查和 CI 的实际结论另行记录，不能互相替代。

## 教训 / 防回归

1. 显示与追溯需要的完整构建版本，不等于 API 的版本合同；转换应在共用传输边界做。
2. 识别失败不能变成一个看似有效的版本；保留服务器的格式拒绝与最低版本限制。
3. 回归必须经过实际 URLRequest 接线，包含本机真实后缀、预发布、构建标识与坏输入，
   不能只测字符串函数或纯数字样例。

长期合同见 [Sky Studio 账号](../architecture/sky-studio-account.md)「请求里的版本」。
