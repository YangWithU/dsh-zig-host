//! ═══════════════════════════════════════════════════════════════════════════
//!  SSE 解析器 —— 把流式响应切成一条条事件
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! DeepSeek（以及所有 OpenAI 兼容接口）的流式响应长这样：
//!
//!     data: {"choices":[{"delta":{"content":"你"}}]}
//!     data: {"choices":[{"delta":{"content":"好"}}]}
//!     data: {"choices":[{"delta":{"tool_calls":[{"index":0,...}]}}]}
//!     data: [DONE]
//!
//! ★ 这个解析器存在的唯一理由：**网络给的是字节流，不是行**
//!   一个 TCP 包里可能是半行（`data: {"cho`），下一块才是剩下的。所以必须自己
//!   维护跨块的残留缓冲 —— 按 `\n` 切分却不处理这个，就会随机丢事件，而且频率
//!   取决于网络分片，本地测试根本复现不出来。
//!
//! 设计：固定缓冲、零分配。它跑在收数据的循环里，每次都要调，不值得为它引入
//! 一个分配器；单条 SSE 事件几百字节，8KB 的上限足够（超了明确报错，不静默截断）。

const std = @import("std");

/// 单行上限。超了返回 error.LineTooLong —— 宁可明确失败，也不要静默截断出
/// 一个半截 JSON 让下游去猜。
pub const max_line = 8 * 1024;

