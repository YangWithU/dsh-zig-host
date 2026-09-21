//! ═══════════════════════════════════════════════════════════════════════════
//!  阶段 5 · Tools —— 四个工具的「服务接口 + 实现」      【草图 / 空壳】
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 这个文件同时演示两件事：
//!   (a) 一个**服务接口**怎么定义（ToolsIface 的 extern struct）
//!   (b) 四个工具（read / write / edit / bash）怎么挂上去
//!
//! ★ 服务接口的约定（整个项目最重要的模式）
//! ---------------------------------------------------------------------------
//!   每个服务定义一个 `extern struct`，字段全是 `callconv(.c)` 函数指针，
//!   第一个参数固定是提供者的实例指针（`*anyopaque`）。
//!
//!       服务定义方  ─┐
//!                    ├─ 共享同一个 zig 文件 → 双方编译期检查签名
//!       服务消费方  ─┘
//!
//!   运行时只传 `*const anyopaque`，消费方 cast 回去用：
//!       const raw = ctx.getService("tools") orelse return;
//!       const tools: *const ToolsIface = @ptrCast(@alignCast(raw));
//!
//!   这就是 Cordis `ctx.tools` 的 Zig 版：类型安全在编译期由共享定义保证，
//!   运行期只做一次指针转换。
//!
//! ⚠️ 空壳。

const std = @import("std");
const abi = @import("dsh_abi");

// ───────────────────────────────────────────────────────────────────────────
//  跨 ABI 的通用数据结构
// ───────────────────────────────────────────────────────────────────────────

/// 一段可写缓冲区，用于把「结果字符串」跨边界带回来。
///
/// 为什么不直接返回 slice：Zig 的 slice 是 (ptr, len) 两字段，跨编译单元
/// 传递本身没问题，但配上 error union / 所有权语义就危险了。用这个结构
/// 明确「谁分配、多大、能写多少」。
pub const Buffer = extern struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,
    cap: usize = 0,

    pub fn asSlice(self: *const Buffer) []const u8 {
        _ = self;
        @panic("TODO: 空缓冲区要返回空 slice");
    }
};

/// 工具的描述（要喂给模型的 JSON Schema 也在这里）。
pub const ToolSpec = extern struct {
    name: [*:0]const u8,
    description: [*:0]const u8,
    /// JSON Schema 文本，直接进请求体的 tools[].input_schema
    parameters_json: [*:0]const u8,
};

/// 工具的调用入口。
///
/// `args_json` 是模型给的参数（JSON 文本）
/// `out`      是宿主提供的输出缓冲区，工具往里写结果
/// 返回 abi.Status；**绝不允许 panic 穿出去**（工具是最容易出错的地方）
pub const ToolExecuteFn = *const fn (
    impl: *anyopaque,
    args_json: [*:0]const u8,
    out: *Buffer,
) callconv(.c) abi.Status;

/// 「工具注册表」服务接口 —— 别的插件通过它加工具。
///
/// 对应 dsh 里的 `ctx.tools`（packages/core/tools）。
pub const ToolsIface = extern struct {
    /// 注册一个工具。返回句柄供撤销（工具注册也是可逆的！）
    register: *const fn (impl: *anyopaque, spec: *const ToolSpec, exec: ToolExecuteFn) callconv(.c) abi.Handle,

    /// 按名字找一个工具（agent loop 解析出 tool_call 后用它派发）
    find: *const fn (impl: *anyopaque, name: [*:0]const u8, exec_out: **const ToolExecuteFn, tool_out: **const anyopaque) callconv(.c) abi.Status,

    /// 列举全部工具（组装请求体时要给模型看）
    count: *const fn (impl: *anyopaque) callconv(.c) usize,
    at: *const fn (impl: *anyopaque, index: usize, spec_out: **const ToolSpec) callconv(.c) abi.Status,
};

/// 服务名常量（拼错名字是最难查的 bug，统一放这里）。
pub const SERVICE_NAME = "tools";

