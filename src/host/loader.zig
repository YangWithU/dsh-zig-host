//! ═══════════════════════════════════════════════════════════════════════════
//!  阶段 1 · Loader —— 装卸一个 .so
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 职责: 把「磁盘上的一个 .so」变成「几个可调用的函数指针」，以及反向的关闭。
//! 不做: 状态机（那是 fiber 的事）、服务注册（那是 context 的事）。
//!
//! 开打的顺序就是筛选的顺序：先看 ABI 版本，版本不对立刻返回，**绝不进 init**。
//! 理由: 版本不匹配时两侧的类型布局可能已经不同（同一个 Handle 结构体，
//! 一边 u32 一边 u64 之类），此时调用插件代码不会报错 —— 只会崩。必须先挡。
//!
//! 任一步失败都关掉已打开的句柄再返回错误，不留半个打开的库。

const std = @import("std");
const abi = @import("dsh_abi");

pub const LoadError = error{
    /// .so 里没有 dsh_plugin_abi_version（不像是个插件）
    MissingAbiVersion,
    /// 版本对不上：宿主与插件编译自不同的 ABI
    AbiMismatch,
    /// 没有 init 符号
    MissingInit,
};

/// 一次成功的打开：句柄 + 找到的符号。
pub const Loaded = struct {
    lib: std.DynLib,
    init: abi.PluginInitFn,
    /// 可选导出：插件主动收尾用的。宿主**不得依赖**它做清理
    /// （清理的正确性由撤销清单保证，这个钩子只是让插件有机会收自己的尾）。
    deinit: ?abi.PluginDeinitFn = null,
};

/// dlopen → 校验 ABI 版本 → 取符号。
pub fn open(path: []const u8) !Loaded {
    var lib = try std.DynLib.open(path);
    errdefer lib.close();

    const version_fn = lib.lookup(abi.PluginAbiVersionFn, abi.SYM_ABI_VERSION) orelse
        return LoadError.MissingAbiVersion;
    if (version_fn() != abi.ABI_VERSION) return LoadError.AbiMismatch;

    const init = lib.lookup(abi.PluginInitFn, abi.SYM_INIT) orelse return LoadError.MissingInit;
    const deinit = lib.lookup(abi.PluginDeinitFn, abi.SYM_DEINIT);

    return .{ .lib = lib, .init = init, .deinit = deinit };
}

/// 关掉句柄。**调用者必须已经撤销完全部注册**（顺序铁律，见 fiber.unload）。
pub fn close(l: *Loaded) void {
    l.lib.close();
}

/// 从路径猜一个诊断用的名字："a/b/libhello.so" -> "hello"。
/// 只用于日志和错误信息，解析不出就返回整个 basename。
pub fn nameFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.startsWith(u8, base, "lib")) {
        if (std.mem.indexOf(u8, base, ".")) |dot| return base[3..dot];
        return base[3..];
    }
    return base;
}

// ───────────────────────────────────────────────────────────────────────────
//  测试
// ───────────────────────────────────────────────────────────────────────────

test "nameFromPath: 从 .so 路径推名字" {
    try std.testing.expectEqualStrings("hello", nameFromPath("zig-out/lib/libhello.so"));
    try std.testing.expectEqualStrings("hello", nameFromPath("libhello.so"));
    try std.testing.expectEqualStrings("hello", nameFromPath("/abs/path/libhello.so"));
    // 不以 lib 开头时原样返回 basename
    try std.testing.expectEqualStrings("weird.so", nameFromPath("weird.so"));
}

test "open: 文件不存在 -> 报错且不留打开的句柄" {
    // 用 testing.allocator：若有资源泄漏（句柄对应的内部分配）它会报出来
    const r = open("zig-out/lib/libdefinitely-not-here.so");
    try std.testing.expectError(error.FileNotFound, r);
}

test "open: 存在但不是动态库 -> 报错且不留句柄" {
    // build.zig 是纯文本，dlopen 会失败
    const r = open("build.zig");
    try std.testing.expect(r == error.FileNotFound or r == error.InvalidFile or r == error.NotDir);
}
