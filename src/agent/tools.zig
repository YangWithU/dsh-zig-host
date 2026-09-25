//! ═══════════════════════════════════════════════════════════════════════════
//!  MVP · 工具四件套 read / write / edit / bash          【实装，非空壳】
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 职责: 给 agent loop 提供四个工具；只认「名字 + JSON 参数 → 一段文本」。
//! 数据流: loop 从模型响应里取出 tool_calls → 按名字查表 → 把 arguments（JSON
//!         文本）交给本模块执行 → 结果写进调用方提供的 Buffer。
//! 不变量: ① 绝不 panic、绝不把 Zig error 抛出边界，一律转成 abi.Status；
//!         ② 结果（含失败原因）一律写进 out 指向的缓冲区，本模块不把内部内存
//!            借给外面 —— 将来本模块搬进 .so 后，arena 会被整体清空；
//!         ③ 一切外部能力（读文件/写文件/起进程）都经由 Host 窄接口取得，
//!            工具实现里不许直接出现 std.fs / std.process 的调用点。
//! 不可简化: 参数不能改成 Zig 结构体直接传（将来跨 C ABI 只能传字符串），
//!           结果也不能由工具自己持有（见不变量②）。破坏任一条，搬进插件即返工。
//!
//! 与 src/plugins/tools.zig 的关系: 那份是「插件版」（含 ToolsIface 服务表），
//! 本文件是「MVP 版」（工具直接编进宿主、放在一个数组里）。ToolSpec /
//! ToolExecuteFn / Buffer 的形状必须一致；阶段 5 做插件时以本文件为唯一定义源，
//! plugins/tools.zig 改为 import 这里，不要再抄一份（两份定义 = 两份真相）。
//!
//! 注意：本模块被设计成「将来会被整体搬进 .so」，所以它对外只依赖 Host 这个
//!       窄接口 + 一个调用方给的缓冲区，不依赖任何宿主内部类型。

const std = @import("std");
const abi = @import("dsh_abi");

// ───────────────────────────────────────────────────────────────────────────
//  跨边界的数据形状（将来搬进 .so 后原样可用）
// ───────────────────────────────────────────────────────────────────────────

/// 结果缓冲区：**谁调用谁分配**，工具只负责往里写。
///
/// 为什么不让工具返回自己分配的内存：插件卸载时 arena 整体清空，宿主手里
/// 那块当场悬空。所以所有权必须从一开始就在调用方。
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

/// 工具执行入口。**形状与将来跨 C ABI 调用时完全一致**，不要改成 Zig 风格：
/// 参数是 JSON 文本、结果写进 out、失败用 Status 表达，绝不跨边界抛 error。
pub const ToolExecuteFn = *const fn (
    impl: *anyopaque,
    args_json: [*:0]const u8,
    out: *Buffer,
) callconv(.c) abi.Status;

pub const Tool = struct {
    spec: ToolSpec,
    exec: ToolExecuteFn,
};

// ───────────────────────────────────────────────────────────────────────────
//  Host：工具能用到的全部外部能力（窄接口）
// ───────────────────────────────────────────────────────────────────────────

/// 工具与外界之间的**唯一**通道。MVP 阶段由 main 直接构造；阶段 5 会由它
/// 生成 HostApi 的函数表（或 HostApi 的实现落回这里）。
///
/// 为什么不许工具直接调 std.fs / std.process：本模块将来要整体搬进 .so，
/// 那时它没有资格自己碰文件系统与进程 —— 能力必须由宿主授予。
pub const Host = struct {
    gpa: std.mem.Allocator,
    /// 每次工具调用专用的临时分配器（外部负责 reset），工具里不必释放内存。
    scratch: std.mem.Allocator,
    io: std.Io,
    /// 工具的工作目录（相对路径按它解析）。
    dir: std.Io.Dir,
    /// 单个工具结果的字节上限，超出即截断（防 bash 一条命令灌爆上下文）。
    max_output: usize = 30_000,
    /// bash 的默认超时（秒）。
    bash_timeout_s: i64 = 60,
};

// ───────────────────────────────────────────────────────────────────────────
//  工具表
// ───────────────────────────────────────────────────────────────────────────

