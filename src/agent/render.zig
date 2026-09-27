//! ═══════════════════════════════════════════════════════════════════════════
//!  渲染层：把事件变成终端上的一段文本
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 它只做「事件 -> 字符」：**不读输入、不碰终端状态、不做任何决策**。
//! 这个边界是刻意的 —— 将来要把它搬进插件（作为 UI 插件）时，搬的就是这一层，
//! 宿主那边只需要把「直接订阅 Bus」换成「插件注册监听」。
//!
//! 为什么现在留在宿主而不是做成插件：一个终端只有一个写者。TUI 与 loop 共享
//! 同一个 stderr，同时写就会撕裂界面；而插件是可热重载的陌生代码，崩了会把
//! 终端留在 raw mode 里（用户连 Ctrl-C 都按不出来）。越靠近基础设施的东西，
//! 越不该放进 .so。
//!
//! 输出格式（刻意的纯 ASCII 前缀，不用 box drawing 也不用 emoji）：
//!
//!     > 用户输入                     （REPL 自己打印，不走事件）
//!     [助手] 模型说的话
//!     [工具] bash
//!       $ ls *.zig
//!       -> ok（19 字节）
//!
//! 载荷的解析为什么手写而不用 std.json：这里是 C ABI 回调路径（onEvent 是
//! callconv(.c) 的函数指针），**没有分配器可用**，而 parseFromSlice 需要。
//! 载荷是我们自己编的固定形状，手写提取够用且无分配。

const std = @import("std");
const abi = @import("dsh_abi");

pub const Renderer = struct {
    /// 总开关（关掉就完全安静，便于脚本化使用）
    enabled: bool = true,
    /// 是否显示助手文本
    show_text: bool = true,
    /// 是否显示工具调用与结果
    show_tools: bool = true,
    /// 是否显示状态（默认关：它在交互终端里只是噪音）
    show_status: bool = false,

    /// 是否正在流式输出。**跨事件的状态**：流式段落里首段要打前缀、后续段直接
    /// 接上；等到下一个非 delta 事件到来时才能补那个换行。
    streaming: bool = false,

    /// 本轮的文本是否已经通过流式增量显示过了。
    /// 用来避免「delta 早就把文本显示完，紧接着的完整 assistant-text 又打一遍」。
    streamed: bool = false,
};

/// 某个事件关心的载荷上限。超出就截断 —— 渲染层不该因为一条超长消息炸掉。
const max_text = 8 * 1024;

/// Bus 监听器：把事件渲染出来，然后**放行**。
///
/// ★ `next` 必须调：渲染层只是观察者之一，它不调 next 就等于把后面所有监听器
///   （包括插件里的权限门）全挡掉了 —— 一个 UI 把业务拦死是最糟的一类 bug。
pub fn onEvent(
    user: *anyopaque,
    payload: *abi.EventPayload,
    next_ctx: *anyopaque,
    next: abi.NextFn,
) callconv(.c) abi.Status {
    const self: *Renderer = @ptrCast(@alignCast(user));

    if (self.enabled) {
        var buf: [max_text]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        renderTo(&w, std.mem.span(payload.name), std.mem.span(payload.json), self) catch {};
        if (w.buffered().len > 0) std.debug.print("{s}", .{w.buffered()});
    }

    return next(next_ctx, payload);
}

/// 纯渲染：把一条事件写进 writer。不打印、不碰终端 —— 所以能被直接测试。
///
/// `opts` 是**可变**的：流式输出需要跨事件记住「当前是不是正在接续一段文本」。
pub fn renderTo(
    w: *std.Io.Writer,
    event: []const u8,
    json: []const u8,
    opts: *Renderer,
) !void {
    // 流式增量单独处理：它要在同一行里继续追加，不能每段都打前缀
    if (std.mem.eql(u8, event, abi.EventNames.assistant_delta)) {
        if (!opts.show_text) return;
        return renderDelta(w, json, opts);
    }

    // 到了这里说明流式段落结束了（下一段将是别的东西）：把没打的换行补上。
    // 这一步放在分派之前，否则 show_status=false 时就没有人会补它了。
    if (opts.streaming) {
        try w.writeAll("\n");
        opts.streaming = false;
    }

    if (std.mem.eql(u8, event, abi.EventNames.assistant_text)) {
        // 刚流式输出过：文本已经在屏幕上了，这一条只剩「让上面那段把换行补上」
        // 的作用，不能再打一遍。
        if (opts.streamed) {
            opts.streamed = false;
            return;
        }
        if (!opts.show_text) return;
        return renderText(w, json);
    }
    if (std.mem.eql(u8, event, abi.EventNames.tool_call)) {
        if (!opts.show_tools) return;
        return renderToolCall(w, json);
    }
    if (std.mem.eql(u8, event, abi.EventNames.tool_result)) {
        if (!opts.show_tools) return;
        return renderToolResult(w, json);
    }
    if (std.mem.eql(u8, event, abi.EventNames.agent_status)) {
        if (!opts.show_status) return;
        return renderStatus(w, json);
    }
    // 不认识的事件安静放过：将来加了新事件，旧渲染层不该报错
}

