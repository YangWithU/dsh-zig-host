//! Agent 主循环：驱动「请求 -> 执行工具 -> 再请求」，直到模型给出最终答复。
//!
//! 职责: 把用户的一句话变成一次完整交互（可能包含多次工具调用）。
//! 数据流: main -> Loop.runTurn(用户输入)
//!           追加 user 消息 -> llm.complete() -> 打印文本
//!           -> 有 tool_calls 就逐个执行 -> 结果作为 role=tool 追加 -> 再请求
//! 不变量: ① 模型可见的每一步都必须进 Session，否则下一轮上下文不完整；
//!         ② 工具失败也把原因作为结果回给模型（让它自己纠正），不中断循环；
//!         ③ 必须有轮次上限 —— 模型完全可能反复调同一个工具。
//! 不可简化: 不能省掉「把 assistant 的 tool_calls 原样记进历史」这一步。少了它，
//!           下一轮的 role=tool 消息就没有对应的 tool_call_id，协议直接不合法。
//!
//! 生命周期: 历史里的每个字符串都拷进 session_arena（会话级），不指向临时缓冲区。
//!           另外，Loop 是**借用** client / session / host 的（内部存的是指针），
//!           所以这三者的地址一旦变化（结构体被拷贝、对象被移动），指针立即失效。
//!           调用方让它们与 Loop 活在同一作用域，并且不要把 Loop 拷走。

const std = @import("std");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const context_files = @import("context_files.zig");

pub const Config = struct {
    /// 单次输入最多允许几轮「请求 + 工具」往返
    max_rounds: u32 = 16,
    /// 单个工具结果缓冲区的字节数
    tool_output_bytes: usize = 64 * 1024,
};

pub const Loop = struct {
    gpa: std.mem.Allocator,
    /// 会话级 arena：历史里的字符串活到这里
    session_arena: std.mem.Allocator,
    io: std.Io,
    client: *llm.Client,
    session: *llm.Session,
    host: *tools.Host,
    tools_json: []const u8,
    system_prompt: []const u8,
    cfg: Config,
    tool_buf: []u8,

    pub fn init(
        gpa: std.mem.Allocator,
        session_arena: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        client: *llm.Client,
        session: *llm.Session,
        host: *tools.Host,
        cfg: Config,
    ) !Loop {
        // 工具清单与 system 提示只组装一次 —— 它们在一次会话里不会变
        const tools_json = try tools.jsonSpec(session_arena);
        const system_prompt = try buildSystemPrompt(session_arena, io, dir);

        return .{
            .gpa = gpa,
            .session_arena = session_arena,
            .io = io,
            .client = client,
            .session = session,
            .host = host,
            .tools_json = tools_json,
            .system_prompt = system_prompt,
            .cfg = cfg,
            .tool_buf = try gpa.alloc(u8, cfg.tool_output_bytes),
        };
    }

    pub fn deinit(self: *Loop) void {
        self.gpa.free(self.tool_buf);
    }

    /// 跑完一轮用户输入。返回后 Session 里已经记录了这一轮的全部往返。
    pub fn runTurn(self: *Loop, user_text: []const u8) !void {
        try self.session.append(.{
            .role = .user,
            .content = try self.session_arena.dupe(u8, user_text),
        });

        var round: u32 = 0;
        while (round < self.cfg.max_rounds) : (round += 1) {
            // 每轮一个临时 arena：请求体、工具参数这些用完就丢
            var turn = std.heap.ArenaAllocator.init(self.gpa);
            defer turn.deinit();
            const ta = turn.allocator();

            const done = try self.client.complete(ta, self.session, self.tools_json);

            if (done.text.len > 0) std.debug.print("{s}\n", .{done.text});

            // assistant 这一轮同样要进历史，且 tool_calls 必须原样保留
            try self.session.append(.{
                .role = .assistant,
                .content = try self.session_arena.dupe(u8, done.text),
                .tool_calls = try self.keepToolCalls(done.tool_calls),
            });

            if (!done.wantsTools()) return;

            for (done.tool_calls) |call| {
                const result = try self.runTool(ta, call);
                try self.session.append(.{
                    .role = .tool,
                    .tool_call_id = try self.session_arena.dupe(u8, call.id),
                    .content = result,
                });
            }
        }

        std.debug.print("[loop] 已达 {d} 轮上限，停止本轮（防模型反复调工具）\n", .{self.cfg.max_rounds});
    }

    /// 执行一个工具调用，返回可长期保存（已拷进 session arena）的结果文本。
    fn runTool(self: *Loop, ta: std.mem.Allocator, call: llm.ToolCall) ![]const u8 {
        const t = tools.find(call.name) orelse {
            const msg = try std.fmt.allocPrint(self.session_arena, "未知工具：{s}", .{call.name});
            std.debug.print("[tool] {s} -> 未知工具\n", .{call.name});
            return msg;
        };

        // 工具签名要 C 字符串（将来跨 ABI 的形态）
        const args_z = try ta.dupeZ(u8, call.arguments_json);

        var out = tools.Buffer{ .ptr = self.tool_buf.ptr, .cap = self.tool_buf.len, .len = 0 };
        const status = t.exec(self.host, args_z.ptr, &out);

        const text = out.slice();
        if (status != .ok) {
            // 失败时把内容也打出来，不然只能看到一个状态码（排查时很痛苦）
            std.debug.print("[tool] {s} -> {s}: {s}\n", .{ call.name, @tagName(status), text });
        } else {
            std.debug.print("[tool] {s} -> ok（{d} 字节）\n", .{ call.name, text.len });
        }

        // 结果要活到会话结束（下一轮请求还要用它），必须拷出来
        return self.session_arena.dupe(u8, text);
    }

    /// 把这一轮的 tool_calls 拷进 session arena（它们原本指向临时 arena）。
    fn keepToolCalls(self: *Loop, calls: []const llm.ToolCall) ![]const llm.ToolCall {
        if (calls.len == 0) return &.{};
        const kept = try self.session_arena.alloc(llm.ToolCall, calls.len);
        for (calls, 0..) |c, i| {
            kept[i] = .{
                .id = try self.session_arena.dupe(u8, c.id),
                .name = try self.session_arena.dupe(u8, c.name),
                .arguments_json = try self.session_arena.dupe(u8, c.arguments_json),
            };
        }
        return kept;
    }
};

