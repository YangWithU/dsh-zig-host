//! ═══════════════════════════════════════════════════════════════════════════
//!  Context —— 宿主的门面，把 loader / fiber / services 缝在一起
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 这个结构就是 Cordis 里 `Context` 的 Zig 版。差别在于：
//!
//!     Cordis:  ctx 是 Proxy，读 ctx.tools 会动态查表
//!     Zig   :  ctx 是普通结构体，插件通过 HostApi 回调来查表
//!
//! 也就是说：**Cordis 把「查表」藏在属性读取语法里，Zig 把它变成显式调用。**
//! 功能等价，写法不同 —— 这是本移植最大的风格差异。
//!
//! 数据流
//! ---------------------------------------------------------------------------
//!   宿主: Context.init            -> registry 建表
//!         Context.newFiber(name)  -> 建 fiber + 建它专属的 PluginSlot
//!         slot.api                -> 就是交给该插件的那份 HostApi
//!   插件: 调 api.register_service(api.ctx, ...)
//!         -> 宿主用 api.ctx 反查出 slot -> 知道是哪个 fiber
//!         -> 注册与记账都落在正确的人头上
//!
//! ★ 为什么每个插件一份 HostApi（而不是全场共用一份）
//! ---------------------------------------------------------------------------
//!   因为宿主必须知道「这次调用是谁发起的」：
//!     · register_service 要知道把服务记在谁的账上
//!     · alloc            要知道从哪个 arena 切内存
//!   共用一份 ctx 就分不出人 —— 轻则记账错位，重则卸载时撤掉别人的注册。
//!   做法：**函数指针全部相同，只有 ctx 不同**（各指向自己的 PluginSlot）。
//!
//! 不变量
//! ---------------------------------------------------------------------------
//!   ① HostApi 的实现函数**绝不 panic、绝不抛 error**，一律用 Status / null
//!      回报。插件崩溃不能传染宿主，宿主崩溃也不该由插件触发。
//!   ② 注册类操作一律「先注册成功、再登记撤销」，责任在宿主（不靠插件自觉）。
//!   ③ deinit 必须先卸 fiber 再释放表 —— 反过来的话，卸载过程（撤销要去服务
//!      表删行）会访问已经释放的表。
//!
//! 当前实现进度（一步一步来，每一步都留可验证的测试）
//! ---------------------------------------------------------------------------
//!   已完成: init / deinit / newFiber / apiAlloc / apiLog
//!   下一步: apiRegisterService / apiGetService / apiRevoke（服务注册闭环）
//!   再下一步: mountPlugin / unmountPlugin（真 dlopen 一个 .so）
//!   推迟:   apiOnEvent（事件总线第二批）、依赖门（settle）、隔离作用域

const std = @import("std");
const abi = @import("dsh_abi");
const fiber_mod = @import("fiber.zig");
const services = @import("services.zig");

