//! LLM 客户端：把「对话历史 + 工具清单」换成一次模型回复。
//!
//! 职责: 组装请求体、发出去、解析回复。**只做一次请求一次解析**。
//! 数据流: loop -> Client.complete() -> buildRequest() -> Transport.send() -> parseResponse()
//! 不变量: ① 不重试、不循环（那是 loop 的事，重试策略属于调度不属于传输）；
//!         ② 解析不到就报错，不猜；模型给的 arguments 原样保留为字符串 ——
//!            它确实可能是非法 JSON，容错是工具层的责任，不是这里的；
//!         ③ 回放与真实两条路径共用同一套解析代码，否则用回放测出来的结论不算数。
//! 不可简化: 不能把「发请求」和「解析」写成一体。测试时唯一需要替换的是发请求那一步，
//!           所以传输必须是可注入的（Transport），而不是直接调 std.http。
//!
//! 已验证的环境事实: 端点 https://api.deepseek.com/chat/completions（OpenAI 兼容），
//! 模型 deepseek-flash / deepseek-v4-pro，密钥走 DEEPSEEK_API_KEY，
//! TLS 根证书由 std.http.Client 自动加载（不必手动指定 CA 路径）。

const std = @import("std");
const sse = @import("sse.zig");

// ───────────────────────────────────────────────────────────────────────────
//  消息与历史
// ───────────────────────────────────────────────────────────────────────────

pub const Message = struct {
    role: Role,
    content: []const u8 = "",
    /// 仅 role=tool 用：这条结果对应哪个 tool_call
    tool_call_id: []const u8 = "",
    /// 仅 role=assistant 用：模型要求的工具调用
    tool_calls: []const ToolCall = &.{},

    pub const Role = enum {
        system,
        user,
        assistant,
        tool,

        pub fn wire(self: Role) []const u8 {
            return switch (self) {
                .system => "system",
                .user => "user",
                .assistant => "assistant",
                .tool => "tool",
            };
        }
    };
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    /// 参数 JSON 文本，原样保存（可能是非法 JSON，由工具层报错给模型）
    arguments_json: []const u8,
};

/// 对话历史。append-only：模型可见的东西只能从这里重建，不能存在于别处。
///
/// 内存说明: Message 里的字符串不归 Session 所有（由调用方传给它的 arena 持有）。
/// 这样 Session 只管结构、不管字符串生命周期，避免两处所有权。MVP 用一个活到
/// 进程结束的 arena，不需要逐个释放。
pub const Session = struct {
    gpa: std.mem.Allocator,
    messages: std.ArrayList(Message) = .empty,

    pub fn init(gpa: std.mem.Allocator) Session {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Session) void {
        self.messages.deinit(self.gpa);
    }

    pub fn append(self: *Session, m: Message) !void {
        try self.messages.append(self.gpa, m);
    }
};

pub const Completion = struct {
    text: []const u8 = "",
    tool_calls: []const ToolCall = &.{},
    finish_reason: []const u8 = "",
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,

    pub fn wantsTools(self: Completion) bool {
        return self.tool_calls.len > 0;
    }
};

pub const Config = struct {
    base_url: []const u8 = "https://api.deepseek.com",
    model: []const u8 = "deepseek-flash",
    max_tokens: u32 = 8192,
    temperature: f32 = 0.0,
};

// ───────────────────────────────────────────────────────────────────────────
//  传输层：唯一依赖网络的地方，也是测试时唯一要替换的地方
// ───────────────────────────────────────────────────────────────────────────

/// 一次 HTTP 往返。status 交给调用方判断，body 无论成败都留着 ——
/// 出错时响应体里往往写着原因（401 密钥错、429 限流、模型拒绝）。
pub const Response = struct {
    status: u16,
    body: []const u8,
};