/// 流式的一段增量：首段打前缀，后续直接接上。
fn renderDelta(w: *std.Io.Writer, json: []const u8, opts: *Renderer) !void {
    var buf: [max_text]u8 = undefined;
    const text = jsonStringField(json, "text", &buf) orelse return;
    if (text.len == 0) return;
    if (!opts.streaming) {
        try w.writeAll("\n[助手] ");
        opts.streaming = true;
    }
    opts.streamed = true;
    try w.writeAll(text);
}

fn renderText(w: *std.Io.Writer, json: []const u8) !void {
    var buf: [max_text]u8 = undefined;
    const text = jsonStringField(json, "text", &buf) orelse return;
    if (text.len == 0) return;
    try w.writeAll("\n[助手] ");
    try w.writeAll(text);
    try w.writeAll("\n");
}

fn renderToolCall(w: *std.Io.Writer, json: []const u8) !void {
    var name_buf: [64]u8 = undefined;
    var args_buf: [1024]u8 = undefined;
    var sum_buf: [512]u8 = undefined;

    const name = jsonStringField(json, "tool", &name_buf) orelse return;
    const args = jsonStringField(json, "arguments", &args_buf) orelse "{}";
    const summary = summarizeArgs(args, &sum_buf);

    try w.print("\n[工具] {s}\n  $ {s}\n", .{ name, summary });
}

fn renderToolResult(w: *std.Io.Writer, json: []const u8) !void {
    const ok = if (jsonRawField(json, "ok")) |v| std.mem.eql(u8, v, "true") else false;
    const bytes = jsonRawField(json, "bytes") orelse "?";
    try w.print("  -> {s}（{s} 字节）\n", .{ if (ok) "ok" else "失败", bytes });
}

fn renderStatus(w: *std.Io.Writer, json: []const u8) !void {
    var buf: [32]u8 = undefined;
    const state = jsonStringField(json, "state", &buf) orelse return;
    if (std.mem.eql(u8, state, "thinking")) {
        try w.writeAll("  [状态] 正在请求模型...\n");
    }
    // idle 不显示：安静下来本身就是信号，再打一行反而是噪音
}

/// 从工具参数里抽出「人类最想看的那一项」。
///
/// 启发式：先找 command（bash），再找 path（read/write/edit），都没有就把
/// 原文截断显示。渲染层不认识工具语义，也不该认识 —— 它只按约定猜一个键。
fn summarizeArgs(args_json: []const u8, out: []u8) []const u8 {
    var scratch: [1024]u8 = undefined;
    if (jsonStringField(args_json, "command", &scratch)) |cmd| {
        const n = @min(out.len, cmd.len);
        @memcpy(out[0..n], cmd[0..n]);
        return out[0..n];
    }
    if (jsonStringField(args_json, "path", &scratch)) |p| {
        const n = @min(out.len, p.len);
        @memcpy(out[0..n], p[0..n]);
        return out[0..n];
    }
    const n = @min(out.len, args_json.len);
    @memcpy(out[0..n], args_json[0..n]);
    return out[0..n];
}

/// 取 `"key":"value"` 的值并解码 JSON 转义，写进 out。
///
/// 容忍冒号与值之间的空白 —— 模型给参数的习惯写法是 `"command": "ls"`，
/// 只认无空格形式曾经真的漏掉过（界面上把整个参数 JSON 当命令显示了出来）。
///
/// 只处理我们自己的载荷会出现的转义（`\" \\ \n \t \r \/`）；`\uXXXX` 不解码，
/// 真遇到时原样带过（显示得难看，但不会假装解对了）。
/// 找不到 key、或值不是字符串 -> null。
fn jsonStringField(json: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, json, needle) orelse return null;

    var i = at + needle.len;
    while (i < json.len and isJsonSpace(json[i])) i += 1;
    if (i >= json.len or json[i] != ':') return null;
    i += 1;
    while (i < json.len and isJsonSpace(json[i])) i += 1;
    if (i >= json.len or json[i] != '"') return null; // 值不是字符串
    i += 1;

    var n: usize = 0;
    while (i < json.len) {
        const c = json[i];
        if (c == '\\' and i + 1 < json.len) {
            const decoded: u8 = switch (json[i + 1]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                else => json[i + 1],
            };
            if (n < out.len) {
                out[n] = decoded;
                n += 1;
            }
            i += 2;
            continue;
        }
        if (c == '"') break; // 值的结尾
        if (n < out.len) {
            out[n] = c;
            n += 1;
        }
        i += 1;
    }
    return out[0..n];
}

