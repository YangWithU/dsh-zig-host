//! ═══════════════════════════════════════════════════════════════════════════
//!  工具插件 · read / write / edit / bash —— 跑在 .so 里
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 这是「工具搬家」的落点：同一套工具，从编在宿主里变成运行时加载的插件。
//! 宿主侧因此可以完全不知道存在哪些工具 —— 它按名字去服务表要 `tools`，
//! 列出来、按名字执行，剩下的插件自己管。
//!
//! 数据流
//! ---------------------------------------------------------------------------
//!   init:  校验 ABI -> 注册服务 "tools"（iface + impl 都是本插件的静态数据）
//!   运行:  宿主 get_service("tools") -> count/at 拿描述生成请求体
//!                             -> execute(name, args_json, out) 执行
//!   卸载:  宿主的撤销清单把服务摘掉 -> dlclose -> 本插件的内存整体回收
//!
//! ★ 与宿主内那份实现（src/agent/tools.zig）的关键差别
//! ---------------------------------------------------------------------------
//!   那份直接调 `host.dir.readFileAlloc` / `std.process.run`；
//!   这里**只能**经由 `api.read_file` / `api.write_file` / `api.run_shell`。
//!   插件是被加载进来的陌生代码，它没有资格自己碰文件系统与进程 ——
//!   能力由宿主授予，所以这一整个文件里不出现 std.fs / std.process。
//!
//! 不变量
//! ---------------------------------------------------------------------------
//!   ① 绝不 panic、绝不把 Zig error 抛出去：一律转成 abi.Status，失败原因写进 out
//!      （模型看不到 Status，只能看到 out 里的文字）。
//!   ② 内存只能从 `api.alloc` 出（即本插件自己的 arena）—— 所以不需要 free，
//!      卸载时宿主整体回收。
//!   ③ 返回给宿主的指针（ToolSpec）指本插件的静态数据，卸载即失效；
//!      宿主不得长期持有。
//!
//! 已知的过渡状态
//! ---------------------------------------------------------------------------
//!   四个工具的「实现」此刻在仓库里有两份（宿主内一份、这里一份），因为 agent
//!   loop 还在用宿主内那份。跨边界的**形状**与**描述文本**只有一份（src/tool_api.zig），
//!   所以不会漂移。等 loop 改成从服务表取工具，宿主内那份实现就可以删掉。

const std = @import("std");
const abi = @import("dsh_abi");
const tool_api = @import("dsh_tools");

const Buffer = tool_api.Buffer;
const ToolSpec = tool_api.ToolSpec;
const ToolExecuteFn = tool_api.ToolExecuteFn;

// ───────────────────────────────────────────────────────────────────────────
//  插件侧的 Host：能力全部来自宿主，内存只能从宿主给的 arena 出
// ───────────────────────────────────────────────────────────────────────────

