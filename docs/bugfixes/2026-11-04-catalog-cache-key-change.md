# 2026-11-04 换 Key 后迟到的模型目录回填缓存并清掉新请求

## 症状
代码复审发现：旧 Key 的 /models 尚未返回时换成新 Key，先清缓存并发起新查询；如果旧回答随后到达，它能再次占据共享目录缓存。新的调用还可能绕开正在等待的新查询，错误地拿到旧目录，或者再发一次重复查询。制作计划引入离线缓存读取后，这种跨账号的过期目录尤其不能被当成当前可用模型表。

## 根因
SkyStudioCatalogCache.catalog 在 await 之后无条件写 stored，并在 defer 无条件清 loading。forget 只把两个字段置 nil，未改变悬挂调用恢复后的写权限。Task 先后与字段生命周期因此脱节：旧任务既能回填，也能清掉后继任务。

## 修复
forget 推进一个本地 invalidation epoch。每个新加载捕获自己的 epoch；只有它仍属于当前 epoch，返回时才可以填 stored 或清 loading。旧调用者仍可收到它自己当时请求的结果，但不能改新的共享缓存。cachedCatalog 只返回时间未倒退、10分钟内的已热公开目录，不会隐式联网。

## 验证
真实 SkyStudioCatalogCache 与 SkyStudioAPI，注入可显式放行每个请求的 URLSession/URLProtocol。先挂旧请求，再 forget 并挂新请求，最后先释放旧请求；验证旧结果不回填、后继调用继续共用新请求且没有第三次 /models。包括冷peek零HTTP、过期/倒退时间与 forget。
已执行 /tmp 真API/cache注入正向：11项/0失败。
已执行安全反向：隔离副本只撤回写缓存的epoch核对，11项中准确2项红；另一副本只撤回清loading的epoch核对，11项中准确2项红。生产源/绿色二进制保持原样；不触真实网络或钥匙串。
统一实际模型检查入口 scripts/check-film-production.sh；最终完整App与check-all/CI结果另填，不用纯值结果代替MCP验收。

## 教训 / 防回归
异步缓存失效既要拦迟到写回，也要拦迟到清理后继状态。长期规则见 [Sky Studio 任务：模型目录缓存](../architecture/sky-studio-jobs.md)。
