//! ═══════════════════════════════════════════════════════════════════════════
//!  阶段 1 · Loader —— 把 .so 变成运行中的插件        【草图 / 空壳】
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 职责：给定一个 .so 路径，产出（并可撤销）一个运行中的插件。
//!
//! 与 Cordis 的对应
//! ---------------------------------------------------------------------------
//!     Cordis: entry → import(name) → ctx.plugin(plugin, config)
//!     Zig   : entry → dlopen(path)  → Fiber.load() → plugin_init(api, cfg)
//!
//! 关键机制（实测已验证可行）
//! ---------------------------------------------------------------------------
//!   · 同进程内替换磁盘上的 .so，重新 dlopen 同一路径 → 拿到**新代码**
//!     这就等价于 Node「清模块缓存再 import」，是热重载的基础。
//!   · 必须链接 libc（`-lc`）。否则 Linux 走 Zig 自带的 ElfDynLib，
//!     复杂一点的调用就段错误。
//!   · 路径必须带斜杠（绝对路径或 ./）。裸库名会走 LD_LIBRARY_PATH 搜索。
//!
//! ⚠️ 空壳。

const std = @import("std");
const abi = @import("dsh_abi");
const fiber_mod = @import("fiber.zig");

/// 一次加载尝试的诊断结果。加载失败时用来告诉用户「卡在哪一步」。
pub const LoadReport = struct {
    stage: Stage,
    /// 失败原因（仅在 stage != .ok 时有意义）
    message: []const u8 = "",
    /// 插件自报的名字（如果读到了）
    plugin_name: []const u8 = "",

    pub const Stage = enum {
        ok,
        open_failed, // .so 打不开（文件不存在 / 架构不对 / 依赖缺失）
        symbol_missing, // 找不到 dsh_plugin_init 等约定符号
        abi_mismatch, // 插件与宿主的 ABI_VERSION 不一致
        init_failed, // plugin_init 返回了非 ok
        rolled_back, // 失败后已回滚干净
    };
};

/// 打开 .so 并校验它确实是一个插件。**此步骤不产生副作用**（不 init、不注册）。
///
/// 为什么先校验后初始化：一个 ABI 不匹配的 .so 如果在 init 里已经改过全局
/// 状态再报错，回滚会很麻烦。把所有能提前查的都提前查。
pub fn inspect(path: []const u8) LoadReport {
    _ = path;
    @panic("TODO: dlopen(RTLD_LAZY) + dlsym(SYM_ABI_VERSION) + 比对 ABI_VERSION");
}

/// 完整挂载一个插件：
///   1. 建 Fiber（身份 + arena）
///   2. inspect 校验
///   3. dlsym SYM_INIT
///   4. 调 plugin_init(api, config_json)
///   5. 校验插件声明的依赖（inject）—— 若依赖未齐，停在 pending
///
/// 任何一步失败都要走完整回滚路径，不留下半加载的 fiber。
pub fn mount(
    host: *abi.HostApi,
    gpa: std.mem.Allocator,
    path: []const u8,
    config_json: [:0]const u8,
) !*fiber_mod.Fiber {
    _ = host;
    _ = gpa;
    _ = path;
    _ = config_json;
    @panic("TODO: 阶段 1 —— inspect → dlsym → init → 返回 fiber");
}

/// 卸载一个插件。等价于 Cordis 里 fiber.dispose()。
///
/// 内部顺序（不可调换）：
///     撤销全部注册（逆序） → dlclose → arena.deinit()
pub fn unmount(f: *fiber_mod.Fiber) void {
    _ = f;
    @panic("TODO: 阶段 1 —— 委托给 Fiber.unload/dispose");
}

/// 重新挂载：卸载旧的，加载新的。
///
/// ★ 热重载的核心语义（对齐 Cordis 的 reload）：
///     「新的代码 + 原来的位置 + 原来的配置」
///   也就是说：新 fiber 要挂在**同一个父 fiber 下**，用**同一份原始 config**，
///   这样插件在树里的地位不变，只是实现换了一份。
///   （Cordis 里对应的是 `oldFiber.parent.registry.plugin(plugin, oldFiber._config)`）
pub fn reload(f: *fiber_mod.Fiber) !*fiber_mod.Fiber {
    _ = f;
    @panic("TODO: 阶段 4 —— 保留 parent/config，卸载旧实现，挂载新实现");
}
