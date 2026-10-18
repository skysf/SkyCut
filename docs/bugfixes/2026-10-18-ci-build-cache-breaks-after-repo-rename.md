# 2026-10-18 仓库改名 SkyCut 之后，CI 五组全部编不过：恢复了旧目录编的 .build 缓存

## 症状

GitHub 仓库从 `skysf/SrtFlow` 改名 `skysf/SkyCut` 之后的第一个 PR（#252，只改了文档）CI 五组全红。每一组都是同一类编译错误，几十行：

```
error: precompiled file '/Users/runner/work/SkyCut/SkyCut/.build/arm64-apple-macosx/debug/ModuleCache/…/SwiftShims-….pcm'
was compiled with module cache path '/Users/runner/work/SrtFlow/SrtFlow/.build/arm64-apple-macosx/debug/ModuleCache/…',
but the path is currently '/Users/runner/work/SkyCut/SkyCut/.build/arm64-apple-macosx/debug/ModuleCache/…'
error: missing required module 'SwiftShims'
```

改名之前合的 #250、#251 都是绿的：它们的 CI 跑在改名之前。

## 根因

- **`.build` 里记着检出目录的绝对路径。** Clang / Swift 的模块缓存（`ModuleCache` 下的 `.pcm`）写死了编它时的路径；换了目录，编译器认出
  「不是在这里编的」就拒绝用，又不会自己重编，直接报错。
- **CI 的 `.build` 缓存 key 只看 `Package.swift`**：`swiftpm-<os>-<Package.swift 的哈希>`，`restore-keys` 是 `swiftpm-<os>-`。GitHub 托管
  runner 的检出目录是 `/Users/runner/work/<仓库名>/<仓库名>`，仓库改名就换了目录，可 key 没变（`restore-keys` 的前缀更是什么都匹配），
  改名之前存的缓存原样恢复回来。
- 本机挪目录时撞的是同一个坑，当时删了本地的 `.build`（[改名方案](../plans/2026-10-18-rename-to-skycut.md)「本机收拾」第 4 步），
  可 CI 上的缓存没人想到 —— 它和本地的 `.build` 是同一样东西，只是存在 GitHub 上。

## 修复

`.github/workflows/checks.yml` 缓存 `.build` 的那一步，`key` 和 `restore-keys` 都带上 `${{ github.workspace }}`（检出目录）：

```yaml
key: swiftpm-${{ runner.os }}-${{ github.workspace }}-${{ hashFiles('Package.swift') }}
restore-keys: swiftpm-${{ runner.os }}-${{ github.workspace }}-
```

改名之前的缓存 key 不带目录，新的前缀匹配不到它们：第一轮冷编、存一份新 key 的缓存，之后照常命中。以后再改名、换 runner 的检出目录也一样不会捡到别处编的缓存。
旧缓存不用手删，GitHub 七天没人用就会自己清掉。`vendor/` 那份 ffmpeg 缓存是一个独立的二进制、不记路径，不用改。

## 验证

- 新守卫 `checks/ci-build-cache-key.sh`（第 1 组）：缓存 `.build` 那一步的 `key` 和 `restore-keys` 都要带 `github.workspace`。
  反向验证：`key` 改回旧写法 → 红、退出码 1；`restore-keys` 改回旧写法 → 红、退出码 1；恢复后转绿。
- 这个 PR 自己的 CI：新 key 恢复不到旧缓存，五组冷编都过；#252 把 main 合进去之后重跑转绿。

## 教训 / 防回归

- **记着绝对路径的缓存，key 里就得有那个路径。** 只按内容（`Package.swift`）做 key，等于默认目录永远不变。
- **改名 / 挪目录要把所有「编译产物的副本」都找出来作废**：本机的 `.build`、CI 的缓存、别的机器上的副本。改名的长期规矩见
  [产品名与代码名](../architecture/product-name.md) 第二节；CI 的缓存规矩写在 [构建与打包「CI」一节](../build/build-and-packaging.md)。
- 文档只改了几行的 PR 五组齐红、错误都一样，先怀疑环境（缓存、runner、工具链），别去翻这次的改动。