pub const SseParser = struct {
    /// 还没凑成完整一行的残留（跨 chunk 的半行就住在这里）
    buf: [max_line]u8 = undefined,
    len: usize = 0,

    /// 当前这条事件的内容。独立于 buf —— buf 每消费一行就会往前挪，
    /// 直接把 buf 里的切片交出去，下次 next 就悬空了。
    event: [max_line]u8 = undefined,

    pub const Event = union(enum) {
        /// 还没有完整的一行，等更多数据
        none,
        /// 有完整一行，但不是 data 行（SSE 的注释行、空行、event:/id: 等）
        ignored,
        /// 一条 data 的内容（已去掉 `data: ` 前缀）
        data: []const u8,
        /// 收到 [DONE]
        done,
    };

    /// 喂一块刚收到的数据。可以任意大小、任意切分。
    pub fn feed(self: *SseParser, chunk: []const u8) !void {
        if (self.len + chunk.len > self.buf.len) return error.LineTooLong;
        @memcpy(self.buf[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
    }

    /// 取下一个事件。没有完整行时返回 .none —— 调用方应当继续 feed。
    pub fn next(self: *SseParser) Event {
        const nl = std.mem.indexOfScalar(u8, self.buf[0..self.len], '\n') orelse return .none;

        // ★ 先把这一行搬到独立缓冲，**再**消费 buf。
        //   顺序反了就会被就地覆盖：消费是把 buf[nl+1..] 拷到 buf[0..]，
        //   而直接留在 buf 里的 line 切片正好是 buf[0..nl] —— 前者的目标区域
        //   与后者重叠。这个 bug 真出现过，且看起来像「第一条事件被第二条的
        //   开头覆写」这种莫名其妙的现象。
        const line_len = nl;
        if (line_len > self.event.len) return .ignored; // 理论上 feed 已经拦住了
        @memcpy(self.event[0..line_len], self.buf[0..line_len]);

        const rest_len = self.len - (nl + 1);
        std.mem.copyForwards(u8, self.buf[0..rest_len], self.buf[nl + 1 .. self.len]);
        self.len = rest_len;

        var line = self.event[0..line_len];
        // 兼容 CRLF
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (!std.mem.startsWith(u8, line, "data:")) return .ignored;

        var payload = line["data:".len..];
        if (payload.len > 0 and payload[0] == ' ') payload = payload[1..];
        if (std.mem.eql(u8, payload, "[DONE]")) return .done;

        // payload 指向 self.event，下次 next 才会被覆盖 —— 本次调用的返回值安全
        return .{ .data = payload };
    }
};

/// 把一整段 SSE 文本拆成所有 data 事件（测试与回放用：一次拿到全部数据）。
/// 返回的切片指向 parser.event，**每次调用都会覆盖**，所以批量场景要自己拷。
pub const Collector = struct {
    parser: SseParser = .{},
    items: std.ArrayList([]const u8),
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Collector {
        return .{ .gpa = gpa, .items = .empty };
    }

    pub fn deinit(self: *Collector) void {
        for (self.items.items) |s| self.gpa.free(s);
        self.items.deinit(self.gpa);
    }

    /// 喂一块数据，把解析出的事件攒起来（data 会复制一份）。
    pub fn feed(self: *Collector, chunk: []const u8) !void {
        try self.parser.feed(chunk);
        while (true) {
            switch (self.parser.next()) {
                .none => break,
                .ignored => continue,
                .done => break,
                .data => |d| try self.items.append(self.gpa, try self.gpa.dupe(u8, d)),
            }
        }
    }
};

// ───────────────────────────────────────────────────────────────────────────
//  测试
// ───────────────────────────────────────────────────────────────────────────

fn expectNext(parser: *SseParser, expected: SseParser.Event) !void {
    const got = parser.next();
    switch (expected) {
        .none => try std.testing.expect(got == .none),
        .ignored => try std.testing.expect(got == .ignored),
        .done => try std.testing.expect(got == .done),
        .data => |want| switch (got) {
            .data => |have| try std.testing.expectEqualStrings(want, have),
            else => return error.WrongEventKind,
        },
    }
}

test "SseParser: 一次给完整数据，逐条取出来" {
    var p = SseParser{};
    try p.feed(
        "data: {\"a\":1}\n" ++
            "data: {\"b\":2}\n" ++
            "data: [DONE]\n",
    );

    try expectNext(&p, .{ .data = "{\"a\":1}" });
    try expectNext(&p, .{ .data = "{\"b\":2}" });
    try expectNext(&p, .done);
    try expectNext(&p, .none);
}

test "SseParser: 跨 chunk 的半行 —— 这是它存在的理由" {
    var p = SseParser{};

    // 网络把一行切成了三块，中间还断在 JSON 里
    try p.feed("data: {\"cho");
    try expectNext(&p, .none);
    try p.feed("ices\":[{\"delta\"");
    try expectNext(&p, .none);
    try p.feed(":{\"content\":\"hi\"}}]}\n");
    try expectNext(&p, .{ .data = "{\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}" });
}

test "SseParser: 忽略非 data 行（空行、注释），兼容 CRLF" {
    var p = SseParser{};
    try p.feed(": keep-alive\n");
    try expectNext(&p, .ignored);
    try p.feed("\n");
    try expectNext(&p, .ignored);
    try p.feed("data: {\"x\":1}\r\n");
    try expectNext(&p, .{ .data = "{\"x\":1}" });
    try p.feed("event: ping\ndata: {\"y\":2}\n");
    try expectNext(&p, .ignored);
    try expectNext(&p, .{ .data = "{\"y\":2}" });
}

test "SseParser: 单行超限明确报错，不静默截断" {
    var p = SseParser{};
    const huge = "data: " ++ ("x" ** (max_line));
    try std.testing.expectError(error.LineTooLong, p.feed(huge));
}

test "SseParser: data 切片只活到下一次 next 为止（想留住就自己拷一份）" {
    var p = SseParser{};
    try p.feed("data: AAAA\ndata: BB\n");

    const first = p.next();
    try std.testing.expect(std.mem.eql(u8, first.data, "AAAA"));

    // 契约：返回的切片在下一次 next / feed 之前有效（它指向 parser 内部的
    // 事件缓冲）。批量收集时必须自己拷 —— Collector 就是这么做的。
    const saved = try std.testing.allocator.dupe(u8, first.data);
    defer std.testing.allocator.free(saved);

    try expectNext(&p, .{ .data = "BB" });
    // 留下来的那份不受影响
    try std.testing.expectEqualStrings("AAAA", saved);
}

test "Collector: 零敲碎打地喂，攒出来的事件一条不少" {
    const gpa = std.testing.allocator;
    var c = Collector.init(gpa);
    defer c.deinit();

    // 每个字符单独喂一次 —— 最极端的切分
    for ("data: {\"a\":1}\ndata: {\"b\":2}\n") |ch| {
        try c.feed(&[_]u8{ch});
    }

    try std.testing.expectEqual(@as(usize, 2), c.items.items.len);
    try std.testing.expectEqualStrings("{\"a\":1}", c.items.items[0]);
    try std.testing.expectEqualStrings("{\"b\":2}", c.items.items[1]);
}