/// 交给某个插件的私有包装。
///
/// 它只做一件事：记住「这一份 HostApi 属于谁」。
/// 插件的每次回调都带着指向自己 slot 的 ctx，宿主据此反查 fiber。
pub const PluginSlot = struct {
    host: *Context,
    fiber: *fiber_mod.Fiber,
    /// 这个插件专属的那一份 HostApi（ctx 指向本 slot）。
    api: abi.HostApi = undefined,
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    registry: services.Registry,

    /// 所有活着的 fiber。deinit 时逆序卸载。
    fibers: std.ArrayList(*fiber_mod.Fiber),
    /// 每个 fiber 一个 slot。**在堆上**，地址稳定 —— 插件手里的 api.ctx
    /// 在整个插件生命周期内不能失效。
    slots: std.ArrayList(*PluginSlot),

    /// fiber 编号。单调递增、永不复用（与 Handle.id 同理）。
    next_id: u64 = 1,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Context {
        return .{
            .gpa = gpa,
            .io = io,
            .registry = services.Registry.init(gpa),
            .fibers = .empty,
            .slots = .empty,
        };
    }

    /// 释放宿主：先把 fiber 全部卸完，再释放表。
    pub fn deinit(self: *Context) void {
        var i = self.fibers.items.len;
        while (i > 0) {
            i -= 1;
            // 内部会 unload（撤销 -> dlclose -> arena），此时 registry 还活着
            self.fibers.items[i].deinit();
        }
        self.fibers.deinit(self.gpa);

        for (self.slots.items) |s| self.gpa.destroy(s);
        self.slots.deinit(self.gpa);

        self.registry.deinit();
    }

    /// 建一个 fiber（此时**不**加载代码），并配好它专属的 HostApi。
    /// 返回 slot：`slot.fiber` 是身份，`slot.api` 是交给插件的那份把手。
    pub fn newFiber(self: *Context, name: []const u8, path: ?[]const u8) !*PluginSlot {
        const id = self.next_id;
        self.next_id += 1;

        const f = try fiber_mod.Fiber.create(self.gpa, id, name, path);
        errdefer f.deinit();

        const slot = try self.gpa.create(PluginSlot);
        errdefer self.gpa.destroy(slot);

        slot.* = .{
            .host = self,
            .fiber = f,
            .api = buildApi(slot),
        };

        try self.fibers.append(self.gpa, f);
        errdefer _ = self.fibers.pop();

        try self.slots.append(self.gpa, slot);
        return slot;
    }

    // ───────────────────────────────────────────────────────────────────────
    //  以下为 HostApi 的实现方（C ABI 静态函数）
    //
    //  ⚠️ 共同要求：绝不 panic、绝不抛 error，一律用 abi.Status / null 回报。
    // ───────────────────────────────────────────────────────────────────────

    /// HostApi.alloc：从**调用者自己那个 fiber 的 arena** 分配。
    ///
    /// 这就是「谁的东西谁的生命周期」的物理保证：插件申请的内存天然属于它，
    /// 卸载时随它的 arena 一起还回去，不可能漏。
    pub fn apiAlloc(host_ctx: *anyopaque, len: usize, alignment: u32) callconv(.c) ?*anyopaque {
        // 对齐参数跨 C ABI 进来是字节数，必须是 2 的幂。不对就拒绝，不猜。
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return null;

        const slot = slotFrom(host_ctx);
        const aligned: std.mem.Alignment = .fromByteUnits(alignment);
        // 用 rawAlloc 而不是 alignedAlloc：后者的对齐参数是 comptime 的，
        // 而这里的对齐来自 C ABI，只能是运行时值。
        const raw = std.mem.Allocator.rawAlloc(
            slot.fiber.allocator(),
            len,
            aligned,
            @returnAddress(),
        ) orelse return null;
        return @ptrCast(raw);
    }

    /// HostApi.log：写 stderr，带插件名前缀。
    ///
    /// 前缀不是装饰：多个插件的输出混在一起时，没有前缀就分不清是谁在说话。
    pub fn apiLog(host_ctx: *anyopaque, level: abi.LogLevel, msg: [*:0]const u8) callconv(.c) void {
        const slot = slotFrom(host_ctx);
        std.debug.print("[plugin:{s}] {s}: {s}\n", .{
            slot.fiber.name,
            levelName(level),
            std.mem.span(msg),
        });
    }

    /// HostApi.register_service：**下一步实现**。
    /// 现在诚实返回「无效句柄」，而不是假装成功 —— 假装成功会让插件以为
    /// 自己注册上了，实际什么都没有。
    pub fn apiRegisterService(
        host_ctx: *anyopaque,
        name: [*:0]const u8,
        iface: *const anyopaque,
        impl: *anyopaque,
        scope: u64,
    ) callconv(.c) abi.Handle {
        _ = host_ctx;
        _ = name;
        _ = iface;
        _ = impl;
        _ = scope;
        return abi.INVALID_HANDLE;
    }

    /// HostApi.get_service：**下一步实现**。
    pub fn apiGetService(
        host_ctx: *anyopaque,
        name: [*:0]const u8,
        scope: u64,
    ) callconv(.c) ?*anyopaque {
        _ = host_ctx;
        _ = name;
        _ = scope;
        return null;
    }

    /// HostApi.on_event：事件总线推迟到第二批（它要先动 ABI 才能表达 waterfall）。
    /// 返回无效句柄 —— 调用方会把它当成「没注册上」，安全。
    pub fn apiOnEvent(
        host_ctx: *anyopaque,
        event: [*:0]const u8,
        mode: abi.DispatchMode,
        cb: abi.Callback,
    ) callconv(.c) abi.Handle {
        _ = host_ctx;
        _ = event;
        _ = mode;
        _ = cb;
        return abi.INVALID_HANDLE;
    }

    /// HostApi.revoke（插件主动提前撤销）：**下一步实现**。
    pub fn apiRevoke(host_ctx: *anyopaque, h: abi.Handle) callconv(.c) abi.Status {
        _ = host_ctx;
        _ = h;
        return .err_internal;
    }
};

// ───────────────────────────────────────────────────────────────────────────
//  内部工具
// ───────────────────────────────────────────────────────────────────────────