/// 把流式增量拼成一个 Completion。
///
/// 工具调用是这里的难点：`id` / `name` 只在第一块出现，`arguments` 会被切成
/// 很多块，多路工具调用靠 `index` 区分 —— 所以要**按 index 累积**，不能假设
/// 先后到达的块属于同一个调用（模型可以交错地往回送）。
pub const StreamAccumulator = struct {
    arena: std.mem.Allocator,
    text: std.ArrayList(u8),
    calls: std.ArrayList(ToolCall),
    finish_reason: []const u8 = "",
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    /// 解析出的错误。回调路径不能抛错，只能记下来由调用方事后查。
    failed: bool = false,
    /// 每收到一段文本就回调一次（渲染层靠它逐字显示）
    on_text: ?Sink = null,

    pub fn init(arena: std.mem.Allocator) StreamAccumulator {
        return .{ .arena = arena, .text = .empty, .calls = .empty };
    }

    /// 消费一条 SSE `data:` 的内容（一个 OpenAI 流式 chunk）。
    pub fn consume(self: *StreamAccumulator, data: []const u8) !void {
        const Wire = struct {
            choices: []const Choice = &.{},
            usage: ?Usage = null,

            const Choice = struct {
                delta: ?Delta = null,
                finish_reason: ?[]const u8 = null,
            };
            const Delta = struct {
                content: ?[]const u8 = null,
                tool_calls: ?[]const ToolCallDelta = null,
            };
            const ToolCallDelta = struct {
                index: ?u32 = null,
                id: ?[]const u8 = null,
                function: ?Function = null,

                const Function = struct {
                    name: ?[]const u8 = null,
                    arguments: ?[]const u8 = null,
                };
            };
            const Usage = struct {
                prompt_tokens: ?u64 = null,
                completion_tokens: ?u64 = null,
            };
        };

        const parsed = try std.json.parseFromSliceLeaky(Wire, self.arena, data, .{
            .ignore_unknown_fields = true,
        });

        for (parsed.choices) |c| {
            if (c.finish_reason) |f| self.finish_reason = f;

            const delta = c.delta orelse continue;

            if (delta.content) |piece| {
                if (piece.len > 0) {
                    try self.text.appendSlice(self.arena, piece);
                    if (self.on_text) |s| s.on_data(s.ctx, piece);
                }
            }

            for (delta.tool_calls orelse &.{}) |tc| {
                const idx: usize = tc.index orelse 0;
                // 稀疏扩容：多路调用可能先到 index=1 再到 index=0
                while (self.calls.items.len <= idx) {
                    try self.calls.append(self.arena, .{ .id = "", .name = "", .arguments_json = "" });
                }
                const slot = &self.calls.items[idx];
                if (tc.id) |id| {
                    slot.id = try std.mem.concat(self.arena, u8, &.{ slot.id, id });
                }
                if (tc.function) |f| {
                    if (f.name) |n| {
                        slot.name = try std.mem.concat(self.arena, u8, &.{ slot.name, n });
                    }
                    if (f.arguments) |a| {
                        slot.arguments_json = try std.mem.concat(self.arena, u8, &.{ slot.arguments_json, a });
                    }
                }
            }
        }

        if (parsed.usage) |u| {
            if (u.prompt_tokens) |v| self.prompt_tokens = v;
            if (u.completion_tokens) |v| self.completion_tokens = v;
        }
    }

    pub fn finish(self: *StreamAccumulator) Completion {
        return .{
            .text = self.text.items,
            .tool_calls = self.calls.items,
            .finish_reason = self.finish_reason,
            .prompt_tokens = self.prompt_tokens,
            .completion_tokens = self.completion_tokens,
        };
    }
};

/// 流式回调：用「函数指针 + 上下文」而不是 Zig 闭包 —— 这条路径要走 C 风格的
/// writer 回调，闭包在这里没有位置。
pub const Sink = struct {
    ctx: *anyopaque,
    on_data: *const fn (ctx: *anyopaque, data: []const u8) void,
};

pub const Transport = struct {
    ctx: *anyopaque,
    send: *const fn (
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        url: []const u8,
        auth: []const u8,
        body: []const u8,
    ) anyerror!Response,

    /// 流式发送：每解析出一条 SSE `data:` 就回调一次。返回 HTTP 状态码。
    sendStream: *const fn (
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        url: []const u8,
        auth: []const u8,
        body: []const u8,
        sink: Sink,
    ) anyerror!u16,
};

