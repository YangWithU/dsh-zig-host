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
//!          apiRegisterService / apiGetService / apiRevoke（服务注册闭环）
//!   下一步: mountPlugin / unmountPlugin（真 dlopen 一个 .so）
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

    /// HostApi.register_service：把调用者的能力放上桌，并**同时记账**。
    ///
    /// 三步，顺序固定：
    ///   ① registry.provide        —— 分配编号、入表、记 owner
    ///   ② 用宿主分配器造一条撤销项（存编号与代次，不存名字）追加到
    ///      **调用者这个 fiber** 的撤销清单里
    ///   ③ 返回 Handle 给插件
    ///
    /// 「注册」与「登记撤销」必须成对且先注册后记账：漏一个就是卸载后段错误；
    /// 顺序反了则可能留下一条指向不存在注册的脏账（provide 因重名失败时）。
    /// 任何一步失败都要把前面已做的撤掉 —— 不留半个注册。
    pub fn apiRegisterService(
        host_ctx: *anyopaque,
        name: [*:0]const u8,
        iface: *const anyopaque,
        impl: *anyopaque,
        scope: u64,
    ) callconv(.c) abi.Handle {
        const slot = slotFrom(host_ctx);
        const host = slot.host;

        // ① 入表（重名或分配失败 -> 无效句柄）
        const h = host.registry.provide(.{
            .name = std.mem.span(name),
            .scope = scope,
            .iface = iface,
            .impl = impl,
            .owner = slot.fiber,
        });
        if (h.id == 0) return abi.INVALID_HANDLE;

        // ②a 造撤销项的上下文（宿主分配器，**不走插件 arena**）
        const info = host.gpa.create(ServiceRevoke) catch {
            // 连账都记不上，就必须把刚注册的撤掉：
            // 否则表里留着一个永远不会被撤销的注册（卸载后就是野指针）。
            host.registry.revoke(h.id, h.generation, slot.fiber);
            return abi.INVALID_HANDLE;
        };
        info.* = .{ .registry = &host.registry, .owner = slot.fiber };

        // ②b 记账
        slot.fiber.addDisposable(.{
            .id = h.id,
            .generation = h.generation,
            .run = revokeService,
            .data = @ptrCast(info),
            // 标签不拼上服务名：那个字符串来自插件，生命周期不归我们管，
            // 而标签要留到卸载时用。诊断时按 id 去表里查即可。
            .label = "service",
        }) catch {
            host.gpa.destroy(info);
            host.registry.revoke(h.id, h.generation, slot.fiber);
            return abi.INVALID_HANDLE;
        };

        return h;
    }

    /// HostApi.get_service：这就是 Cordis `ctx.tools` 的对应物。
    /// 没有这个服务 -> 返回 null（**不是错误**：依赖未就绪是合法状态）。
    pub fn apiGetService(
        host_ctx: *anyopaque,
        name: [*:0]const u8,
        scope: u64,
    ) callconv(.c) ?*anyopaque {
        const slot = slotFrom(host_ctx);
        const iface = slot.host.registry.get(std.mem.span(name), scope) orelse return null;
        // 返回接口表本身；调用方自己 cast 成具体的 iface 类型
        return @constCast(iface);
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

    /// HostApi.revoke：插件主动提前撤销某一条注册（可选能力）。
    ///
    /// 在本 fiber 的撤销清单里按 (id, generation) 找到那一条 -> 执行它
    /// （去宿主表里删行）-> 从清单里移除。
    ///
    /// ★ 这不是「卸载」：卸载是宿主对整份清单的批量执行；这里只是把其中
    ///   一条提前执行。两者共用同一份撤销项，所以两条路径不会打架。
    pub fn apiRevoke(host_ctx: *anyopaque, h: abi.Handle) callconv(.c) abi.Status {
        const slot = slotFrom(host_ctx);
        const f = slot.fiber;

        for (f.disposers.items, 0..) |*d, i| {
            // id 撞上但代次不同 = 「重新注册后的新一代」，不是你要撤的那条
            if (d.id != h.id or d.generation != h.generation) continue;
            d.run(d);
            _ = f.disposers.orderedRemove(i);
            return .ok;
        }

        // 找不到 = 早就撤过了（幂等，不崩）
        return .err_not_found;
    }
};

