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
//!          mountPlugin / unmountPlugin（真 dlopen 一个 .so）
//!          apiReadFile / apiWriteFile / apiRunShell（ABI v2 的三个基础能力）
//!   下一步: plugins/tools.zig 把四件套搬进 .so
//!   推迟:   apiOnEvent（事件总线第二批）、依赖门（settle）、隔离作用域
//!
//! 已知待决问题（等第一个真实的消费者插件出现再定，现在不拍脑袋设计）
//! ---------------------------------------------------------------------------
//!   `get_service` 只返回接口表（iface），而调用一个方法还需要提供者的实例
//!   指针（impl）。现在是宿主侧直接从表里取 impl 来调用。等真有插件要消费
//!   别人的服务时，再决定是让 get_service 返回 { iface, impl } 还是让接口
//!   结构体自带 impl 字段。

const std = @import("std");
const abi = @import("dsh_abi");
const fiber_mod = @import("fiber.zig");
const services = @import("services.zig");
const loader = @import("loader.zig");

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

    // ── 宿主侧的挂载 / 卸载入口 ─────────────────────────────────────────────

    /// 按 fiber 找回它的 slot。热重载要用：拆旧之前得知道拆的是哪一个。
    pub fn slotOfFiber(self: *Context, f: *fiber_mod.Fiber) ?*PluginSlot {
        for (self.slots.items) |s| {
            if (s.fiber == f) return s;
        }
        return null;
    }

    pub const MountResult = union(enum) {
        ok: *PluginSlot,
        /// 加载失败。fiber 已经在 load 内部完整回滚过，也已经从表里摘掉，
        /// 调用方什么都不用收拾。
        failed: abi.Status,
    };

    /// 挂载一个插件：分配编号 -> 建 fiber + slot -> dlopen + init -> 完成。
    ///
    /// 失败时**不留半个插件**：load 内部已经跑完撤销清单、dlclose、清 arena，
    /// 这里只负责把它从登记表里摘干净。
    pub fn mountPlugin(
        self: *Context,
        path: []const u8,
        config_json: [:0]const u8,
    ) MountResult {
        const slot = self.newFiber(loader.nameFromPath(path), path) catch
            return .{ .failed = .err_oom };

        const st = slot.fiber.load(&slot.api, config_json);
        if (st != .ok) {
            self.dropFiber(slot.fiber);
            self.dropSlot(slot);
            return .{ .failed = st };
        }
        return .{ .ok = slot };
    }

    /// 卸载一个插件：撤销全部注册 -> dlclose -> 释放 arena -> 摘表 -> 销毁 slot。
    /// （前两步在 fiber.unload 里，顺序铁律见 fiber.zig 文件头。）
    pub fn unmountPlugin(self: *Context, slot: *PluginSlot) void {
        self.dropFiber(slot.fiber);
        self.dropSlot(slot);
    }

    /// 把 fiber 从登记表摘掉并销毁它（deinit 内部会 unload）。
    fn dropFiber(self: *Context, f: *fiber_mod.Fiber) void {
        for (self.fibers.items, 0..) |x, i| {
            if (x == f) {
                _ = self.fibers.orderedRemove(i);
                break;
            }
        }
        f.deinit();
    }

    /// 把 slot 从登记表摘掉并释放。
    /// ⚠️ 必须在 dropFiber **之后**调用：fiber 销毁后 slot.fiber 就是悬垂指针，
    ///    这里不能再读它。
    fn dropSlot(self: *Context, slot: *PluginSlot) void {
        for (self.slots.items, 0..) |s, i| {
            if (s == slot) {
                _ = self.slots.orderedRemove(i);
                break;
            }
        }
        self.gpa.destroy(slot);
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

    // ── 基础能力：文件与进程（ABI v2） ────────────────────────────────────

    /// HostApi.read_file：读文件，内存从**调用者自己的 arena** 切。
    ///
    /// 为什么由宿主分配而不是让插件先给缓冲区：文件大小不可预知；而调用者
    /// arena 随它的 fiber 卸载整体回收，宿主不需要为这块内存做任何记账。
    pub fn apiReadFile(
        host_ctx: *anyopaque,
        path: [*:0]const u8,
        out: *abi.Bytes,
    ) callconv(.c) abi.Status {
        const slot = slotFrom(host_ctx);
        const data = std.Io.Dir.cwd().readFileAlloc(
            slot.host.io,
            std.mem.span(path),
            slot.fiber.allocator(),
            .limited(max_read_bytes),
        ) catch |e| return fileErrorStatus(e);

        out.ptr = data.ptr;
        out.len = data.len;
        return .ok;
    }

    /// HostApi.write_file：覆盖写入。
    /// data 由调用者提供，只在这次调用期间需要有效 —— 宿主立刻写出去，不留引用。
    pub fn apiWriteFile(
        host_ctx: *anyopaque,
        path: [*:0]const u8,
        data: [*]const u8,
        len: usize,
    ) callconv(.c) abi.Status {
        const slot = slotFrom(host_ctx);
        std.Io.Dir.cwd().writeFile(slot.host.io, .{
            .sub_path = std.mem.span(path),
            .data = data[0..len],
        }) catch |e| return fileErrorStatus(e);
        return .ok;
    }

    /// HostApi.run_shell：`bash -lc <command>`，结果写进 out。
    ///
    /// 命令非 0 退出返回 ok（exit_code 里有值）—— 只有「跑不起来」才是错误。
    pub fn apiRunShell(
        host_ctx: *anyopaque,
        command: [*:0]const u8,
        timeout_s: u32,
        out: *abi.ShellResult,
    ) callconv(.c) abi.Status {
        const slot = slotFrom(host_ctx);

        const res = std.process.run(slot.fiber.allocator(), slot.host.io, .{
            // 用 bash -lc 而不是自己切词：命令原样交给 shell，与用户手敲一致
            .argv = &.{ "bash", "-lc", std.mem.span(command) },
            .stdout_limit = .limited(max_shell_bytes),
            .stderr_limit = .limited(max_shell_bytes),
            .timeout = .{ .duration = .{
                .raw = std.Io.Duration.fromSeconds(timeout_s),
                .clock = .awake,
            } },
        }) catch |e| return shellErrorStatus(e);

        out.* = .{
            .stdout_ptr = res.stdout.ptr,
            .stdout_len = res.stdout.len,
            .stderr_ptr = res.stderr.ptr,
            .stderr_len = res.stderr.len,
        };
        switch (res.term) {
            .exited => |code| {
                out.term = .exited;
                out.code = @intCast(code);
            },
            .signal => |sig| {
                out.term = .signal;
                out.code = @intCast(@intFromEnum(sig));
            },
            .stopped => |sig| {
                out.term = .signal;
                out.code = @intCast(@intFromEnum(sig));
            },
            .unknown => {},
        }
        return .ok;
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
        .read_file = Context.apiReadFile,
        .write_file = Context.apiWriteFile,
        .run_shell = Context.apiRunShell,
        .register_service = Context.apiRegisterService,
        .get_service = Context.apiGetService,
        .on_event = Context.apiOnEvent,
        .revoke = Context.apiRevoke,
    };
}