/// 挂在 HTTP 响应上的 writer：数据一到就喂给 SSE 解析器。
///
/// ★ buffer 容量为 0 是刻意的。Writer 只在「数据放不进 buffer」时才调 drain，
///   给它一个非零 buffer 就意味着 SSE 事件先攒在 buffer 里、攒满才被处理 ——
///   那就不是流式了（token 早就到了，界面上却不动）。
///
/// ⚠️ 必须在使用者自己的作用域里构造（`var s: StreamSink = undefined; s.init(...)`）。
///    靠返回值拷贝不行：writer 靠 @fieldParentPtr 反查回它，地址一变就失效。
const StreamSink = struct {
    parser: sse.SseParser = .{},
    sink: Sink,
    writer: std.Io.Writer = undefined,
    /// drain 只能抛 Writer.Error，业务错误记在这里
    failed: bool = false,
    /// 响应体的开头若干字节：非 200 时响应体不是 SSE，错误原因在里面，
    /// 而流式路径不像非流式那样能把整个 body 留下来。
    head: [400]u8 = undefined,
    head_len: usize = 0,

    fn init(self: *StreamSink, sink: Sink) void {
        self.* = .{ .sink = sink };
        self.writer = .{ .vtable = &vtable, .buffer = &.{}, .end = 0 };
    }

    const vtable = std.Io.Writer.VTable{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *StreamSink = @alignCast(@fieldParentPtr("writer", w));

        var total: usize = 0;
        for (data, 0..) |chunk, i| {
            // 最后一片可能要求重复 splat 次
            const times = if (i + 1 == data.len) splat else 1;
            var t: usize = 0;
            while (t < times) : (t += 1) {
                self.consume(chunk) catch {
                    self.failed = true;
                    return error.WriteFailed;
                };
                total += chunk.len;
            }
        }
        return total;
    }

    fn consume(self: *StreamSink, chunk: []const u8) !void {
        const room = self.head.len - self.head_len;
        if (room > 0) {
            const n = @min(room, chunk.len);
            @memcpy(self.head[self.head_len..][0..n], chunk[0..n]);
            self.head_len += n;
        }

        try self.parser.feed(chunk);
        while (true) {
            switch (self.parser.next()) {
                .none => break,
                .ignored => continue,
                .done => break,
                .data => |d| self.sink.on_data(self.sink.ctx, d),
            }
        }
    }
};

pub const HttpTransport = struct {
    client: std.http.Client,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) HttpTransport {
        return .{ .client = .{ .allocator = gpa, .io = io } };
    }

    pub fn deinit(self: *HttpTransport) void {
        self.client.deinit();
    }

    pub fn asTransport(self: *HttpTransport) Transport {
        return .{ .ctx = self, .send = send, .sendStream = sendStream };
    }

    fn send(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        url: []const u8,
        auth: []const u8,
        body: []const u8,
    ) anyerror!Response {
        const self: *HttpTransport = @ptrCast(@alignCast(ctx));

        var aw: std.Io.Writer.Allocating = .init(arena);
        const res = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = auth },
            },
            .response_writer = &aw.writer,
        });
        // 失败要看得见：把响应体打出来（限流、鉴权、模型拒绝的原因都在里面）。
        // 打印归传输层：状态码是 HTTP 的事，回放传输不该跟着吵。
        if (@intFromEnum(res.status) != 200) {
            std.debug.print("[llm] HTTP {d}: {s}\n", .{
                @intFromEnum(res.status),
                aw.written()[0..@min(aw.written().len, 600)],
            });
        }
        return .{ .status = @intFromEnum(res.status), .body = aw.written() };
    }

    fn sendStream(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        url: []const u8,
        auth: []const u8,
        body: []const u8,
        sink: Sink,
    ) anyerror!u16 {
        _ = arena;
        const self: *HttpTransport = @ptrCast(@alignCast(ctx));

        var stream: StreamSink = undefined;
        stream.init(sink);

        const res = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "text/event-stream" },
            },
            .response_writer = &stream.writer,
        });

        const status = @intFromEnum(res.status);
        if (status != 200) {
            std.debug.print("[llm] HTTP {d}: {s}\n", .{ status, stream.head[0..stream.head_len] });
        }
        if (stream.failed) return error.SseParseFailed;
        return status;
    }
};

