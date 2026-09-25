//! ═══════════════════════════════════════════════════════════════════════════
//!  阶段 1 · 最小示例插件 —— 验证「装卸闭环」         【草图 / 空壳】
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 这个插件是阶段 1 的验收工具，故意做得极小：
//!     注册一个服务 + 一个事件监听 + 一次分配 → 卸载后三者必须全部消失
//!
//! 它验证的命题：
//!     「动态加载 + 安全卸载」这条闭环成立。
//!   如果这一步不成立，后面所有阶段都没有意义（已实测：漏撤销 = 段错误）。
//!
//! 编译方式：
//!     zig build-lib -dynamic -fPIC --name hello src/plugins/hello.zig -lc
//!
//! ⚠️ 空壳。

const std = @import("std");
const abi = @import("dsh_abi");

/// 插件自报的 ABI 版本。宿主加载时会先比对这个值。
pub export fn dsh_plugin_abi_version() callconv(.c) u32 {
    @panic("TODO: 阶段 1 —— 返回 abi.ABI_VERSION");
}

/// 记录本实例注册过的句柄 —— **纯诊断用**，不是卸载所需。
/// 卸载由宿主按自己的撤销清单完成，插件丢不丢这些句柄都不影响清理干净。
var g_state: struct {
    api: ?*const abi.HostApi = null,
    svc_handle: abi.Handle = abi.INVALID_HANDLE,
    event_handle: abi.Handle = abi.INVALID_HANDLE,
} = .{};

/// 一个极简服务接口（演示「服务接口 = extern struct of fn pointers」）。
pub const HelloIface = extern struct {
    greet: *const fn (impl: *anyopaque, out: *abi.HostApi) callconv(.c) void,
};

fn greetImpl(impl: *anyopaque, out: *abi.HostApi) callconv(.c) void {
    _ = impl;
    _ = out;
    @panic("TODO: 阶段 1 —— 通过 host api.log 打印一句话");
}

var hello_iface = HelloIface{ .greet = &greetImpl };

/// 事件回调。注意：这个函数指针会被宿主存下来，所以它的代码**必须**
/// 在宿主撤销它之后才能被卸载（撤销先于 dlclose）。
fn onEvent(host_ctx: *anyopaque, payload: *const abi.EventPayload) callconv(.c) void {
    _ = host_ctx;
    _ = payload;
    @panic("TODO: 阶段 1 —— 打印收到的事件名");
}

/// 插件入口。
///
/// 顺序（每一步都必须成功才继续，失败要回滚已做的部分）：
///     1. api.check()      校验 ABI
///     2. api.alloc()      试分配（验证 arena 通路）
///     3. register_service 注册 hello 服务，记下句柄
///     4. on_event         监听某事件，记下句柄
pub export fn dsh_plugin_init(api: *const abi.HostApi, config_json: [*:0]const u8) callconv(.c) abi.Status {
    _ = api;
    _ = config_json;
    @panic("TODO: 阶段 1 —— 校验 ABI → 分配 → 注册服务 → 注册监听");
}

/// 可选导出：主动收尾钩子（这个插件**不需要**它）。
///
/// 它注册的东西（一个服务 + 一个监听）全部经由 HostApi，卸载时由**宿主**
/// 按撤销清单撤掉，arena 也由宿主清空。这里只留一个打印，用来验证卸载时序
/// （它必须发生在 dlclose 之前）。
///
/// 什么插件才真需要它：绕开 HostApi 自己搞了外部资源（起了线程、开了文件、
/// 注册了系统信号）的那些 —— 宿主不知道这些，只能由插件自己收尾。
pub export fn dsh_plugin_deinit() callconv(.c) void {
    @panic("TODO: 阶段 1 —— 打印 'deinit'，用于确认卸载时序");
}