// ───────────────────────────────────────────────────────────────────────────
//  四个工具
//
//  实现要点（草图，暂不实现）：
//    · 全部走宿主的 arena 分配输出缓冲区
//    · bash 用 std.process.Child（注意 0.16 的 API 要传 io）
//    · edit 要做「精确文本替换」，找不到匹配必须报错而不是猜
//    · 所有路径要做沙箱前缀校验（dsh 里有专门的 sandbox seam）
// ───────────────────────────────────────────────────────────────────────────

/// read：读文件。参数 { path, offset?, limit? }
pub fn toolRead(impl: *anyopaque, args_json: [*:0]const u8, out: *Buffer) callconv(.c) abi.Status {
    _ = impl;
    _ = args_json;
    _ = out;
    @panic("TODO: 阶段 5 —— 解析参数 → 读文件 → 写入 out（超限时截断并标注）");
}

/// write：写文件。参数 { path, content }
/// 注意：应当默认创建父目录、支持覆盖，并回报写入字节数。
pub fn toolWrite(impl: *anyopaque, args_json: [*:0]const u8, out: *Buffer) callconv(.c) abi.Status {
    _ = impl;
    _ = args_json;
    _ = out;
    @panic("TODO: 阶段 5 —— 解析参数 → 建父目录 → 写文件 → 回报字节数");
}

/// edit：精确文本替换。参数 { path, old_string, new_string, replace_all? }
///
/// ★ 设计决策：**必须精确匹配，找不到就报错**。
///   这是 dsh 里 edit 工具的硬规则：「不猜」。模糊匹配会让模型以为改成功了，
///   实际改错地方，比直接失败危险得多。
pub fn toolEdit(impl: *anyopaque, args_json: [*:0]const u8, out: *Buffer) callconv(.c) abi.Status {
    _ = impl;
    _ = args_json;
    _ = out;
    @panic("TODO: 阶段 5 —— 读原文件 → 精确匹配 old_string（唯一性或 replace_all）→ 替换 → 写回");
}

/// bash：执行命令。参数 { command, timeout_ms? }
///
/// 实现要点：
///   · std.process.Child（0.16 的 wait/kill 都要传 io）
///   · 必须捕获 stdout+stderr 并带超时；超时要真的杀掉进程组
///   · 输出要截断（否则一次 `find /` 就把上下文撑爆）
pub fn toolBash(impl: *anyopaque, args_json: [*:0]const u8, out: *Buffer, io: std.Io) callconv(.c) abi.Status {
    _ = impl;
    _ = args_json;
    _ = out;
    _ = io;
    @panic("TODO: 阶段 5 —— spawn → 收集输出 → 超时杀进程 → 截断 → 写 out");
}

// ───────────────────────────────────────────────────────────────────────────
//  内建工具插件：把上面四个工具注册进 ctx.tools
//
//  它本身就是「一个插件」，所以它自己也要遵守契约：
//      init 里注册 4 个工具；卸载时 4 个注册全部被逆序撤销。
// ───────────────────────────────────────────────────────────────────────────

/// 工具表的静态描述（init 时批量注册）。
pub const builtin_specs = [_]ToolSpec{
    .{ .name = "read", .description = "读取文件内容", .parameters_json = "{}" },
    .{ .name = "write", .description = "写入文件", .parameters_json = "{}" },
    .{ .name = "edit", .description = "精确文本替换", .parameters_json = "{}" },
    .{ .name = "bash", .description = "执行 shell 命令", .parameters_json = "{}" },
};

/// 插件入口（对应 abi.PluginInitFn 的签名）。
///
/// 流程：校验 ABI → 取 tools 服务 → 逐个 register。
/// 任何一步失败都要返回 Status，且**已经注册的要撤销掉**。
pub export fn dsh_plugin_init(api: *const abi.HostApi, config_json: [*:0]const u8) callconv(.c) abi.Status {
    _ = api;
    _ = config_json;
    @panic("TODO: 阶段 5 —— 校验 ABI → getService(tools) → 注册 4 个工具");
}

pub export fn dsh_plugin_abi_version() callconv(.c) u32 {
    @panic("TODO: 阶段 5 —— 返回 abi.ABI_VERSION");
}