/// 回放：不联网，按顺序返回预先准备好的响应。
///
/// 存在的意义是把 loop 的测试变成确定性的 —— 毫秒级、可断言、不花钱、不受限流影响。
/// 支持多个响应是为了测「先调工具、再给结论」这种多轮剧本；
/// 顺带记下最后一次请求体与调用次数，便于断言「我们发了什么、发了几次」。
pub const ReplayTransport = struct {
    responses: []const []const u8 = &.{},
    status: u16 = 200,
    calls: usize = 0,
    /// 给了分配器就把每次请求体拷一份下来 —— 请求体本身是每轮临时 arena 的，
    /// 循环结束后就没了，直接存指针会悬空（这是被测试逮到过的真实翻车）。
    gpa: ?std.mem.Allocator = null,
    last_request: []const u8 = "",

    pub fn deinit(self: *ReplayTransport) void {
        if (self.gpa) |g| {
            if (self.last_request.len > 0) g.free(self.last_request);
        }
        self.last_request = "";
    }

    pub fn asTransport(self: *ReplayTransport) Transport {
        return .{ .ctx = self, .send = send, .sendStream = sendStream };
    }

    fn sendStream(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        url: []const u8,
        auth: []const u8,
        body: []const u8,
        sink: Sink,
    ) anyerror!u16 {
        _ = arena;
        _ = url;
        _ = auth;
        const self: *ReplayTransport = @ptrCast(@alignCast(ctx));

        if (self.gpa) |g| {
            if (self.last_request.len > 0) g.free(self.last_request);
            self.last_request = try g.dupe(u8, body);
        } else {
            self.last_request = body;
        }

        defer self.calls += 1;
        if (self.responses.len == 0) return self.status;

        const idx = @min(self.calls, self.responses.len - 1);
        // 剧本里放的就是**真正的 SSE 文本**（`data: {...}\n`）：这样测试跑的
        // 是与线上同一条解析路径，而不是另写一份「假的流式」。
        var parser = sse.SseParser{};
        parser.feed(self.responses[idx]) catch return error.SseParseFailed;
        while (true) {
            switch (parser.next()) {
                .none => break,
                .ignored => continue,
                .done => break,
                .data => |d| sink.on_data(sink.ctx, d),
            }
        }
        return self.status;
    }

    fn send(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        url: []const u8,
        auth: []const u8,
        body: []const u8,
    ) anyerror!Response {
        _ = arena;
        _ = url;
        _ = auth;
        const self: *ReplayTransport = @ptrCast(@alignCast(ctx));

        if (self.gpa) |g| {
            if (self.last_request.len > 0) g.free(self.last_request);
            self.last_request = try g.dupe(u8, body);
        } else {
            self.last_request = body;
        }

        defer self.calls += 1;
        if (self.responses.len == 0) return .{ .status = self.status, .body = "" };
        // 用完之后一直重复最后一条，免得调用次数一多就报错
        const i = @min(self.calls, self.responses.len - 1);
        return .{ .status = self.status, .body = self.responses[i] };
    }
};

// ───────────────────────────────────────────────────────────────────────────
//  客户端
// ───────────────────────────────────────────────────────────────────────────

pub const Client = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    api_key: []const u8,
    transport: Transport,

    pub fn init(gpa: std.mem.Allocator, cfg: Config, api_key: []const u8, transport: Transport) Client {
        return .{ .gpa = gpa, .cfg = cfg, .api_key = api_key, .transport = transport };
    }

    /// 发一次请求并解析回复。arena 负责这次请求涉及的全部临时内存。
    ///
    /// `extra_system` 是本次请求**额外注入**的 system 内容（空 = 不注入）。
    /// 它只活在这一份请求体里，不进会话历史 —— 插件的「注入检索到的上下文」
    /// 就是走这条路（见 agent/request 事件）。
    pub fn complete(
        self: *Client,
        arena: std.mem.Allocator,
        session: *const Session,
        tools_json: []const u8,
        extra_system: []const u8,
    ) !Completion {
        const body = try buildRequest(arena, self.cfg, session, tools_json, extra_system, false);
        const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key});
        const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{self.cfg.base_url});

        const res = try self.transport.send(self.transport.ctx, arena, url, auth, body);
        if (res.status != 200) return error.HttpStatusNotOk;
        return parseResponse(arena, res.body);
    }

    /// 流式发一次请求：文本增量通过 `on_text` **实时**回调，返回拼好的完整结果。
    ///
    /// 与非流式共用同一套请求体与解析器 —— 差别只在于数据是边到边处理的。
    pub fn completeStream(
        self: *Client,
        arena: std.mem.Allocator,
        session: *const Session,
        tools_json: []const u8,
        extra_system: []const u8,
        on_text: ?Sink,
    ) !Completion {
        const body = try buildRequest(arena, self.cfg, session, tools_json, extra_system, true);
        const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key});
        const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{self.cfg.base_url});

        var acc = StreamAccumulator.init(arena);
        acc.on_text = on_text;

        const status = try self.transport.sendStream(
            self.transport.ctx,
            arena,
            url,
            auth,
            body,
            .{ .ctx = @ptrCast(&acc), .on_data = consumeInto },
        );
        if (status != 200) return error.HttpStatusNotOk;
        if (acc.failed) return error.StreamParseFailed;
        return acc.finish();
    }
};

