//! ═══════════════════════════════════════════════════════════════════════════
//!  最小插件 · hello —— 用来验证装卸闭环的探针
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 它做四件事，每件都对应一条要被验证的机制：
//!
//!   1. init 里校验 ABI 版本 —— loader 已经挡过一道，这里再查一次是插件侧
//!      的自我防卫（插件可能被非本项目的宿主加载）。
//!   2. init 里注册一个服务   —— 验证「注册 + 宿主记账」这条链。
//!   3. init 里注册两个事件监听 —— 验证跨 ABI 的回调：一个只观察（emit），
//!      一个改写结果（waterfall）。
//!   4. deinit 里打一句日志   —— 用来观察卸载时序（撤销 -> deinit -> dlclose）。
//!
//! ★ 为什么插件不导出 deinit 也能被正确清理
//! ---------------------------------------------------------------------------
//!   因为**撤销的责任在宿主**：宿主在注册那一刻就把「怎么撤销」记进了 fiber
//!   的清单，插件什么都不做也不会漏。deinit 在这里只是观察点，不是清理的
//!   依赖 —— 宿主不得依赖它（见 abi.PluginDeinitFn 的说明）。
//!
//! 编译：由 build.zig 的 plugin_names 列表负责（加一个插件 = 加一个名字）。

const std = @import("std");
const abi = @import("dsh_abi");
const greeter = @import("dsh_greeter");

/// 测试用它确认「拿到的确实是这个插件里的那一个 iface」。
/// 集成测试里写死了同一个值，两边必须一致。
pub const GREET_MAGIC: u32 = 0x9EE7;

/// 插件自己的状态（服务实例）。真实插件把实例数据挂在这个指针上。
var state: u32 = 0;

/// 保存宿主给的 api，供 deinit 里回报时序（deinit 的签名没有参数）。
var saved_api: ?*const abi.HostApi = null;

fn greetImpl(impl: *anyopaque) callconv(.c) u32 {
    _ = impl;
    return GREET_MAGIC;
}

/// 接口表的实例。做成静态的：**一个插件一份接口表，与实例数据（state）分开** ——
/// 一个插件可以拿同一份接口表开多个实例，各自填自己的 impl。
const greeter_iface = greeter.GreeterIface{ .greet = greetImpl };

// ───────────────────────────────────────────────────────────────────────────
//  两个事件监听器：验证跨 ABI 的回调真的能进插件代码
// ───────────────────────────────────────────────────────────────────────────

/// 监听器自己的状态。Zig 没有闭包，插件要访问自己的数据只能靠 on_event 传来
/// 的这个 user 指针。
var ping_count: u32 = 0;

/// 只观察、然后放行（emit 的典型用法）
fn onPing(user: *anyopaque, payload: *abi.EventPayload, next_ctx: *anyopaque, next: abi.NextFn) callconv(.c) abi.Status {
    const counter: *u32 = @ptrCast(@alignCast(user));
    counter.* += 1;
    if (saved_api) |api| {
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "收到 {s}（累计 {d} 次）", .{
            std.mem.span(payload.name), counter.*,
        }) catch "收到事件";
        api.log(api.ctx, .info, msg.ptr);
    }
    return next(next_ctx, payload);
}

/// 监听 tool/pre-execute：只观察、然后放行。
/// 它存在的意义是：在**真实对话**里确认 loop 确实每次工具调用前都发了事件
/// （日志里会出现「工具即将执行 …」）。真正的权限门插件会在 next() 之前决定
/// 是否放行，这里只是探针。
fn onToolPre(user: *anyopaque, payload: *abi.EventPayload, next_ctx: *anyopaque, next: abi.NextFn) callconv(.c) abi.Status {
    _ = user;
    if (saved_api) |api| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "工具即将执行：{s}", .{
            std.mem.span(payload.json),
        }) catch "工具即将执行";
        api.log(api.ctx, .info, msg.ptr);
    }
    return next(next_ctx, payload);
}

/// 先放行、拿到内层结果再改写（waterfall 的典型用法）。
/// 这就是「插件动态改 system prompt」将来要走的路：宿主把默认值预先写进
/// payload.out，插件在链上把它换掉。
fn onPrompt(user: *anyopaque, payload: *abi.EventPayload, next_ctx: *anyopaque, next: abi.NextFn) callconv(.c) abi.Status {
    _ = user;
    const st = next(next_ctx, payload);
    if (st != .ok) return st;

    var buf: [512]u8 = undefined;
    const wrapped = std.fmt.bufPrint(&buf, "[hello 加料] {s}", .{payload.out()}) catch
        return .err_too_large;
    payload.setOut(wrapped);
    return .ok;
}

// ───────────────────────────────────────────────────────────────────────────
//  插件导出的符号
// ───────────────────────────────────────────────────────────────────────────

pub export fn dsh_plugin_abi_version() callconv(.c) u32 {
    return abi.ABI_VERSION;
}

pub export fn dsh_plugin_init(
    api: *const abi.HostApi,
    config_json: [*:0]const u8,
) callconv(.c) abi.Status {
    _ = config_json; // 这个插件没有配置项

    // 第一件事永远是校验 ABI：版本不一致时两侧类型布局可能已经不同，
    // 此时读 api 的任何字段都是灾难。
    const st = api.check();
    if (st != .ok) return st;

    saved_api = api;
    api.log(api.ctx, .info, "hello 插件启动");

    // 注册服务。失败必须如实返回 —— 假装成功会让宿主以为有这么个服务。
    const h = api.register_service(
        api.ctx,
        greeter.NAME,
        @ptrCast(&greeter_iface),
        @ptrCast(&state),
        0, // scope 0 = 根作用域
    );
    if (h.id == 0) return .err_duplicate;

    api.log(api.ctx, .info, "greeter 服务已注册");

    // 两个监听：注册与记账同样成对（责任在宿主）
    if (api.on_event(api.ctx, EVENT_PING, onPing, @ptrCast(&ping_count)).id == 0) {
        return .err_internal;
    }
    if (api.on_event(api.ctx, EVENT_PROMPT, onPrompt, @ptrCast(&state)).id == 0) {
        return .err_internal;
    }
    // 真实事件：loop 每次工具调用前发的那个（只观察，不拦）
    if (api.on_event(api.ctx, abi.EventNames.tool_pre_execute, onToolPre, @ptrCast(&state)).id == 0) {
        return .err_internal;
    }

    return .ok;
}

/// 这个插件监听的事件名（测试与宿主都按它对表）
pub const EVENT_PING = "demo/ping";
pub const EVENT_PROMPT = "demo/prompt";

/// 可选导出。宿主**不得依赖**它做清理（清理由宿主的撤销清单保证）。
/// 它存在的意义是让我们能观察卸载时序：应当在撤销之后、dlclose 之前被调用。
pub export fn dsh_plugin_deinit() callconv(.c) void {
    if (saved_api) |api| {
        api.log(api.ctx, .info, "hello 收尾（撤销已完成，.so 即将卸载）");
    }
    saved_api = null;
}