// ───────────────────────────────────────────────────────────────────────────
//  内部工具
// ───────────────────────────────────────────────────────────────────────────

/// 一条「撤销某个服务注册」所需的信息。
/// 用**宿主分配器**分配，`revokeService` 里自己还回去 —— 撤销清单的生命周期
/// 必须独立于插件 arena（arena 会在卸载时整块清空）。
const ServiceRevoke = struct {
    registry: *services.Registry,
    owner: *fiber_mod.Fiber,
};

fn revokeService(d: *fiber_mod.Disposable) void {
    const info: *ServiceRevoke = @ptrCast(@alignCast(d.data));
    info.registry.revoke(d.id, d.generation, info.owner);
    // 谁分配谁释放：这条撤销项的上下文用完就还
    info.registry.gpa.destroy(info);
}

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

    // 事件总线推迟到第二批（它得先改 ABI 才能表达 waterfall）。
    // 返回无效句柄而不是空指针 —— 插件会把它当成「没注册上」，安全。
    const ev = api.on_event(api.ctx, "tool/call", .emit, struct {
        fn cb(_: *anyopaque, _: *const abi.EventPayload) callconv(.c) void {}
    }.cb);
    try std.testing.expectEqual(abi.INVALID_HANDLE.id, ev.id);
}

test "register_service -> get_service：注册与取用，记账成对" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const provider = try ctx.newFiber("provider", null);
    const consumer = try ctx.newFiber("consumer", null);
    var iface_blob: u32 = 1;
    var impl_blob: u32 = 2;

    const h = provider.api.register_service(
        provider.api.ctx,
        "greeter",
        @ptrCast(&iface_blob),
        @ptrCast(&impl_blob),
        0,
    );
    try std.testing.expect(h.id != 0);

    // 表里一行，owner 记的是提供者
    try std.testing.expectEqual(@as(usize, 1), ctx.registry.count());
    const entry = ctx.registry.lookup(h.id).?;
    try std.testing.expectEqualStrings("greeter", entry.name);
    try std.testing.expect(entry.owner == provider.fiber);
    try std.testing.expect(entry.iface == @as(*const anyopaque, @ptrCast(&iface_blob)));

    // 记账成对：清单里恰好一条，id 与代次都对得上
    try std.testing.expectEqual(@as(usize, 1), provider.fiber.disposers.items.len);
    try std.testing.expectEqual(h.id, provider.fiber.disposers.items[0].id);
    try std.testing.expectEqual(h.generation, provider.fiber.disposers.items[0].generation);

    // 另一个插件按名字就能取到手
    const got = consumer.api.get_service(consumer.api.ctx, "greeter", 0);
    try std.testing.expect(got != null);
    try std.testing.expect(got.? == @as(*anyopaque, @ptrCast(&iface_blob)));

    // 别的 scope 没这份；不存在的名字是 null（不是错误）
    try std.testing.expect(consumer.api.get_service(consumer.api.ctx, "greeter", 5) == null);
    try std.testing.expect(consumer.api.get_service(consumer.api.ctx, "nope", 0) == null);
}

