//! ═══════════════════════════════════════════════════════════════════════════
//!  阶段 1 · Fiber —— 一次插件挂载的运行时身份
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 一个 Fiber 代表「一个插件的一份运行实例」，掌管三样东西：
//!
//!   1. 状态机        什么时候加载 / 卸载
//!   2. 撤销清单      卸载时按什么顺序、撤销哪些注册
//!   3. 专属 arena    这个插件的内存在哪、什么时候整块回收
//!
//! 状态迁移（第一批实现这些边）
//!
//!     create ──→ pending ──load()──→ loading ──成功──→ active
//!                   ↑                   │                │
//!                   │                   │ 失败            │ unload()
//!                   │                   ↓                ↓
//!                   │                failed ←────── unloading
//!                   └────────────────────────────────────┘
//!                   deinit() ──→ disposed（终态，不可再用）
//!
//!   · unload 之后回到 pending，**可以再次 load**（热重载就靠这条）；
//!     真正不可逆的是 deinit。
//!   · failed 是「这次加载没成」，不是「这个 fiber 废了」。
//!
//! ★ 与 Cordis 的三个关键差异（基调，必须记住）
//! ---------------------------------------------------------------------------
//!   1. Cordis 用闭包捕获实现回卷；Zig 用**显式 disposer 栈**（Disposable）。
//!   2. Cordis 靠 GC 兜内存；Zig 靠 **arena 整体释放**，泄漏不可能。
//!   3. Cordis 漏清理最多内存泄漏；Zig **漏清理 = 段错误**（已实测）。
//!      ⇒ 撤销清单不是「好设计」，是「安全硬前提」。
//!
//! 顺序铁律：unload 里三步不可调换
//! ---------------------------------------------------------------------------
//!   ① 逆序跑撤销清单  →  ② dlclose  →  ③ arena 清空
//!
//!   ① 必须早于 ②：撤销清单里每一条做的都是「去宿主表里删一行」，而那些行里
//!      存着指向 .so 代码的函数地址。先卸代码再撤销，撤销过程自己就跳到别人
//!      家里去了（实测：漏撤销 → 段错误）。
//!   ③ 必须在 ① 之后：撤销项携带的上下文（Disposable.data）可能就是 arena
//!      里的内存，先清 arena 就没得用了。
//!
//! 第一批不做（连同理由）
//! ---------------------------------------------------------------------------
//!   · 依赖门（inject / epoch / refresh）：服务出现消失自动加载卸载。它需要
//!     services <-> fiber 双向协作，等装卸闭环有测试保护之后再加。
//!   · 树结构（parent / children 级联卸载）：还没有「插件里装插件」的场景。
//!   · 谁驱动状态迁移：现在是谁调谁负责，没有调度器（Context 将来承担）。

const std = @import("std");
const abi = @import("dsh_abi");
const loader = @import("loader.zig");

pub const State = enum {
    pending,
    loading,
    active,
    unloading,
    failed,
    disposed,
};

/// 一条可撤销的注册。
///
/// 为什么用显式结构体而不是闭包：Zig 没有闭包捕获，撤销逻辑必须自己携带
/// 「撤销时需要的全部信息」，`data` 就是那个上下文。
pub const Disposable = struct {
    /// 对应的注册编号（等于宿主侧那个 Handle.id）。
    /// ★ 撤销按编号定位，不按名字 —— 同名注册可以有多份，凭名字会撤错。
    ///   插件主动撤销（api.revoke）时，就是靠它在清单里找到这一条。
    id: u64 = 0,

    /// 真正执行撤销的函数。
    run: *const fn (self: *Disposable) void,

    /// 撤销所需的状态。**由宿主分配器分配**，不放插件 arena：
    /// 撤销清单的生命周期必须独立于 arena，否则 arena 一旦先清空，
    /// 清单里的上下文就没了，撤销无从谈起。
    /// 谁分配谁释放 —— `run` 自己负责把 data 还回去。
    data: *anyopaque,

    /// 诊断标签，如 "service(greeter)"。卸载日志与排错用。
    label: []const u8 = "",
};