/// 流式回调桥：把每一条 SSE data 喂给累积器。
/// 抛不了错（回调签名是 void），所以失败记在 acc.failed 上，调用方事后查。
fn consumeInto(ctx: *anyopaque, data: []const u8) void {
    const acc: *StreamAccumulator = @ptrCast(@alignCast(ctx));
    acc.consume(data) catch {
        acc.failed = true;
    };
}

// ───────────────────────────────────────────────────────────────────────────
//  请求体组装
// ───────────────────────────────────────────────────────────────────────────

/// `tools_json` 已是合法的 JSON 数组文本（由 tools.zig 的 spec 生成），直接嵌入；
/// messages 则用类型序列化，避免手写转义出错（工具输出里有换行和引号）。
pub fn buildRequest(
    arena: std.mem.Allocator,
    cfg: Config,
    session: *const Session,
    tools_json: []const u8,
    extra_system: []const u8,
    stream: bool,
) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("{\"model\":");
    try std.json.Stringify.value(cfg.model, .{}, w);
    try w.writeAll(",\"messages\":[");
    var written: usize = 0;
    for (session.messages.items, 0..) |m, i| {
        if (written > 0) try w.writeAll(",");
        try writeMessage(w, m);
        written += 1;

        // 注入的额外上下文紧跟第一条（system）之后：放在最前面让模型一定看到，
        // 但又不沾污会话历史（它只是这一份请求体里的临时内容）。
        if (i == 0 and extra_system.len > 0) {
            try w.writeAll(",");
            try writeMessage(w, .{ .role = .system, .content = extra_system });
            written += 1;
        }
    }
    try w.writeAll("]");

    if (tools_json.len > 0 and !std.mem.eql(u8, tools_json, "[]")) {
        try w.writeAll(",\"tools\":");
        try w.writeAll(tools_json);
        try w.writeAll(",\"tool_choice\":\"auto\"");
    }

    try w.print(",\"max_tokens\":{d},\"temperature\":{d}", .{ cfg.max_tokens, cfg.temperature });
    if (stream) try w.writeAll(",\"stream\":true");
    try w.writeAll("}");
    return aw.written();
}

fn writeMessage(w: *std.Io.Writer, m: Message) !void {
    try w.writeAll("{\"role\":");
    try std.json.Stringify.value(m.role.wire(), .{}, w);

    if (m.tool_call_id.len > 0) {
        try w.writeAll(",\"tool_call_id\":");
        try std.json.Stringify.value(m.tool_call_id, .{}, w);
    }

    try w.writeAll(",\"content\":");
    try std.json.Stringify.value(m.content, .{}, w);

    if (m.tool_calls.len > 0) {
        try w.writeAll(",\"tool_calls\":[");
        for (m.tool_calls, 0..) |tc, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"id\":");
            try std.json.Stringify.value(tc.id, .{}, w);
            try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
            try std.json.Stringify.value(tc.name, .{}, w);
            try w.writeAll(",\"arguments\":");
            // arguments 本身是一段 JSON 文本，按字符串序列化（会被正确转义）
            try std.json.Stringify.value(tc.arguments_json, .{}, w);
            try w.writeAll("}}");
        }
        try w.writeAll("]");
    }

    try w.writeAll("}");
}

// ───────────────────────────────────────────────────────────────────────────
//  响应解析
// ───────────────────────────────────────────────────────────────────────────

/// 只声明我们真正要用的字段。忽略未知字段是必须的 ——
/// 响应里还有 reasoning_content、logprobs、system_fingerprint 等一堆东西。
const WireResponse = struct {
    choices: []const Choice = &.{},
    usage: ?Usage = null,

    const Choice = struct {
        message: Msg = .{},
        finish_reason: ?[]const u8 = null,
    };

    const Msg = struct {
        content: ?[]const u8 = null,
        tool_calls: ?[]const WireCall = null,
    };

    const WireCall = struct {
        id: []const u8 = "",
        function: Fn = .{},

        const Fn = struct {
            name: []const u8 = "",
            arguments: []const u8 = "{}",
        };
    };

    const Usage = struct {
        prompt_tokens: u64 = 0,
        completion_tokens: u64 = 0,
    };
};