test "拒重名；卸载后表与清单双双清零（零残留）" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const slot = try ctx.newFiber("plug", null);
    var blob: u32 = 1;

    const h1 = slot.api.register_service(slot.api.ctx, "tools", @ptrCast(&blob), @ptrCast(&blob), 0);
    try std.testing.expect(h1.id != 0);

    // 同名同 scope -> 拒，且**不留下脏账**
    const dup = slot.api.register_service(slot.api.ctx, "tools", @ptrCast(&blob), @ptrCast(&blob), 0);
    try std.testing.expectEqual(abi.INVALID_HANDLE.id, dup.id);
    try std.testing.expectEqual(@as(usize, 1), ctx.registry.count());
    try std.testing.expectEqual(@as(usize, 1), slot.fiber.disposers.items.len);

    // 同名不同 scope -> 允许共存
    const h3 = slot.api.register_service(slot.api.ctx, "tools", @ptrCast(&blob), @ptrCast(&blob), 7);
    try std.testing.expect(h3.id != 0);
    try std.testing.expectEqual(@as(usize, 2), ctx.registry.count());
    try std.testing.expectEqual(@as(usize, 2), slot.fiber.disposers.items.len);

    // ★ 这一条就是阶段 1 的验收命题：挂载 -> 注册 N 项 -> 卸载 -> 零残留
    slot.fiber.unload();
    try std.testing.expectEqual(@as(usize, 0), ctx.registry.count());
    try std.testing.expectEqual(@as(usize, 0), slot.fiber.disposers.items.len);

    // 再卸一次幂等
    slot.fiber.unload();
    try std.testing.expectEqual(@as(usize, 0), ctx.registry.count());
}

test "apiRevoke：插件提前撤掉单条，幂等且不动别人的" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const slot = try ctx.newFiber("plug", null);
    var blob: u32 = 1;

    const h1 = slot.api.register_service(slot.api.ctx, "a", @ptrCast(&blob), @ptrCast(&blob), 0);
    const h2 = slot.api.register_service(slot.api.ctx, "b", @ptrCast(&blob), @ptrCast(&blob), 0);
    try std.testing.expectEqual(@as(usize, 2), ctx.registry.count());

    // 提前撤掉 a
    try std.testing.expectEqual(abi.Status.ok, slot.api.revoke(slot.api.ctx, h1));
    try std.testing.expectEqual(@as(usize, 1), ctx.registry.count());
    try std.testing.expectEqual(@as(usize, 1), slot.fiber.disposers.items.len);
    // 撤的是 a 不是 b
    try std.testing.expect(ctx.registry.get("a", 0) == null);
    try std.testing.expect(ctx.registry.get("b", 0) != null);

    // 再撤一次：清单里已经没有这条了
    try std.testing.expectEqual(abi.Status.err_not_found, slot.api.revoke(slot.api.ctx, h1));
    // 代次对不上也不撤
    try std.testing.expectEqual(
        abi.Status.err_not_found,
        slot.api.revoke(slot.api.ctx, .{ .id = h2.id, .generation = h2.generation + 1 }),
    );
    try std.testing.expectEqual(@as(usize, 1), ctx.registry.count());

    // 剩下的那条仍然能被卸载流程收走
    slot.fiber.unload();
    try std.testing.expectEqual(@as(usize, 0), ctx.registry.count());
    try std.testing.expectEqual(@as(usize, 0), slot.fiber.disposers.items.len);
}

test "卸载一个插件不会动另一个插件的注册" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const a = try ctx.newFiber("a", null);
    const b = try ctx.newFiber("b", null);
    var blob: u32 = 1;

    _ = a.api.register_service(a.api.ctx, "fs", @ptrCast(&blob), @ptrCast(&blob), 0);
    _ = b.api.register_service(b.api.ctx, "net", @ptrCast(&blob), @ptrCast(&blob), 0);
    try std.testing.expectEqual(@as(usize, 2), ctx.registry.count());

    a.fiber.unload();
    try std.testing.expectEqual(@as(usize, 1), ctx.registry.count());
    // b 的还在，a 的没了
    try std.testing.expect(b.api.get_service(b.api.ctx, "net", 0) != null);
    try std.testing.expect(ctx.registry.get("fs", 0) == null);
    // b 的账也没被动
    try std.testing.expectEqual(@as(usize, 1), b.fiber.disposers.items.len);
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