/// 一个插件实例。
pub const Fiber = struct {
    /// 宿主分配器：撤销清单走它，**不走 arena**（见 Disposable.data 的说明）。
    gpa: std.mem.Allocator,
    /// 宿主分配的稳定编号（单调递增，永不复用）。
    id: u64,
    state: State = .pending,
    /// 诊断用的名字（由调用方给，其生命周期必须覆盖 fiber）
    name: []const u8,

    /// 插件来源：.so 的路径。**内置插件（编译进宿主）为 null**，
    /// 那种 fiber 用 loadBuiltin 之外的方式激活，不走 dlopen。
    plugin_path: ?[]const u8 = null,

    /// dlopen 句柄。卸载时必须 dlclose（每代都真正卸载）。
    ///
    /// ★ 定案：dlclose 与「产物名带内容指纹」两条一起做，各管一件事。
    ///   · dlclose        —— 负责把内存还回去。实测：同一文件「加载+卸载」
    ///     各 20 次，物理内存 13.5MB → 13.7MB 基本不动。
    ///   · 产物名带指纹   —— 负责「即使某次没卸干净，也一定加载到新代码」。
    ///     一旦没真卸载，同路径 dlopen 会把旧的那份**原样还给你**：不报错、
    ///     不崩，静默跑在旧代码上（实测确认）。换文件名，这件事不可能发生。
    ///
    /// ⚠️ 绝不允许「覆盖正在被加载的那个 .so 文件」：已映射进内存的代码页
    ///   会被破坏，下一次调用直接段错误（实测 SIGSEGV）。
    lib: ?loader.Loaded = null,

    /// ★ 插件专属 arena。该插件一切与自身同生命周期的分配都从这里出。
    ///   卸载时整块还回去 —— 这是 Zig 相对 Cordis 的最大红利。
    arena: std.heap.ArenaAllocator,

    /// ★ 撤销清单。存放 arena 管不到的**外部资源**：
    ///   服务注册、事件监听、打开的文件/进程。
    ///   · 由宿主分配器持有，生命周期独立于 arena。
    ///   · 卸载时**逆序**执行（后注册的先撤销）。
    ///   · 「加载失败回滚」复用同一份清单、同一段执行逻辑 —— 回滚与卸载
    ///     走的是同一条路，不需要写两套。
    ///   · 责任在宿主：注册那一刻宿主就顺手记一条，不依靠插件自觉。
    disposers: std.ArrayList(Disposable),

    // ── 构造与销毁 ─────────────────────────────────────────────────────────

    /// 创建一个 fiber。此时**不**加载插件代码，只是登记身份 + 建 arena。
    /// `name` 的生命周期必须覆盖 fiber（调用方持有，通常是静态字符串）。
    pub fn create(
        gpa: std.mem.Allocator,
        id: u64,
        name: []const u8,
        path: ?[]const u8,
    ) !*Fiber {
        const self = try gpa.create(Fiber);
        self.* = .{
            .gpa = gpa,
            .id = id,
            .name = name,
            .plugin_path = path,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .disposers = .empty,
        };
        return self;
    }

    /// 插件申请内存用的分配器（就是它自己的 arena）。
    /// 插件通过 HostApi.alloc 拿到的内存，最终从这里出。
    pub fn allocator(self: *Fiber) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// 登记一条撤销项。
    ///
    /// ★ 调用顺序不能反：**先做注册、再登记撤销**。反过来的话，登记完之后
    ///   注册失败，撤销清单里就留下一条指向不存在注册的项（撤销时找不到行，
    ///   幂等返回，但清单本身脏了）。
    pub fn addDisposable(self: *Fiber, d: Disposable) !void {
        try self.disposers.append(self.gpa, d);
    }

    // ── 加载与卸载 ─────────────────────────────────────────────────────────

    /// 加载：dlopen → 校验 ABI → 调 plugin_init。
    ///
    /// 失败必须**完全回滚**，而且回滚就是 unload()：跑同一份撤销清单（把 init
    /// 里已经注册掉的东西撤掉）+ dlclose + arena 清空。不留半个插件 ——
    /// 半加载状态是后续所有诡异崩溃的源头。
    pub fn load(self: *Fiber, api: *const abi.HostApi, config_json: [*:0]const u8) abi.Status {
        const path = self.plugin_path orelse return .err_invalid_arg;
        self.state = .loading;

        const loaded = loader.open(path) catch |e| {
            self.state = .failed;
            return statusFromLoadError(e);
        };
        self.lib = loaded;

        const st = self.lib.?.init(api, config_json);
        if (st != .ok) {
            // init 里可能已经注册了一部分 —— 走 unload 把它撤干净
            self.unload();
            self.state = .failed;
            return st;
        }

        self.state = .active;
        return .ok;
    }

    /// 卸载：**先**逆序撤销全部注册，**再** dlclose，**最后** arena 清空。
    /// 三步顺序的理由见文件头「顺序铁律」。幂等：重复调用不会重复撤销。
    pub fn unload(self: *Fiber) void {
        // 幂等保护 + 重入保护。
        // 注意**不能**把 pending 当成「已经干净」跳过：卸载完回到 pending 之后
        // 再调一次是空操作没错，但「刚 create、还没 load」的 fiber 也可能是
        // pending —— 而它照样可能有撤销项（手动注册过、或上一次 load 失败回滚
        // 没走完）。所以 pending 必须放行，靠清单本身为空来兜底。
        if (self.state == .disposed or self.state == .unloading) return;

        self.state = .unloading;

        // ① 逆序跑撤销清单（后注册的先撤）。
        //    取指针再调用、调用完才弹出 —— 用值拷贝调用的话，run 里的改动
        //    落在拷贝上，清单里那条不会被更新。
        while (self.disposers.items.len > 0) {
            const d = &self.disposers.items[self.disposers.items.len - 1];
            d.run(d);
            _ = self.disposers.pop();
        }

        // ② 可选收尾钩子，然后 dlclose
        if (self.lib) |*l| {
            // 宿主不得依赖这个钩子做清理（见 abi.PluginDeinitFn 的说明）
            if (l.deinit) |f| f();
            loader.close(l);
            self.lib = null;
        }

        // ③ 插件内存整块还回去。free_all 是「还内存」而不是「留着备用」，
        //    否则反复装卸会一路涨上去。
        _ = self.arena.reset(.free_all);

        // 回到 pending：这个 fiber 还能再次 load（热重载靠这条）
        self.state = .pending;
    }

    /// 彻底销毁：卸载 + 释放清单 + 销毁 arena + 释放自身。之后不可再用。
    /// （从宿主登记表里摘除是调用方的事 —— fiber 不知道自己被登记在哪。）
    pub fn deinit(self: *Fiber) void {
        self.unload();
        self.disposers.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self);
    }
};