/// 组装第一条 system 消息：前言 + 工具用法 + 项目规范 + 工作目录。
///
/// 顺序是有意的，从一般到具体：项目规范（可能很长）夹在中间，
/// 工作目录放最后 —— 模型最容易忽略的是中间，最需要记住的是「在哪儿干活」。
fn buildSystemPrompt(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll(
        \\You are a coding agent working in a terminal. You help the user by reading files,
        \\running shell commands, editing code and writing files.
        \\
        \\Tools available: read, write, edit, bash. Read a file before editing it;
        \\prefer small, verifiable steps over large speculative rewrites.
        \\
    );

    const ctx = try context_files.collect(arena, io, dir);
    if (ctx.len > 0) {
        try w.writeAll("\n");
        try context_files.render(w, ctx);
        try w.writeAll("\n");
    }

    const cwd = try std.process.currentPathAlloc(io, arena);
    try w.print("\nCurrent working directory: {s}\n", .{cwd});

    return aw.written();
}

// ─────────────────────────────────────────────────────────────────────────
//  测试：全部走回放传输，但工具是真的执行（bash 跑一条无副作用的 echo）
// ─────────────────────────────────────────────────────────────────────────

const round_with_tool_call =
    \\{"choices":[{"index":0,"message":{"role":"assistant","content":"",
    \\"tool_calls":[{"id":"call_1","type":"function","function":{"name":"bash",
    \\"arguments":"{\"command\":\"echo hello-from-tool\"}"}}]},"finish_reason":"tool_calls"}]}
;

const round_final =
    \\{"choices":[{"index":0,"message":{"role":"assistant","content":"完成了"},"finish_reason":"stop"}]}
;

