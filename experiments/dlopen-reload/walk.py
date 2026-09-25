#!/usr/bin/env python3
"""问题:
    宿主进程正在用 v0.1 的插件，磁盘上出现了 v0.2。把新 .so 替换过去之后，
    宿主动重新 dlopen 同一个路径，能不能拿到新代码？

结论 (glibc, 2026-09-25 实测):
    cp 覆盖已加载的 .so，再 dlopen 同路径   -> 段错误 (SIGSEGV)
    换掉文件后 dlopen 同路径（旧句柄未释放）-> 静默返回旧代码，且句柄相同
    先真正 dlclose，再 dlopen 同路径         -> 拿到新代码
    换成新文件名再 dlopen                    -> 拿到新代码，句柄不同
    => 热重载必须「每代新文件名」，且不能覆盖正在被加载的文件。
    => 这里用 ctypes 的低层接口，是为了确保 dlclose 真的发生（CDLL 会缓存函数
       指针并持有引用，del 也未必释放句柄，会得到假结论）。

怎么复现:
    zig build                 # 先编出 v01/v02
    python3 walk.py           # 跑三个安全情形
    RUN_CRASH=1 python3 walk.py   # 额外跑会段错误的情形（会留下 core dump）
"""

import ctypes
import _ctypes
import os
import shutil
import subprocess
import sys
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, ".work")


def sub_case(mode: str) -> None:
    """在独立子进程里跑一个情形（dlopen 的加载表是进程级的）。"""
    code = textwrap.dedent(f"""
        import ctypes, _ctypes, os, shutil
        mode = {mode!r}
        d = {WORK!r}
        p = os.path.join(d, "libplugin.so")
        shutil.copy(os.path.join({HERE!r}, "zig-out/lib/libv01.so"), p)

        def load(path): return ctypes._dlopen(path, ctypes.RTLD_LOCAL)
        def sym(h, n): return ctypes.CFUNCTYPE(ctypes.c_int)(_ctypes.dlsym(h, n))
        def ver(h): return sym(h, "plugin_version")()

        h1 = load(p)
        print(f"    起步: 版本号={{ver(h1)}}")
        if mode == "cover_alive":
            shutil.copy(os.path.join({HERE!r}, "zig-out/lib/libv02.so"), p)
            h2 = load(p)
        elif mode == "rename_alive":
            shutil.copy(os.path.join({HERE!r}, "zig-out/lib/libv02.so"), p + ".new")
            os.replace(p + ".new", p)
            h2 = load(p)
        elif mode == "reload_after_close":
            _ctypes.dlclose(h1)
            shutil.copy(os.path.join({HERE!r}, "zig-out/lib/libv02.so"), p)
            h2 = load(p)
        elif mode == "new_filename":
            q = os.path.join(d, "libplugin_v2.so")
            shutil.copy(os.path.join({HERE!r}, "zig-out/lib/libv02.so"), q)
            h2 = load(q)
        print(f"    换过之后: 版本号={{ver(h2)}} (1=旧代码, 2=新代码)")
    """)
    r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    print(r.stdout.rstrip())
    if r.returncode != 0:
        print(f"    -> 进程退出码 {r.returncode}（139 = 段错误）")


def main() -> None:
    os.makedirs(WORK, exist_ok=True)

    safe = ["rename_alive", "reload_after_close", "new_filename"]
    cases = safe + (["cover_alive"] if os.environ.get("RUN_CRASH") else [])

    for mode in cases:
        print(f"  情形 {mode}:")
        sub_case(mode)

    if not os.environ.get("RUN_CRASH"):
        print("  （跳过 cover_alive：它会段错误。要跑就设 RUN_CRASH=1）")

    shutil.rmtree(WORK, ignore_errors=True)


if __name__ == "__main__":
    main()