/// 把 dlopen/符号查找的错误翻译成跨边界的返回码。
fn statusFromLoadError(e: anyerror) abi.Status {
    return switch (e) {
        loader.LoadError.MissingAbiVersion, loader.LoadError.AbiMismatch => .err_abi_mismatch,
        loader.LoadError.MissingInit => .err_invalid_arg,
        error.FileNotFound => .err_not_found,
        else => .err_internal,
    };
}

// ───────────────────────────────────────────────────────────────────────────
//  测试
// ───────────────────────────────────────────────────────────────────────────

/// 记录撤销顺序，用来验证「逆序」这条规矩。
const Recorder = struct {
    seen: [8]u64 = [_]u64{0} ** 8,
    n: usize = 0,
};

fn recordRun(d: *Disposable) void {
    const r: *Recorder = @ptrCast(@alignCast(d.data));
    r.seen[r.n] = d.id;
    r.n += 1;
}

test "撤销清单逆序执行，卸载后清零，重复卸载幂等" {
    const gpa = std.testing.allocator;
    var rec = Recorder{};
    const f = try Fiber.create(gpa, 1, "test", null);
    defer f.deinit();

    for ([_]u64{ 10, 11, 12 }, 0..) |id, i| {
        try f.addDisposable(.{
            .id = id,
            .run = recordRun,
            .data = @ptrCast(&rec),
            .label = if (i == 0) "first" else "more",
        });
    }
    try std.testing.expectEqual(@as(usize, 3), f.disposers.items.len);

    f.unload();

    // 后注册的先撤
    try std.testing.expectEqualSlices(u64, &.{ 12, 11, 10 }, rec.seen[0..3]);
    try std.testing.expectEqual(@as(usize, 0), f.disposers.items.len);
    // 回到 pending：还能再次 load
    try std.testing.expectEqual(State.pending, f.state);

    // 幂等：再卸一次不会重复撤销
    f.unload();
    try std.testing.expectEqual(@as(usize, 3), rec.n);
}

test "arena: 卸载后容量回落（插件内存整块还回去）" {
    const gpa = std.testing.allocator;
    const f = try Fiber.create(gpa, 2, "test", null);
    defer f.deinit();

    const a = f.allocator();
    _ = try a.alloc(u8, 100 * 1024);
    const before = f.arena.queryCapacity();
    try std.testing.expect(before > 0);

    f.unload();
    try std.testing.expect(f.arena.queryCapacity() < before);

    // 卸载之后 arena 仍然可用（重新 load 时插件还要在上面分配）
    _ = try a.alloc(u8, 1024);
}

test "load: .so 不存在 -> failed，不留半个插件" {
    const gpa = std.testing.allocator;
    const f = try Fiber.create(gpa, 3, "ghost", "zig-out/lib/libdefinitely-not-here.so");
    defer f.deinit();

    // dlopen 会先失败，所以这个 api 不会被解引用
    var api: abi.HostApi = undefined;
    const st = f.load(&api, "");

    try std.testing.expectEqual(abi.Status.err_not_found, st);
    try std.testing.expectEqual(State.failed, f.state);
    try std.testing.expect(f.lib == null);
    try std.testing.expectEqual(@as(usize, 0), f.disposers.items.len);
}

test "load: 没有 plugin_path 的内置 fiber 拒绝走 dlopen 路径" {
    const gpa = std.testing.allocator;
    const f = try Fiber.create(gpa, 4, "builtin", null);
    defer f.deinit();

    var api: abi.HostApi = undefined;
    try std.testing.expectEqual(abi.Status.err_invalid_arg, f.load(&api, ""));
    try std.testing.expectEqual(State.pending, f.state);
}