const TestEnv = struct {
    arena_state: std.heap.ArenaAllocator,
    scratch_state: std.heap.ArenaAllocator,
    session: llm.Session,
    host: tools.Host,
    client: llm.Client,
    loop: Loop,

    fn init(self: *TestEnv, replay: *llm.ReplayTransport) !void {
        const gpa = std.testing.allocator;
        // 测试里必须用 std.testing.io（专供测试的 Io.Threaded 实例）；
        // std.Options.debug_io 在测试环境下不能用来起子进程
        const io = std.testing.io;
        self.arena_state = std.heap.ArenaAllocator.init(gpa);
        const arena = self.arena_state.allocator();
        self.scratch_state = std.heap.ArenaAllocator.init(gpa);
        self.session = llm.Session.init(arena);
        self.host = .{
            .gpa = gpa,
            .scratch = self.scratch_state.allocator(),
            .io = io,
            .dir = std.Io.Dir.cwd(),
        };
        self.client = llm.Client.init(arena, .{}, "fake-key", replay.asTransport());
        // 参数是 *TestEnv 而不是返回值：Loop 里存的是 &self.client 这类指针，
        // TestEnv 一旦被拷贝（返回结构体值），这些指针就悬空了。
        self.loop = try Loop.init(gpa, arena, io, std.Io.Dir.cwd(), &self.client, &self.session, &self.host, .{});
    }

    fn deinit(self: *TestEnv) void {
        self.loop.deinit();
        self.scratch_state.deinit();
        self.arena_state.deinit();
    }
};

test "runTurn: 先调工具拿到结果，再给最终答复（完整往返）" {
    var replay = llm.ReplayTransport{ .responses = &.{ round_with_tool_call, round_final }, .gpa = std.testing.allocator };
    defer replay.deinit();
    var env: TestEnv = undefined;
    try env.init(&replay);
    defer env.deinit();

    try env.loop.runTurn("帮我 echo 一下");

    // 请求发了两次：一次触发工具，一次拿结论
    try std.testing.expectEqual(@as(usize, 2), replay.calls);

    // 历史必须是 user / assistant(带 tool_calls) / tool / assistant
    const msgs = env.session.messages.items;
    try std.testing.expectEqual(@as(usize, 4), msgs.len);
    try std.testing.expectEqual(llm.Message.Role.user, msgs[0].role);
    try std.testing.expectEqual(llm.Message.Role.assistant, msgs[1].role);
    try std.testing.expectEqual(@as(usize, 1), msgs[1].tool_calls.len);
    try std.testing.expectEqual(llm.Message.Role.tool, msgs[2].role);
    try std.testing.expectEqualStrings("call_1", msgs[2].tool_call_id);
    try std.testing.expectEqualStrings("完成了", msgs[3].content);

    // 工具是真执行的：结果里应当有那条命令的输出
    try std.testing.expect(std.mem.indexOf(u8, msgs[2].content, "hello-from-tool") != null);
}

test "runTurn: 第二轮请求确实带上了工具结果" {
    var replay = llm.ReplayTransport{ .responses = &.{ round_with_tool_call, round_final }, .gpa = std.testing.allocator };
    defer replay.deinit();
    var env: TestEnv = undefined;
    try env.init(&replay);
    defer env.deinit();

    try env.loop.runTurn("帮我 echo 一下");

    // 最后一次请求体里必须出现 tool 角色与那条输出 —— 这正是「少记一步就协议不合法」的地方
    try std.testing.expect(std.mem.indexOf(u8, replay.last_request, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay.last_request, "hello-from-tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay.last_request, "call_1") != null);
}

test "runTurn: 未知工具不中断循环，而是把原因回给模型" {
    const unknown_tool = "{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"c9\",\"type\":\"function\",\"function\":{\"name\":\"frobnicate\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}";
    var replay = llm.ReplayTransport{ .responses = &.{ unknown_tool, round_final }, .gpa = std.testing.allocator };
    defer replay.deinit();
    var env: TestEnv = undefined;
    try env.init(&replay);
    defer env.deinit();

    try env.loop.runTurn("用个不存在的工具");

    const msgs = env.session.messages.items;
    try std.testing.expectEqual(@as(usize, 4), msgs.len);
    try std.testing.expect(std.mem.indexOf(u8, msgs[2].content, "未知工具") != null);
}

test "runTurn: 模型反复调工具时会在轮次上限停下来" {
    // 同一个响应给很多次：模型永远在调工具
    var replay = llm.ReplayTransport{ .responses = &.{round_with_tool_call}, .gpa = std.testing.allocator };
    defer replay.deinit();
    var env: TestEnv = undefined;
    try env.init(&replay);
    defer env.deinit();
    env.loop.cfg.max_rounds = 2;

    try env.loop.runTurn("停不下来");

    try std.testing.expectEqual(@as(usize, 2), replay.calls);
}