/// 单次读文件的硬上限（防一条 read 把整个大文件灌进 arena）。
/// 这是防爆内存的底线，不是给模型的约束 —— 模型要读多少行由工具的 offset/limit 管。
const max_read_bytes: usize = 16 * 1024 * 1024;

/// 单次命令 stdout / stderr 各自的硬上限（同上是防爆，不是约束）。
const max_shell_bytes: usize = 4 * 1024 * 1024;

/// 文件类操作的错误 → 跨边界状态码。
fn fileErrorStatus(e: anyerror) abi.Status {
    return switch (e) {
        error.FileNotFound => .err_not_found,
        error.OutOfMemory => .err_oom,
        error.StreamTooLong => .err_too_large,
        else => .err_internal,
    };
}

/// 起进程类操作的错误 → 跨边界状态码。
fn shellErrorStatus(e: anyerror) abi.Status {
    return switch (e) {
        error.Timeout => .err_timeout,
        error.StreamTooLong => .err_too_large,
        error.OutOfMemory => .err_oom,
        else => .err_internal,
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

test "apiWriteFile / apiReadFile：写得进读得到，内存记在调用者账上" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const slot = try ctx.newFiber("io-test", null);
    const api = slot.api;

    const path = "/tmp/dsh-context-io-test.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const content = "hello\nworld\n";
    try std.testing.expectEqual(
        abi.Status.ok,
        api.write_file(api.ctx, path, content.ptr, content.len),
    );

    var got: abi.Bytes = .{};
    try std.testing.expectEqual(abi.Status.ok, api.read_file(api.ctx, path, &got));
    try std.testing.expectEqualStrings(content, got.slice());
    // 读回来的内存是从**调用者自己**的 arena 切的
    try std.testing.expect(slot.fiber.arena.queryCapacity() > 0);

    // 文件不存在要说清楚是「找不到」，而不是笼统的内部错误
    var missing: abi.Bytes = .{};
    try std.testing.expectEqual(
        abi.Status.err_not_found,
        api.read_file(api.ctx, "/tmp/dsh-no-such-file-xyz", &missing),
    );
}

test "apiRunShell：拿到退出码与两路输出；非 0 退出不算失败" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const slot = try ctx.newFiber("shell-test", null);
    const api = slot.api;

    var res: abi.ShellResult = .{};
    const st = api.run_shell(api.ctx, "echo to-stdout; echo to-stderr 1>&2; exit 3", 30, &res);

    // 命令退出了（哪怕非 0）就是 ok —— 模型需要看到错误输出才能自己纠正
    try std.testing.expectEqual(abi.Status.ok, st);
    try std.testing.expectEqual(abi.TermKind.exited, res.term);
    try std.testing.expectEqual(@as(i32, 3), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout(), "to-stdout") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stderr(), "to-stderr") != null);
}

test "apiRunShell：超时返回 err_timeout（花 1 秒）" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const slot = try ctx.newFiber("timeout-test", null);
    var res: abi.ShellResult = .{};
    try std.testing.expectEqual(
        abi.Status.err_timeout,
        slot.api.run_shell(slot.api.ctx, "sleep 5", 1, &res),
    );
}