fn isJsonSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// 取 `"key":123` / `"key":true` 这类裸值的文本（自然去掉两侧空白）；
/// 同样要求冒号右侧紧跟着值，否则容易把另一个键的名字当值。
fn jsonRawField(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, json, needle) orelse return null;

    var i = at + needle.len;
    while (i < json.len and isJsonSpace(json[i])) i += 1;
    if (i >= json.len or json[i] != ':') return null;
    i += 1;
    while (i < json.len and isJsonSpace(json[i])) i += 1;

    const begin = i;
    while (i < json.len) : (i += 1) {
        switch (json[i]) {
            ',', '}' => break,
            else => {},
        }
    }
    return std.mem.trim(u8, json[begin..i], " \t\r\n");
}

// ───────────────────────────────────────────────────────────────────────────
//  测试：全是纯函数测试，不碰终端
// ───────────────────────────────────────────────────────────────────────────

test "renderTo: 助手文本（含转义换行）" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var opts = Renderer{};
    try renderTo(&w, abi.EventNames.assistant_text, "{\"text\":\"第一行\\n第二行\"}", &opts);

    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[助手] ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "第一行\n第二行") != null);
}

test "renderTo: 工具调用显示工具名与命令摘要（参数是转义过的字符串）" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var opts = Renderer{};

    // arguments 是**字符串**，里面的引号被转义过 —— 正好验证解码
    try renderTo(
        &w,
        abi.EventNames.tool_call,
        "{\"tool\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls *.zig\\\"}\"}",
        &opts,
    );

    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$ ls *.zig") != null);
}

test "renderTo: read 这类没有 command 的工具，退而显示 path" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var opts = Renderer{};
    try renderTo(
        &w,
        abi.EventNames.tool_call,
        "{\"tool\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"src/main.zig\\\"}\"}",
        &opts,
    );
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "src/main.zig") != null);
}

test "renderTo: 工具结果显示成败与字节数" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var opts = Renderer{};
    try renderTo(&w, abi.EventNames.tool_result, "{\"tool\":\"bash\",\"ok\":true,\"bytes\":19}", &opts);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "19") != null);
}

test "renderTo: 关掉工具显示之后什么都不写；未知事件也不写" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var quiet = Renderer{ .show_tools = false };
    try renderTo(&w, abi.EventNames.tool_call, "{\"tool\":\"bash\"}", &quiet);
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);

    var w2 = std.Io.Writer.fixed(&buf);
    var opts = Renderer{};
    try renderTo(&w2, "some/future-event", "{\"x\":1}", &opts);
    try std.testing.expectEqual(@as(usize, 0), w2.buffered().len);
}

test "renderTo 流式：首段带前缀、后续接上、遇其他事件才换行" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var opts = Renderer{};

    try renderTo(&w, abi.EventNames.assistant_delta, "{\"text\":\"你好\"}", &opts);
    try renderTo(&w, abi.EventNames.assistant_delta, "{\"text\":\"，我看看\"}", &opts);
    // 第二段不能又打一遍前缀，也不能换行
    try std.testing.expectEqualStrings("\n[助手] 你好，我看看", w.buffered());
    try std.testing.expect(opts.streaming);

    // 下一个非 delta 事件才收尾换行
    try renderTo(&w, abi.EventNames.tool_call, "{\"tool\":\"bash\",\"arguments\":\"{}\"}", &opts);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "\n[助手] 你好，我看看\n"));
    try std.testing.expect(!opts.streaming);
}

test "renderTo 流式：紧跟的完整文本不会被打第二遍" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var opts = Renderer{};

    try renderTo(&w, abi.EventNames.assistant_delta, "{\"text\":\"你好\"}", &opts);
    try renderTo(&w, abi.EventNames.assistant_delta, "{\"text\":\"世界\"}", &opts);
    // loop 在流式结束后会再发一次完整文本（非流式渲染靠它）
    try renderTo(&w, abi.EventNames.assistant_text, "{\"text\":\"你好世界\"}", &opts);

    try std.testing.expectEqualStrings("\n[助手] 你好世界\n", w.buffered());
}

test "jsonStringField: 解出转义、容忍冒号后的空白、找不到时返回 null" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("a\"b", jsonStringField("{\"k\":\"a\\\"b\"}", "k", &buf).?);
    try std.testing.expectEqualStrings("x", jsonStringField("{\"k\":\"x\",\"j\":1}", "k", &buf).?);
    // 模型给参数的习惯写法：冒号后带空格（这条曾经真的漏过）
    try std.testing.expectEqualStrings("ls -1", jsonStringField("{\"command\": \"ls -1\"}", "command", &buf).?);
    try std.testing.expect(jsonStringField("{\"k\":\"x\"}", "nope", &buf) == null);
    // 值是数字而不是字符串 -> null（不当成字符串硬取）
    try std.testing.expect(jsonStringField("{\"k\":1}", "k", &buf) == null);
}

test "jsonRawField: 取值去空白，且不会把别的键名当值" {
    try std.testing.expectEqualStrings("true", jsonRawField("{\"ok\": true}", "ok").?);
    try std.testing.expectEqualStrings("19", jsonRawField("{\"tool\":\"bash\",\"bytes\": 19}", "bytes").?);
    try std.testing.expect(jsonRawField("{\"toolname\":1}", "tool") == null);
}
