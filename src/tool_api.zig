//! 工具的跨边界形状：宿主与工具插件共享的类型定义。
//!
//! 为什么单独成模块：这些结构要在**两个编译单元**里逐字节一致（宿主编进
//! `dsh_zig`，工具编进 `libtools.so`）。两份手写的定义迟早漂移，而漂移的表现
//! 不是编译错误，是运行时读到垃圾 —— 所以只留一份，双方 import 它。
//!
//! 与 dsh_abi 的分工：dsh_abi 放**每个插件都要用**的通用契约（Handle /
//! Status / HostApi）；这里放「工具」这个具体能力的接口形状。
//!
//! 由 build.zig 注册成模块 `dsh_tools`。

const std = @import("std");
const abi = @import("dsh_abi");

/// 结果缓冲区：**谁调用谁分配**，工具只负责往里写。
///
/// 为什么不让工具返回自己分配的内存：插件卸载时它的 arena 整体清空，宿主
/// 手里那块当场悬空。所以所有权从一开始就必须在调用方手里。
pub const Buffer = extern struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,
    cap: usize = 0,

    pub fn slice(self: *const Buffer) []const u8 {
        const p = self.ptr orelse return &.{};
        return p[0..self.len];
    }

    /// 一个「写满即停」的 writer。写完后用 finish 记录长度。
    pub fn writer(self: *Buffer) std.Io.Writer {
        const p = self.ptr orelse return .fixed(&.{});
        return .fixed(p[0..self.cap]);
    }

    pub fn finish(self: *Buffer, w: *std.Io.Writer) void {
        self.len = w.buffered().len;
    }
};

/// 工具的对外描述。`parameters_json` 是 JSON Schema 文本，直接塞进请求体的
/// `tools[].function.parameters` —— 所以字段名必须与 schema 里写的完全一致。
pub const ToolSpec = extern struct {
    name: [*:0]const u8,
    description: [*:0]const u8,
    parameters_json: [*:0]const u8,
};

/// 工具执行入口。**形状与跨 C ABI 调用时完全一致**，不要改成 Zig 风格：
/// 参数是 JSON 文本、结果写进 out、失败用 Status 表达，绝不跨边界抛 error。
pub const ToolExecuteFn = *const fn (
    impl: *anyopaque,
    args_json: [*:0]const u8,
    out: *Buffer,
) callconv(.c) abi.Status;

/// 宿主眼里的「一个工具」：描述 + 执行入口。
pub const Tool = struct {
    spec: ToolSpec,
    exec: ToolExecuteFn,
};

/// 「工具表」服务接口。
///
/// 由**提供工具的那个插件**注册成服务；宿主（agent loop）通过服务表拿到它
/// 之后就能列工具、执行工具 —— 宿主编译期完全不需要认识这些工具，这正是
/// 「工具可以在运行时被换掉」的全部意义。
///
/// ★ 接口约定：**第一个字段必须是 impl**（提供者实例）。
///   因为 get_service 只能带回来一个指针，而调用方法同时需要「接口表」和
///   「实例」两样东西。把实例放进接口表第一个字段，消费方一句 `iface.impl`
///   就拿全了 —— 这也是 C 里 vtable + self 的惯用形状。
///   每个服务接口都按这个形状定义，消费方就不需要关心「怎么配到 impl」。
///
/// 这里**没有** `register`：现在工具表就等于那个插件自己的静态表。等真出现
/// 「多个插件各自往同一张表里加工具」的需求，再把表改成宿主提供的基础设施
/// （那时 register 才有调用方）。不为想象中的调用方预先设计。
pub const ToolsIface = extern struct {
    /// 提供者实例。注册时由提供者填入，调用各方法时原样传回。
    impl: *anyopaque,

    /// 表里有几个工具。
    count: *const fn (impl: *anyopaque) callconv(.c) usize,

    /// 第 index 个工具的描述；越界返回 null。
    ///
    /// ⚠️ 返回的指针指向**插件里的静态数据**，生命周期与插件一致。宿主不得
    ///    长期持有它（卸载之后就是悬空指针），只能当场用完就丢。
    at: *const fn (impl: *anyopaque, index: usize) callconv(.c) ?*const ToolSpec,

    /// 按名字执行。out 由宿主提供 —— 结果宿主之后还要用，所以那块内存不能
    /// 由插件持有（见 Buffer 的说明）。
    execute: *const fn (
        impl: *anyopaque,
        name: [*:0]const u8,
        args_json: [*:0]const u8,
        out: *Buffer,
    ) callconv(.c) abi.Status,
};

/// 服务名常量（拼错名字是最难查的一类 bug，统一放这里）。
pub const SERVICE_NAME = "tools";

// ───────────────────────────────────────────────────────────────────────────
//  四个内建工具的对外描述
//
//  放在共享模块里而不是宿主与插件各写一份：description 与 JSON Schema 都是
//  长文本，两边漂移了很难看出来（模型看到的行为会不一样），而编译器不会提示。
// ───────────────────────────────────────────────────────────────────────────

pub const read_spec = ToolSpec{
    .name = "read",
    .description = "Read a file. Output is line-numbered as `<n>\t<text>`.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File path, relative to the working directory"},"offset":{"type":"integer","description":"1-based line number to start from"},"limit":{"type":"integer","description":"Max number of lines to return"}},"required":["path"]}
    ,
};

pub const write_spec = ToolSpec{
    .name = "write",
    .description = "Write a file, overwriting it if it exists.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File path"},"content":{"type":"string","description":"Full file content"}},"required":["path","content"]}
    ,
};

pub const edit_spec = ToolSpec{
    .name = "edit",
    .description = "Replace the first occurrence of oldText with newText. oldText must appear exactly once, otherwise the edit is refused.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File path"},"oldText":{"type":"string","description":"Exact text to replace; must occur exactly once"},"newText":{"type":"string","description":"Replacement text"}},"required":["path","oldText","newText"]}
    ,
};

pub const bash_spec = ToolSpec{
    .name = "bash",
    .description = "Run a shell command with `bash -lc`, returning its stdout/stderr and exit code.",
    .parameters_json =
    \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command"},"timeoutSeconds":{"type":"integer","description":"Kill the command after this many seconds"}},"required":["command"]}
    ,
};

/// 内建工具表（顺序就是喂给模型的顺序）。
pub const builtin_specs = [_]ToolSpec{ read_spec, write_spec, edit_spec, bash_spec };
