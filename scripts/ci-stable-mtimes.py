#!/usr/bin/env python3
"""CI 用：把每个入库文件的修改时间设成由它的内容（git 的 blob id）算出来的值。

为什么（docs/bugfixes/2026-11-04-ci-build-cache-never-saved-a-compile.md）：SwiftPM 判断一个源文件要不要重编，看的是
修改时间和上次记下的「不一样」。CI 每次 checkout 出来的文件修改时间都是那一刻，恢复回来的 .build 里记的却是上一次
checkout 的时间 —— 一个都对不上，于是整个 App 重编一遍，缓存等于没有。按内容算修改时间之后：内容没变的文件每次
checkout 都是同一个时间，SwiftPM 认得出没变；内容变了的换一个时间（blob id 的约 60 位进了秒和纳秒），照样重编。

内容变了的文件新算出来的时间多半比上次编译还早。这没关系：SwiftPM 比的是「和记下的一不一样」，不是「是不是更新」——
2026-11-04 实测（改了内容、时间拨回 2001 年的文件照样重编、跑出来是新值），scripts/check-ci-build-cache.sh 在 CI 上
每次都再验一遍，哪天 SwiftPM 改成只认「更新」它就红，不会悄悄拿旧的目标文件去测新代码。

用法：python3 scripts/ci-stable-mtimes.py [仓库目录]   （默认当前目录；只在 CI 上、checkout 之后、编译之前跑）
"""
import os
import subprocess
import sys

BASE = 978307200  # 2001-01-01：落在哪个工具都认的范围里


def stable_ns(blob_id):
    """同一个 blob id 永远得到同一个时间（纳秒）；不同的 blob id 几乎不可能撞上。"""
    seconds = BASE + int(blob_id[:8], 16) % 900_000_000
    nanos = int(blob_id[8:16], 16) % 1_000_000_000
    return seconds * 1_000_000_000 + nanos


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    listing = subprocess.check_output(["git", "-C", root, "ls-files", "-s", "-z"])
    count = 0
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        meta, path = entry.split(b"\t", 1)
        mode, blob_id, _stage = meta.split(b" ")
        if mode not in (b"100644", b"100755"):
            continue  # 软链接、子模块：这个仓库没有，碰也不碰
        stamp = stable_ns(blob_id.decode("ascii"))
        os.utime(os.path.join(root, path.decode("utf-8")), ns=(stamp, stamp))
        count += 1
    if count == 0:
        sys.exit("ci-stable-mtimes: git ls-files 一个文件都没列出来（不在仓库里？）")
    print("ci-stable-mtimes: %d 个入库文件的修改时间按内容设好了" % count)


if __name__ == "__main__":
    main()