const read_spec = ToolSpec{
    .name = "read",
    .description = "Read a file. Output is line-numbered as `<n>\\t<text>`.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File path, relative to the working directory"},"offset":{"type":"integer","description":"1-based line number to start from"},"limit":{"type":"integer","description":"Max number of lines to return"}},"required":["path"]}
    ,
};

const write_spec = ToolSpec{
    .name = "write",
    .description = "Write a file, overwriting it if it exists. Creates parent directories? No.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File path"},"content":{"type":"string","description":"Full file content"}},"required":["path","content"]}
    ,
};

const edit_spec = ToolSpec{
    .name = "edit",
    .description = "Replace the first occurrence of oldText with newText. oldText must appear exactly once, otherwise the edit is refused.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File path"},"oldText":{"type":"string","description":"Exact text to replace; must occur exactly once"},"newText":{"type":"string","description":"Replacement text"}},"required":["path","oldText","newText"]}
    ,
};

const bash_spec = ToolSpec{
    .name = "bash",
    .description = "Run a shell command with `bash -lc`, returning its stdout/stderr and exit code.",
    .parameters_json =
    \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command"},"timeoutSeconds":{"type":"integer","description":"Kill the command after this many seconds"}},"required":["command"]}
    ,
};

pub const all = [_]Tool{
    .{ .spec = read_spec, .exec = toolRead },
    .{ .spec = write_spec, .exec = toolWrite },
    .{ .spec = edit_spec, .exec = toolEdit },
    .{ .spec = bash_spec, .exec = toolBash },
};

pub fn find(name: []const u8) ?Tool {
    for (all) |t| {
        if (std.mem.eql(u8, std.mem.span(t.spec.name), name)) return t;
    }
    return null;
}

/// 生成请求体里 `tools` 字段所需的 JSON 数组文本（OpenAI 格式）。
///
/// name/description 用序列化（它们可能含引号），parameters_json 直接嵌入 ——
/// 它本身就是我们写死的合法 JSON Schema。
pub fn jsonSpec(arena: std.mem.Allocator) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("[");
    for (all, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
        try std.json.Stringify.value(std.mem.span(t.spec.name), .{}, w);
        try w.writeAll(",\"description\":");
        try std.json.Stringify.value(std.mem.span(t.spec.description), .{}, w);
        try w.writeAll(",\"parameters\":");
        try w.writeAll(std.mem.span(t.spec.parameters_json));
        try w.writeAll("}}");
    }
    try w.writeAll("]");
    return aw.written();
}

// ───────────────────────────────────────────────────────────────────────────
//  C ABI 包装层：把内部 error union 收成 abi.Status（边界上只允许 Status）
// ───────────────────────────────────────────────────────────────────────────

/// 失败结果的写法。状态码供宿主/日志决策，out 里的文字供模型阅读 —— 两者分开：
/// 模型看不到 Status，所以失败原因必须写进 out。
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

/// 参数问题（默认语义）。
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

fn hostFrom(impl: *anyopaque) *Host {
    return @ptrCast(@alignCast(impl));
}

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

fn oomOrInternal(out: *Buffer, e: anyerror) abi.Status {
    _ = failFmt(out, "工具内部错误：{s}", .{@errorName(e)});
    return if (e == error.OutOfMemory) .err_oom else .err_internal;
}

test "jsonSpec: 生成的工具数组是合法 JSON，且条目数与工具表一致" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const spec = try jsonSpec(a);
    const v = try std.json.parseFromSlice(std.json.Value, a, spec, .{});
    try std.testing.expectEqual(@as(usize, all.len), v.value.array.items.len);

    for (v.value.array.items, 0..) |item, i| {
        const f = item.object.get("function").?.object;
        try std.testing.expectEqualStrings(std.mem.span(all[i].spec.name), f.get("name").?.string);
        // parameters 必须是对象（Schema），不是字符串
        try std.testing.expect(f.get("parameters").? == .object);
    }
}

test "四个工具在参数不合法时都不 panic，而是把原因写进 out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var host = Host{
        .gpa = std.testing.allocator,
        .scratch = arena_state.allocator(),
        .io = std.testing.io,
        .dir = std.Io.Dir.cwd(),
    };

    var buf: [256]u8 = undefined;
    var out = Buffer{ .ptr = &buf, .cap = buf.len };

    inline for (all) |t| {
        out.len = 0;
        const st = t.exec(&host, "not json", &out);
        try std.testing.expect(st != .ok);
        try std.testing.expect(out.slice().len > 0);
    }
}

