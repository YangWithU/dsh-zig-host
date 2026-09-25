#!/usr/bin/env python3
"""问题:
    反复重载同一个插件，旧插件占的内存会被回收吗？不回收的话会累积多少？

结论 (2026-09-25 实测，Debug 未 strip 的 .so 磁盘 9.5 MB):
    同一文件「加载 + 卸载」各 20 次:  虚拟地址空间 25.6 -> 25.6 MB，物理 13.5 -> 13.7 MB（零增长）
    20 个不同文件名同时保持加载:      虚拟 73.7 MB，物理 19.2 MB（每份约 2.4 MB / 275 KB）
    把这 20 个也全部卸载:             回落到 25.8 / 13.8 MB
    注意内存涨幅（48 MB）远小于磁盘总量（191 MB）：调试信息不在会被映射的段里。
    另一层结论：dlclose 管不到宿主自己的表（fiber 结构、撤销清单、服务与事件表的行），
    那部分必须逐条撤销，否则既漏内存，又会在下次事件触发时跳到已卸载的代码上。

怎么复现:
    zig build-lib -dynamic -lc --name plug plug.zig -femit-bin=plug.so
    python3 measure.py
"""

import ctypes
import _ctypes
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, ".work")
PAGE = os.sysconf("SC_PAGE_SIZE")


def mem() -> tuple[float, float]:
    with open("/proc/self/statm") as f:
        vsz, rss = f.read().split()[:2]
    return int(vsz) * PAGE / 1024 / 1024, int(rss) * PAGE / 1024 / 1024


def show(tag: str) -> None:
    v, r = mem()
    print(f"{tag:36s} 虚拟 {v:7.1f} MB   物理 {r:6.1f} MB")


def main() -> None:
    src = os.path.join(HERE, "plug.so")
    os.makedirs(WORK, exist_ok=True)

    show("起始")
    for _ in range(20):
        _ctypes.dlclose(ctypes._dlopen(src, ctypes.RTLD_LOCAL))
    show("同一文件 加载+卸载 各 20 次")

    keep = []
    for i in range(20):
        p = os.path.join(WORK, f"plug_{i}.so")
        shutil.copy(src, p)
        keep.append(ctypes._dlopen(p, ctypes.RTLD_LOCAL))
    show("20 个不同文件名同时保持加载")

    for h in keep:
        _ctypes.dlclose(h)
    show("再把这 20 个全部卸载")

    print(f"\n每份 .so 磁盘 {os.path.getsize(src) / 1024 / 1024:.1f} MB，20 份共 {20 * os.path.getsize(src) / 1024 / 1024:.0f} MB")
    shutil.rmtree(WORK, ignore_errors=True)


if __name__ == "__main__":
    main()
