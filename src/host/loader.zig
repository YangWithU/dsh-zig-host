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
///
/// 定案：inspect **只读不留** —— 打开、dlsym 校验、立刻关闭。
///   理由是开/关一个 .so 的代价可以忽略，而「留着的句柄由谁负责关」会引入
///   一处新的所有权问题；失败时更干净（什么都没留下）。
///   load() 真正装载时会自己再打开一次。
pub fn inspect(path: []const u8) LoadReport {
    _ = path;
    @panic("TODO: dlopen(RTLD_LAZY) + dlsym(SYM_ABI_VERSION) + 比对 ABI_VERSION");
}

/// 完整挂载一个插件，四步：
///   1. Fiber.create()    建身份 + arena + 空的撤销清单（不碰插件代码）
///   2. inspect()         校验能打开、符号齐、ABI 版本匹配（只读不留）
///   3. refresh()         依赖（inject）齐不齐？不齐 → 停在 pending，就此打住
///   4. Fiber.load()      dlopen → dlsym(init) → 调 dsh_plugin_init(api, cfg)
///
/// 任何一步失败都要走完整回滚路径（= Fiber.unload()），不留半加载的 fiber。
/// 顺序的理由：① 的唯一产物是「自己那份 fiber」（失败了丢掉即可），②③ 完全不
/// 产生副作用，④ 才是真正会改动全局状态的一步 —— 把风险最大的动作放在最后。
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
///     撤销全部注册（逆序，按编号） → dlclose → arena 清空
/// 详见 Fiber.unload() 的注释；这里只把「谁调用」暴露给 Context。
///
/// ★ 谁负责：宿主。插件不需要、也不应该负责卸载自己 —— 它可能在 init 半路
///   就失败了、可能崩了，而只有宿主清楚「一共收到过哪些注册」。
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
///
/// ★ 顺序定案（把「最容易失败的环节」全部提到「拆旧」之前）：
///     ① 编译新代码 → 产出**新文件名**的 .so（不碰旧文件）
///     ② inspect 新产物（能打开？符号齐？ABI 匹配？）
///        ── ①② 任何一步失败：丢掉新产物直接返回，旧实现原封不动继续跑
///     ③ 拆旧：撤销旧 fiber 的全部注册（逆序） → dlclose
///     ④ 装新：dlopen 新产物 → dsh_plugin_init
///     ⑤ 重放依赖检查（依赖可能变了）→ active 或 pending
///
/// ⚠️ ③ 之后 ④ 失败的话，**已经没有旧实现可回滚了**（旧的已撤销并卸载）。
///   这是本方案公开承认的代价。之所以可以接受：编译、符号、ABI 这三类最容易
///   出的错已经在 ①② 里排除掉了，剩下「dlopen 一个刚刚校验通过的本地文件」
///   失败概率很低；真要求连这个窗口也不丢服务，就得用 scope 做蓝绿（新旧两代
///   同时存在、靠 scope 隔离同名服务），那是后续可选增强，不是现在。
pub fn reload(f: *fiber_mod.Fiber) !*fiber_mod.Fiber {
    _ = f;
    @panic("TODO: 阶段 4 —— 保留 parent/config，卸载旧实现，挂载新实现");
}