// ───────────────────────────────────────────────────────────────────────────
//  read
// ───────────────────────────────────────────────────────────────────────────

fn doRead(host: *Host, args_json: []const u8, out: *Buffer) !abi.Status {
    const Args = struct {
        path: []const u8,
        offset: ?u64 = null,
        limit: ?u64 = null,
    };
    const parsed = std.json.parseFromSlice(Args, host.scratch, args_json, .{ .ignore_unknown_fields = true }) catch
        return fail(out, "read: 参数必须是 {\"path\": \"...\", \"offset\"?, \"limit\"?}");
    const a = parsed.value;

    // 硬上限只为防「把整个大文件读进内存」，不是给模型的约束：
    // 模型要的是“读到多少行”，那由下面的 offset/limit 控制。
    const hard_cap: usize = 16 * 1024 * 1024;
    const data = host.dir.readFileAlloc(host.io, a.path, host.scratch, .limited(hard_cap)) catch |e| {
        const st: abi.Status = if (e == error.FileNotFound) .err_not_found else .err_internal;
        return failFmtAs(st, out, "read: 打开 {s} 失败：{s}", .{ a.path, @errorName(e) });
    };

    const first: usize = if (a.offset) |o| @intCast(o -| 1) else 0;
    const max_lines: usize = if (a.limit) |l| @intCast(l) else std.math.maxInt(usize);

    // 给尾部「还有多少行没显示」的提示留出空间。宁可少显示几行，
    // 也不能写爆缓冲区 —— 写爆就变成静默截断，模型会以为读完了。
    const reserve: usize = 160;
    const budget: usize = if (out.cap > reserve) out.cap - reserve else out.cap;

    // 总行数：与 splitScalar 的迭代次数一致（末尾换行会多出一个空行，
    // count('\n') + 1 恰好对上），用来告诉模型到底还剩下多少行。
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

fn doWrite(host: *Host, args_json: []const u8, out: *Buffer) !abi.Status {
    const Args = struct {
        path: []const u8,
        content: []const u8,
    };
    const parsed = std.json.parseFromSlice(Args, host.scratch, args_json, .{ .ignore_unknown_fields = true }) catch
        return fail(out, "write: 参数必须是 {\"path\": \"...\", \"content\": \"...\"}");
    const a = parsed.value;

    host.dir.writeFile(host.io, .{ .sub_path = a.path, .data = a.content }) catch |e|
        return failFmtAs(.err_internal, out, "write: 写入 {s} 失败：{s}", .{ a.path, @errorName(e) });

    return okFmt(out, "已写入 {s}（{d} 字节）", .{ a.path, a.content.len });
}

// ───────────────────────────────────────────────────────────────────────────
//  edit
// ───────────────────────────────────────────────────────────────────────────

fn doEdit(host: *Host, args_json: []const u8, out: *Buffer) !abi.Status {
    const Args = struct {
        path: []const u8,
        oldText: []const u8,
        newText: []const u8,
    };
    const parsed = std.json.parseFromSlice(Args, host.scratch, args_json, .{ .ignore_unknown_fields = true }) catch
        return fail(out, "edit: 参数必须是 {\"path\": \"...\", \"oldText\": \"...\", \"newText\": \"...\"}");
    const a = parsed.value;

    if (a.oldText.len == 0) return fail(out, "edit: oldText 不能为空（空串会匹配任意位置）");

    const data = host.dir.readFileAlloc(host.io, a.path, host.scratch, .limited(16 * 1024 * 1024)) catch |e| {
        const st: abi.Status = if (e == error.FileNotFound) .err_not_found else .err_internal;
        return failFmtAs(st, out, "edit: 打开 {s} 失败：{s}", .{ a.path, @errorName(e) });
    };

    const idx = std.mem.indexOf(u8, data, a.oldText) orelse
        return failFmt(out, "edit: 在 {s} 里找不到 oldText（注意缩进与空白必须逐字一致）", .{a.path});

    // 唯一性检查：出现两次就拒绝，让模型补更多上下文再来。
    // 理由：悄悄改掉第一处会让人以为改的是另一处，是最难查的一类事故。
    if (std.mem.indexOfPos(u8, data, idx + a.oldText.len, a.oldText) != null)
        return failFmt(out, "edit: oldText 在 {s} 里出现多次，请把上下文写长一些以唯一定位", .{a.path});

    const replaced = try std.mem.concat(host.scratch, u8, &.{
        data[0..idx],
        a.newText,
        data[idx + a.oldText.len ..],
    });
    host.dir.writeFile(host.io, .{ .sub_path = a.path, .data = replaced }) catch |e|
        return failFmtAs(.err_internal, out, "edit: 写回 {s} 失败：{s}", .{ a.path, @errorName(e) });

    return okFmt(out, "已修改 {s}：第 {d} 字节起，{d} 字节 → {d} 字节", .{
        a.path, idx, a.oldText.len, a.newText.len,
    });
}

// ───────────────────────────────────────────────────────────────────────────
//  bash
// ───────────────────────────────────────────────────────────────────────────

fn doBash(host: *Host, args_json: []const u8, out: *Buffer) !abi.Status {
    const Args = struct {
        command: []const u8,
        timeoutSeconds: ?i64 = null,
    };
    const parsed = std.json.parseFromSlice(Args, host.scratch, args_json, .{ .ignore_unknown_fields = true }) catch
        return fail(out, "bash: 参数必须是 {\"command\": \"...\", \"timeoutSeconds\"?}");
    const a = parsed.value;

    const timeout_s = a.timeoutSeconds orelse host.bash_timeout_s;

    // 硬上限只用于防「命令把内存吃光」（yes / cat 大文件 / 死循环打印），
    // 它不是给模型的约束 —— 给模型看的是下面那段主动截断 + 提示。
    const hard_cap: usize = 4 * 1024 * 1024;

    const res = std.process.run(host.scratch, host.io, .{
        // 用 bash -lc 而不是自己切词：命令原样交给 shell，与用户手敲一致
        .argv = &.{ "bash", "-lc", a.command },
        .stdout_limit = .limited(hard_cap),
        .stderr_limit = .limited(hard_cap),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromSeconds(timeout_s),
            .clock = .awake,
        } },
    }) catch |e| {
        if (e == error.StreamTooLong)
            return failFmtAs(.err_internal, out, "bash: 输出超过 {d} MB 硬上限，请用 head/grep 等收窄（命令：{s}）", .{ hard_cap / 1024 / 1024, a.command });
        return failFmtAs(.err_internal, out, "bash: 执行失败（{s}）：{s}", .{ @errorName(e), a.command });
    };

    // 尾部提示也要占地方，同样给缓冲区留出余量
    const reserve: usize = 400;
    const budget: usize = if (out.cap > reserve) out.cap - reserve else out.cap;

    var w = out.writer();
    switch (res.term) {
        .exited => |code| w.print("[exit {d}]\n", .{code}) catch {},
        else => w.print("[{any}]\n", .{res.term}) catch {},
    }

    // 优先保 stdout（多数命令的有用信息在那里）；装不下就截断并明说，
    // 绝不让模型以为它看到了完整输出。
    var truncated = false;
    if (res.stdout.len <= budget) {
        w.writeAll(res.stdout) catch {};
    } else {
        w.writeAll(res.stdout[0..budget]) catch {};
        truncated = true;
    }
    if (!truncated and res.stderr.len > 0) {
        const left = budget -| w.buffered().len;
        if (res.stderr.len + 10 > left) {
            w.writeAll("\n[stderr]\n") catch {};
            w.writeAll(res.stderr[0..(left -| 10)]) catch {};
            truncated = true;
        } else {
            w.writeAll("\n[stderr]\n") catch {};
            w.writeAll(res.stderr) catch {};
        }
    }
    if (truncated) {
        w.print("\n[截断] stdout {d} 字节 / stderr {d} 字节，请用 head、grep、--max-count 等收窄\n", .{ res.stdout.len, res.stderr.len }) catch {};
    }
    out.finish(&w);

    // 注意：命令以非 0 退出**不算工具失败** —— 模型需要看到错误输出来自己纠正。
    return .ok;
}
