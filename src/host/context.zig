//! ═══════════════════════════════════════════════════════════════════════════
//!  Context —— 宿主的门面，把阶段 1–3 缝在一起        【草图 / 空壳】
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 这个结构就是 Cordis 里 `Context` 的 Zig 版。差别在于：
//!
//!     Cordis: ctx 是 Proxy，读 ctx.tools 会动态查表
//!     Zig   : ctx 是普通结构体，插件通过 HostApi 回调来查表
//!
//! 也就是说：**Cordis 把「查表」藏在属性读取语法里，Zig 把它变成显式调用。**
//! 功能等价，写法不同——这是本移植最大的风格差异，也是最该先接受的事。
//!
//! 它同时扮演 HostApi 的实现方（插件调用的那些函数指针都指向本结构的静态函数）。
//!
//! ⚠️ 空壳。

const std = @import("std");
const abi = @import("dsh_abi");
const fiber_mod = @import("fiber.zig");
const services = @import("services.zig");
const events = @import("events.zig");
const loader = @import("loader.zig");

/// 宿主上下文。整个进程里只有一份（root）。
pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    registry: services.Registry,
    bus: events.Bus,
    scopes: services.Scopes,

    /// 所有活着的 fiber（含 root）。
    fibers: std.ArrayList(*fiber_mod.Fiber),
    /// 每个 fiber 一个 arena：key = fiber.id
    arenas: std.AutoHashMap(u64, *std.heap.ArenaAllocator),

    /// 暴露给插件的 API 表。**只构造一次**，内容是下面那些 C ABI 静态函数。
    api: abi.HostApi = undefined,

    /// 初始化：建表、装内置服务、构造 API 表。
    pub fn init(gpa: std.mem.Allocator, io: std.Io) Context {
        _ = gpa;
        _ = io;
        @panic("TODO: 把阶段 1–3 的组件装配起来，并填充 api 函数表");
    }

    /// 释放宿主。
    /// 顺序要求：先把所有 fiber 卸完，再释放服务表/事件表
    /// （反过来的话，卸载过程会去访问已经释放的表）。
    pub fn deinit(self: *Context) void {
        _ = self;
        @panic("TODO: 卸载全部 fiber → 释放 registry/bus/scopes");
    }

    /// 供 agent loop 使用的「取工具表」回调（C ABI）。
    /// 对应 Cordis 里循环里那句 `ctx.tools`。
    pub fn cGetTools(host_ctx: *anyopaque) callconv(.c) ?*const anyopaque {
        _ = host_ctx;
        @panic("TODO: 转发到 registry.get(\"tools\", 0)");
    }

    /// 供 agent loop 使用的「发事件」回调（C ABI）。
    pub fn cEmit(host_ctx: *anyopaque, payload: *const abi.EventPayload) callconv(.c) void {
        _ = host_ctx;
        _ = payload;
        @panic("TODO: 转发到 bus.emit");
    }

    /// 构造交给插件的 API 表。
    ///
    /// 所有函数指针都指向本文件的 `extern` 风格静态函数，
    /// 第一个参数统一是 `*anyopaque`（就是指向本 Context 的指针）。
    pub fn buildApi(self: *Context) abi.HostApi {
        _ = self;
        @panic("TODO: 填充 abi.HostApi 的各个字段");
    }

    // ───────────────────────────────────────────────────────────────────────
    //  下面这些是 HostApi 的实现方（C ABI 静态函数）
    //
    //  ⚠️ 共同要求：**绝不 panic、绝不抛 error**，一律用 abi.Status 回报。
    //     插件的崩溃不能传染给宿主；宿主的崩溃也不该由插件触发。
    // ───────────────────────────────────────────────────────────────────────

    /// HostApi.alloc 的实现：从「调用者所属 fiber 的 arena」分配。
    ///
    /// 怎么知道调用者是哪个 fiber？草图方案：每个插件实例在自己的
    /// HostApi 副本里带一个标识（ctx 指针指向一个 per-plugin 的薄包装）。
    /// 这样插件无法越界分配，也天然做到「谁的东西谁的生命周期」。
    pub fn apiAlloc(host_ctx: *anyopaque, len: usize, alignment: u32) callconv(.c) ?*anyopaque {
        _ = host_ctx;
        _ = len;
        _ = alignment;
        @panic("TODO: 从 per-plugin arena 分配");
    }

    /// HostApi.log 的实现：按级别输出。诊断友好度直接影响调试体验
    /// （Cordis 的 logger 有格式化与分级过滤，这里先做最小版）。
    pub fn apiLog(host_ctx: *anyopaque, level: abi.LogLevel, msg: [*:0]const u8) callconv(.c) void {
        _ = host_ctx;
        _ = level;
        _ = msg;
        @panic("TODO: 写 stderr，带插件名前缀");
    }

    /// HostApi.register_service 的实现。
    ///
    /// 三步，顺序固定：
    ///   ① registry.provide() —— 分配编号、入表、记 owner
    ///   ② 用**宿主分配器**造一条撤销项（存编号，不存名字），追加到
    ///      **调用者这个 fiber** 的撤销清单里
    ///   ③ 通知等在服务上的 fiber 重算状态
    /// 「注册」和「登记撤销」必须成对，漏一个就是卸载后段错误。
    ///
    /// ★ 怎么知道调用者是哪个 fiber：交给插件的 HostApi 是**每个插件各一份**
    ///   的，ctx 指向一个 per-plugin 薄包装 —— 插件无法冒充别人，也天然做到
    ///   「谁注册的东西记在谁头上」。
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
        @panic("TODO: 入服务表 + 登记撤销 + 通知依赖者");
    }

    /// HostApi.get_service 的实现。
    /// 这就是 Cordis `ctx.tools` 的对应物。
    pub fn apiGetService(host_ctx: *anyopaque, name: [*:0]const u8, scope: u64) callconv(.c) ?*anyopaque {
        _ = host_ctx;
        _ = name;
        _ = scope;
        @panic("TODO: 查服务表（不存在返回 null，不是错误）");
    }

    /// HostApi.on_event 的实现。
    /// 与 register_service 同构：分配编号 → 入表 → 用宿主分配器登记撤销项。
    /// 同一事件名可以注册多条，所以撤销必须按编号而不是按事件名。
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
        @panic("TODO: 注册监听 + 登记撤销");
    }

    /// HostApi.revoke 的实现 —— 插件主动提前撤销某一条注册（可选能力）。
    ///
    /// 做三件事：按 Handle.id 在**调用者 fiber 的撤销清单**里找到那一条 →
    /// 执行它（去宿主表里删掉对应行）→ 把它从清单里移除。
    /// 找不到 = 早就撤过了，返回 err_not_found，**不崩**（幂等）。
    ///
    /// ★ 注意这不是「卸载」：卸载是宿主对整份清单的批量执行；
    ///   这个函数只是把清单上的单条提前执行。两者共用同一份撤销项。
    pub fn apiRevoke(host_ctx: *anyopaque, h: abi.Handle) callconv(.c) abi.Status {
        _ = host_ctx;
        _ = h;
        @panic("TODO: 按 handle 找到注册项并撤销");
    }

    // ───────────────────────────────────────────────────────────────────────

    /// 把本 Context 的地址作为不透明句柄交出去（插件与循环都用它回传）。
    pub fn handle(self: *Context) *anyopaque {
        _ = self;
        @panic("TODO: 返回 @ptrCast(self)");
    }

    /// 挂载一个插件（宿主侧入口）。
    pub fn mountPlugin(self: *Context, path: []const u8, config_json: [:0]const u8) !*fiber_mod.Fiber {
        _ = self;
        _ = path;
        _ = config_json;
        @panic("TODO: 委托 loader.mount");
    }

    /// 卸载一个插件。
    pub fn unmountPlugin(self: *Context, f: *fiber_mod.Fiber) void {
        _ = self;
        _ = f;
        @panic("TODO: 委托 loader.unmount");
    }

    /// 收敛：等所有 fiber 稳定（active 或 pending），把失败集中上报。
    ///
    /// 对应 Cordis 的 `ctx.loader.await()`。
    /// 注意 pending 不算失败 —— 依赖未满足是合法状态。
    pub fn settle(self: *Context) !void {
        _ = self;
        @panic("TODO: 循环直到没有状态变化；聚合失败上报");
    }
};