/// 构造某个 slot 专属的 HostApi：函数指针全同，只有 ctx 指向自己。
fn buildApi(slot: *PluginSlot) abi.HostApi {
    return .{
        .abi_version = abi.ABI_VERSION,
        .ctx = @ptrCast(slot),
        .alloc = Context.apiAlloc,
        .log = Context.apiLog,
        .register_service = Context.apiRegisterService,
        .get_service = Context.apiGetService,
        .on_event = Context.apiOnEvent,
        .revoke = Context.apiRevoke,
    };
}

/// 从插件回传的 ctx 反查它属于哪个 slot。
fn slotFrom(host_ctx: *anyopaque) *PluginSlot {
    return @ptrCast(@alignCast(host_ctx));
}

fn levelName(level: abi.LogLevel) []const u8 {
    return switch (level) {
        .debug => "debug",
        .info => "info",
        .warn => "warn",
        .err => "error",
    };
}

// ───────────────────────────────────────────────────────────────────────────
//  测试
// ───────────────────────────────────────────────────────────────────────────

test "每个 fiber 一份 api：ctx 各不相同、函数指针相同" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const a = try ctx.newFiber("plugin-a", null);
    const b = try ctx.newFiber("plugin-b", null);

    // 这是宿主认人的唯一依据
    try std.testing.expect(a.api.ctx != b.api.ctx);
    try std.testing.expectEqual(a.api.ctx, @as(*anyopaque, @ptrCast(a)));
    // 能力是同一套实现
    try std.testing.expectEqual(a.api.alloc, b.api.alloc);
    try std.testing.expectEqual(a.api.log, b.api.log);

    // 版本守卫能用
    try std.testing.expectEqual(abi.ABI_VERSION, a.api.abi_version);
    try std.testing.expectEqual(abi.Status.ok, a.api.check());

    try std.testing.expectEqual(@as(usize, 2), ctx.fibers.items.len);
}

test "apiAlloc: 从调用者自己的 arena 出，别的 fiber 不受影响" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const mine = try ctx.newFiber("mine", null);
    const other = try ctx.newFiber("other", null);

    const p = mine.api.alloc(mine.api.ctx, 4096, 8);
    try std.testing.expect(p != null);
    try std.testing.expect(mine.fiber.arena.queryCapacity() > 0);
    // 关键：内存记在调用者账上，不是别人账上
    try std.testing.expectEqual(@as(usize, 0), other.fiber.arena.queryCapacity());

    // 对齐参数必须是 2 的幂；不是就拒绝而不是硬来
    try std.testing.expect(mine.api.alloc(mine.api.ctx, 16, 0) == null);
    try std.testing.expect(mine.api.alloc(mine.api.ctx, 16, 3) == null);
    try std.testing.expect(mine.api.alloc(mine.api.ctx, 16, 64) != null);
}

test "apiLog: 带插件名前缀，不崩" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const slot = try ctx.newFiber("hello", null);
    slot.api.log(slot.api.ctx, .info, "来自测试的问候");
    slot.api.log(slot.api.ctx, .err, "一个错误级别");
}

test "还没实现的能力诚实返回，不崩、不假装成功" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const slot = try ctx.newFiber("stub", null);
    const api = slot.api;

    // 注册：返回无效句柄（而不是假装成功）—— 插件会看到 id == 0
    const h = api.register_service(api.ctx, "something", @ptrCast(slot), @ptrCast(slot), 0);
    try std.testing.expectEqual(abi.INVALID_HANDLE.id, h.id);
    try std.testing.expectEqual(@as(usize, 0), ctx.registry.count());

    // 查服务：没有就是 null（不是错误）
    try std.testing.expect(api.get_service(api.ctx, "something", 0) == null);

    // 事件总线推迟：同样是无效句柄
    const ev = api.on_event(api.ctx, "tool/call", .emit, struct {
        fn cb(_: *anyopaque, _: *const abi.EventPayload) callconv(.c) void {}
    }.cb);
    try std.testing.expectEqual(abi.INVALID_HANDLE.id, ev.id);

    // 主动撤销：明确失败，不静默
    try std.testing.expectEqual(abi.Status.err_internal, api.revoke(api.ctx, .{ .id = 1 }));
}

test "deinit: 卸掉所有 fiber 且无泄漏（testing.allocator 会报告）" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);

    for ([_][]const u8{ "a", "b", "c" }, 0..) |name, i| {
        const slot = try ctx.newFiber(name, null);
        // 每个 fiber 都分配点东西，验证 arena 被整块回收
        _ = slot.api.alloc(slot.api.ctx, 1024 * (i + 1), 8);
    }
    try std.testing.expectEqual(@as(usize, 3), ctx.fibers.items.len);

    ctx.deinit();
}