/// 把 `api.alloc` 包成标准 Allocator。
///
/// 为什么需要它：插件**没有自己的堆** —— 内存必须从宿主划给它的那块 arena 出
/// （这样卸载时整体回收，插件不可能漏）。但 std.json 的解析、std.mem.concat
/// 这些现成工具都要一个 `std.mem.Allocator`，所以包一层给它。
///
/// free 是空操作：arena 的内存不单独还，随卸载整块回收。
const HostAllocator = struct {
    api: *const abi.HostApi,

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *HostAllocator = @ptrCast(@alignCast(ctx));
        const p = self.api.alloc(self.api.ctx, len, @intCast(alignment.toByteUnits())) orelse
            return null;
        return @ptrCast(p);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false; // arena 不支持原地伸缩
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null; // 让调用方走「分配新的 + 拷贝」
    }

    fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {
        // 空操作：内存随 arena 整体回收
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *HostAllocator) std.mem.Allocator {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

const Host = struct {
    api: *const abi.HostApi,
    /// 从宿主 arena 切的分配器
    gpa: std.mem.Allocator,
    /// bash 的默认超时（秒）
    bash_timeout_s: u32 = 60,
};

/// 一个 .so 被加载一次，所以这些是单实例的。
/// （将来若要一个 .so 支持多实例，把它们塞进 init 里分配的结构体即可。）
var g_alloc: HostAllocator = .{ .api = undefined };
var g_host: Host = undefined;

// ───────────────────────────────────────────────────────────────────────────
//  小工具：失败一律写进 out（模型只看得到 out）
// ───────────────────────────────────────────────────────────────────────────

fn failAs(st: abi.Status, out: *Buffer, msg: []const u8) abi.Status {
    var w = out.writer();
    w.writeAll(msg) catch {};
    out.finish(&w);
    return st;
}

fn failFmtAs(st: abi.Status, out: *Buffer, comptime fmt: []const u8, args: anytype) abi.Status {
    var w = out.writer();
    w.print(fmt, args) catch {};
    out.finish(&w);
    return st;
}

fn fail(out: *Buffer, msg: []const u8) abi.Status {
    return failAs(.err_invalid_arg, out, msg);
}

fn failFmt(out: *Buffer, comptime fmt: []const u8, args: anytype) abi.Status {
    return failFmtAs(.err_invalid_arg, out, fmt, args);
}

fn okFmt(out: *Buffer, comptime fmt: []const u8, args: anytype) abi.Status {
    var w = out.writer();
    w.print(fmt, args) catch {};
    out.finish(&w);
    return .ok;
}

/// 把不带结尾 0 的 slice 复制成 C 字符串。
/// 跨 ABI 的路径/命令参数要求 `[*:0]const u8`，而 JSON 解析出来的字符串没有
/// 结尾 0，所以必须复制一份（内存从本插件的 arena 出，随卸载回收）。
fn cstr(a: std.mem.Allocator, s: []const u8) ![*:0]const u8 {
    const buf = try a.allocSentinel(u8, s.len, 0);
    @memcpy(buf, s);
    return buf.ptr;
}

fn oomOrInternal(out: *Buffer, e: anyerror) abi.Status {
    _ = failFmt(out, "工具内部错误：{s}", .{@errorName(e)});
    return if (e == error.OutOfMemory) .err_oom else .err_internal;
}

fn hostFrom(impl: *anyopaque) *Host {
    return @ptrCast(@alignCast(impl));
}

// ───────────────────────────────────────────────────────────────────────────
//  四个工具的 C ABI 入口
// ───────────────────────────────────────────────────────────────────────────

fn toolRead(impl: *anyopaque, args_json: [*:0]const u8, out: *Buffer) callconv(.c) abi.Status {
    return doRead(hostFrom(impl), std.mem.span(args_json), out) catch |e| oomOrInternal(out, e);
}

fn toolWrite(impl: *anyopaque, args_json: [*:0]const u8, out: *Buffer) callconv(.c) abi.Status {
    return doWrite(hostFrom(impl), std.mem.span(args_json), out) catch |e| oomOrInternal(out, e);
}

fn toolEdit(impl: *anyopaque, args_json: [*:0]const u8, out: *Buffer) callconv(.c) abi.Status {
    return doEdit(hostFrom(impl), std.mem.span(args_json), out) catch |e| oomOrInternal(out, e);
}

fn toolBash(impl: *anyopaque, args_json: [*:0]const u8, out: *Buffer) callconv(.c) abi.Status {
    return doBash(hostFrom(impl), std.mem.span(args_json), out) catch |e| oomOrInternal(out, e);
}

const specs = tool_api.builtin_specs;
const execs = [_]ToolExecuteFn{ toolRead, toolWrite, toolEdit, toolBash };

// ───────────────────────────────────────────────────────────────────────────
//  read
// ───────────────────────────────────────────────────────────────────────────

fn doRead(h: *Host, args_json: []const u8, out: *Buffer) !abi.Status {
    const Args = struct {
        path: []const u8,
        offset: ?u64 = null,
        limit: ?u64 = null,
    };
    const parsed = std.json.parseFromSlice(Args, h.gpa, args_json, .{ .ignore_unknown_fields = true }) catch
        return fail(out, "read: 参数必须是 {\"path\": \"...\", \"offset\"?, \"limit\"?}");
    const a = parsed.value;

    const path_z = try cstr(h.gpa, a.path);
    var bytes: abi.Bytes = .{};
    const st = h.api.read_file(h.api.ctx, path_z, &bytes);
    if (st != .ok) {
        return failFmtAs(st, out, "read: 打开 {s} 失败（{s}）", .{ a.path, @tagName(st) });
    }
    const data = bytes.slice();

    const first: usize = if (a.offset) |o| @intCast(o -| 1) else 0;
    const max_lines: usize = if (a.limit) |l| @intCast(l) else std.math.maxInt(usize);

    // 给尾部「还有多少行没显示」的提示留空间。宁可少显示几行，也不能写爆
    // 缓冲区 —— 写爆就变成静默截断，模型会以为读完了。
    const reserve: usize = 160;
    const budget: usize = if (out.cap > reserve) out.cap - reserve else out.cap;

    // 总行数：与 splitScalar 的迭代次数一致（末尾换行会多出一个空行，
    // count('\n') + 1 恰好对上），用来告诉模型到底还剩多少行。
    const total_lines = std.mem.count(u8, data, "\n") + 1;

    var w = out.writer();
    var emitted: usize = 0;
    var line_no: usize = 0;
    var last_shown: usize = 0;
    var truncated = false;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        line_no += 1;
        if (line_no <= first) continue;
        if (emitted >= max_lines) {
            truncated = true;
            break;
        }
        if (w.buffered().len + line.len + 12 > budget) {
            truncated = true;
            break;
        }
        w.print("{d}\t{s}\n", .{ line_no, line }) catch {
            truncated = true;
            break;
        };
        emitted += 1;
        last_shown = line_no;
    }

    if (emitted == 0) {
        out.finish(&w);
        return failFmt(out, "read: {s} 只有 {d} 行，offset={d} 越界", .{ a.path, line_no, first + 1 });
    }
    if (truncated) {
        w.print("\n[截断] 共 {d} 行，已显示到第 {d} 行，还有 {d} 行；用 offset={d} 继续读\n", .{
            total_lines, last_shown, total_lines - last_shown, last_shown + 1,
        }) catch {};
    }
    out.finish(&w);
    return .ok;
}