pub fn parseResponse(arena: std.mem.Allocator, body: []const u8) !Completion {
    const parsed = try std.json.parseFromSlice(WireResponse, arena, body, .{
        .ignore_unknown_fields = true,
    });
    if (parsed.value.choices.len == 0) return error.EmptyChoices;
    const ch = parsed.value.choices[0];

    var calls: std.ArrayList(ToolCall) = .empty;
    if (ch.message.tool_calls) |tcs| {
        for (tcs) |tc| {
            try calls.append(arena, .{
                .id = tc.id,
                .name = tc.function.name,
                .arguments_json = tc.function.arguments,
            });
        }
    }

    return .{
        .text = ch.message.content orelse "",
        .tool_calls = try calls.toOwnedSlice(arena),
        .finish_reason = ch.finish_reason orelse "",
        .prompt_tokens = if (parsed.value.usage) |u| u.prompt_tokens else 0,
        .completion_tokens = if (parsed.value.usage) |u| u.completion_tokens else 0,
    };
}

/// 本账号网关实测可用的模型。
pub const known_models = [_][]const u8{ "deepseek-flash", "deepseek-v4-pro" };

// ─────────────────────────────────────────────────────────────────────────
//  测试：全部走回放传输，不联网、不花钱、结果确定
// ─────────────────────────────────────────────────────────────────────────

const fake_tool_call_response =
    \\{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":"先看一下目录",
    \\"tool_calls":[{"id":"call_1","type":"function","function":{"name":"bash",
    \\"arguments":"{\"command\":\"ls\"}"}}]},"finish_reason":"tool_calls"}],
    \\"usage":{"prompt_tokens":11,"completion_tokens":7},"reasoning_content":"会被忽略"}
;

test "parseResponse: 取出文本、工具调用与用量，并忽略未知字段" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const c = try parseResponse(a, fake_tool_call_response);
    try std.testing.expectEqualStrings("先看一下目录", c.text);
    try std.testing.expectEqualStrings("tool_calls", c.finish_reason);
    try std.testing.expectEqual(@as(usize, 1), c.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", c.tool_calls[0].id);
    try std.testing.expectEqualStrings("bash", c.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", c.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(u64, 11), c.prompt_tokens);
    try std.testing.expect(c.wantsTools());
}

test "buildRequest: 产物是合法 JSON，转义正确" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var session = Session.init(a);
    try session.append(.{ .role = .system, .content = "你是助手" });
    try session.append(.{ .role = .user, .content = "带\"引号\"和\n换行的内容" });
    try session.append(.{
        .role = .assistant,
        .tool_calls = &.{.{ .id = "c1", .name = "bash", .arguments_json = "{\"command\":\"ls\"}" }},
    });
    try session.append(.{ .role = .tool, .tool_call_id = "c1", .content = "a\nb" });

    const body = try buildRequest(a, .{}, &session, "[]", "", false);
    // 能原样解析回来 = 转义正确；手拼 JSON 最容易在这里出错
    const v = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    try std.testing.expectEqualStrings("deepseek-flash", v.value.object.get("model").?.string);
    const msgs = v.value.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 4), msgs.items.len);
    try std.testing.expectEqualStrings("system", msgs.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("带\"引号\"和\n换行的内容", msgs.items[1].object.get("content").?.string);
    const calls = msgs.items[2].object.get("tool_calls").?.array;
    try std.testing.expectEqualStrings("bash", calls.items[0].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("c1", msgs.items[3].object.get("tool_call_id").?.string);
    // 没传工具时不应出现 tools/tool_choice 字段
    try std.testing.expect(v.value.object.get("tools") == null);
}

test "complete: 走回放传输，端到端不联网" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var replay = ReplayTransport{ .responses = &.{fake_tool_call_response} };
    var client = Client.init(a, .{}, "fake-key", replay.asTransport());

    var session = Session.init(a);
    try session.append(.{ .role = .user, .content = "看看目录" });

    const c = try client.complete(a, &session, "[]", "");
    try std.testing.expectEqual(@as(usize, 1), c.tool_calls.len);
    try std.testing.expect(std.mem.indexOf(u8, replay.last_request, "看看目录") != null);
}

test "complete: 非 200 时报错而不是硬吞" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var replay = ReplayTransport{ .responses = &.{"{\"error\":\"rate limited\"}"}, .status = 429 };
    var client = Client.init(a, .{}, "fake-key", replay.asTransport());

    var session = Session.init(a);
    try session.append(.{ .role = .user, .content = "hi" });

    try std.testing.expectError(error.HttpStatusNotOk, client.complete(a, &session, "[]", ""));
}