// ───────────────────────────────────────────────────────────────────────────
//  write
// ───────────────────────────────────────────────────────────────────────────

fn doWrite(h: *Host, args_json: []const u8, out: *Buffer) !abi.Status {
    const Args = struct {
        path: []const u8,
        content: []const u8,
    };
    const parsed = std.json.parseFromSlice(Args, h.gpa, args_json, .{ .ignore_unknown_fields = true }) catch
        return fail(out, "write: 参数必须是 {\"path\": \"...\", \"content\": \"...\"}");
    const a = parsed.value;

    const path_z = try cstr(h.gpa, a.path);
    const st = h.api.write_file(h.api.ctx, path_z, a.content.ptr, a.content.len);
    if (st != .ok) {
        return failFmtAs(.err_internal, out, "write: 写入 {s} 失败（{s}）", .{ a.path, @tagName(st) });
    }
    return okFmt(out, "已写入 {s}（{d} 字节）", .{ a.path, a.content.len });
}

// ───────────────────────────────────────────────────────────────────────────
//  edit
// ───────────────────────────────────────────────────────────────────────────

fn doEdit(h: *Host, args_json: []const u8, out: *Buffer) !abi.Status {
    const Args = struct {
        path: []const u8,
        oldText: []const u8,
        newText: []const u8,
    };
    const parsed = std.json.parseFromSlice(Args, h.gpa, args_json, .{ .ignore_unknown_fields = true }) catch
        return fail(out, "edit: 参数必须是 {\"path\": \"...\", \"oldText\": \"...\", \"newText\": \"...\"}");
    const a = parsed.value;

    if (a.oldText.len == 0) return fail(out, "edit: oldText 不能为空（空串会匹配任意位置）");

    const path_z = try cstr(h.gpa, a.path);
    var bytes: abi.Bytes = .{};
    const st = h.api.read_file(h.api.ctx, path_z, &bytes);
    if (st != .ok) {
        return failFmtAs(st, out, "edit: 打开 {s} 失败（{s}）", .{ a.path, @tagName(st) });
    }
    const data = bytes.slice();

    const idx = std.mem.indexOf(u8, data, a.oldText) orelse
        return failFmt(out, "edit: 在 {s} 里找不到 oldText（注意缩进与空白必须逐字一致）", .{a.path});

    // 唯一性检查：出现两次就拒绝，让模型补更多上下文再来。
    // 悄悄改掉第一处会让人以为改的是另一处，是最难查的一类事故 —— 宁可不猜。
    if (std.mem.indexOfPos(u8, data, idx + a.oldText.len, a.oldText) != null) {
        return failFmt(out, "edit: oldText 在 {s} 里出现多次，请把上下文写长一些以唯一定位", .{a.path});
    }

    const replaced = try std.mem.concat(h.gpa, u8, &.{
        data[0..idx],
        a.newText,
        data[idx + a.oldText.len ..],
    });

    const st2 = h.api.write_file(h.api.ctx, path_z, replaced.ptr, replaced.len);
    if (st2 != .ok) {
        return failFmtAs(.err_internal, out, "edit: 写回 {s} 失败（{s}）", .{ a.path, @tagName(st2) });
    }
    return okFmt(out, "已修改 {s}：第 {d} 字节起，{d} 字节 → {d} 字节", .{
        a.path, idx, a.oldText.len, a.newText.len,
    });
}

// ───────────────────────────────────────────────────────────────────────────
//  bash
// ───────────────────────────────────────────────────────────────────────────

fn doBash(h: *Host, args_json: []const u8, out: *Buffer) !abi.Status {
    const Args = struct {
        command: []const u8,
        timeoutSeconds: ?i64 = null,
    };
    const parsed = std.json.parseFromSlice(Args, h.gpa, args_json, .{ .ignore_unknown_fields = true }) catch
        return fail(out, "bash: 参数必须是 {\"command\": \"...\", \"timeoutSeconds\"?}");
    const a = parsed.value;

    const raw_timeout = a.timeoutSeconds orelse h.bash_timeout_s;
    if (raw_timeout <= 0) return fail(out, "bash: timeoutSeconds 必须大于 0");
    const timeout_s: u32 = @intCast(raw_timeout);

    const cmd_z = try cstr(h.gpa, a.command);
    var res: abi.ShellResult = .{};
    const st = h.api.run_shell(h.api.ctx, cmd_z, timeout_s, &res);
    if (st != .ok) {
        // 这里才是真失败：命令根本没跑起来，或者超时被杀
        return failFmtAs(.err_internal, out, "bash: 执行失败（{s}）：{s}", .{ @tagName(st), a.command });
    }

    // 尾部提示也要占地方，同样给缓冲区留余量
    const reserve: usize = 400;
    const budget: usize = if (out.cap > reserve) out.cap - reserve else out.cap;

    var w = out.writer();
    switch (res.term) {
        .exited => |code| w.print("[exit {d}]\n", .{code}) catch {},
        .signal => |sig| w.print("[signal {d}]\n", .{sig}) catch {},
        .other => w.writeAll("[terminated]\n") catch {},
    }

    const so = res.stdout();
    const se = res.stderr();

    // 优先保 stdout（多数命令的有用信息在那里）；装不下就截断并明说，
    // 绝不让模型以为它看到了完整输出。
    var truncated = false;
    if (so.len <= budget) {
        w.writeAll(so) catch {};
    } else {
        w.writeAll(so[0..budget]) catch {};
        truncated = true;
    }
    if (!truncated and se.len > 0) {
        const left = budget -| w.buffered().len;
        if (se.len + 10 > left) {
            w.writeAll("\n[stderr]\n") catch {};
            w.writeAll(se[0..(left -| 10)]) catch {};
            truncated = true;
        } else {
            w.writeAll("\n[stderr]\n") catch {};
            w.writeAll(se) catch {};
        }
    }
    if (truncated) {
        w.print("\n[截断] stdout {d} 字节 / stderr {d} 字节，请用 head、grep、--max-count 等收窄\n", .{
            so.len, se.len,
        }) catch {};
    }
    out.finish(&w);

    // 命令以非 0 退出**不算工具失败** —— 模型需要看到错误输出来自己纠正。
    return .ok;
}

// ───────────────────────────────────────────────────────────────────────────
//  服务接口实现：把工具表交给宿主
// ───────────────────────────────────────────────────────────────────────────

fn ifaceCount(impl: *anyopaque) callconv(.c) usize {
    _ = impl;
    return specs.len;
}

fn ifaceAt(impl: *anyopaque, index: usize) callconv(.c) ?*const ToolSpec {
    _ = impl;
    if (index >= specs.len) return null;
    return &specs[index];
}

fn ifaceExecute(
    impl: *anyopaque,
    name: [*:0]const u8,
    args_json: [*:0]const u8,
    out: *Buffer,
) callconv(.c) abi.Status {
    const wanted = std.mem.span(name);
    for (specs, 0..) |spec, i| {
        if (!std.mem.eql(u8, std.mem.span(spec.name), wanted)) continue;
        return execs[i](impl, args_json, out);
    }
    // 未知工具不是崩溃，是把「没有这个工具」如实告诉调用方
    return failFmt(out, "未知工具：{s}", .{wanted});
}

/// 接口表。`impl` 字段（第一个）就是 g_host 的地址，在 init 里填。
/// 做成 var 而不是 const：impl 字段要在运行时才知道（虽然它其实就是个静态地址，
/// 但用运行时赋值免去 comptime 指针转换的麻烦，也更好读）。
var iface: tool_api.ToolsIface = .{
    .impl = undefined,
    .count = ifaceCount,
    .at = ifaceAt,
    .execute = ifaceExecute,
};

// ───────────────────────────────────────────────────────────────────────────
//  插件入口
// ───────────────────────────────────────────────────────────────────────────

pub export fn dsh_plugin_abi_version() callconv(.c) u32 {
    return abi.ABI_VERSION;
}

pub export fn dsh_plugin_init(
    api: *const abi.HostApi,
    config_json: [*:0]const u8,
) callconv(.c) abi.Status {
    _ = config_json; // 这个插件没有配置项

    const st = api.check();
    if (st != .ok) return st;

    g_alloc.api = api;
    g_host = .{ .api = api, .gpa = g_alloc.allocator() };
    iface.impl = @ptrCast(&g_host);

    const h = api.register_service(
        api.ctx,
        tool_api.SERVICE_NAME,
        @ptrCast(&iface),
        @ptrCast(&g_host),
        0,
    );
    if (h.id == 0) return .err_duplicate;

    api.log(api.ctx, .info, "tools 插件已就绪（4 个工具）");
    return .ok;
}

pub export fn dsh_plugin_deinit() callconv(.c) void {}
