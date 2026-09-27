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
//!           另外，Loop 是**借用** client / session / tools_iface 的（内部存的是
//!           指针），所以这三者的地址一旦变化（结构体被拷贝、对象被移动），指针
//!           立即失效。调用方让它们与 Loop 活在同一作用域，并且不要把 Loop 拷走。
//!
//! 与工具的关系（移植完成后的形态）: loop **不认识任何工具名**。它把模型给的
//!           名字与参数原样交给工具表服务，连「未知工具」这种回答也是工具表写在
//!           out 里的一段文字，loop 只负责搬运。所以工具在哪个 .so 里、有几个、
//!           叫什么，对 loop 完全不可见。

const std = @import("std");
const abi = @import("dsh_abi");
const tool_api = @import("dsh_tools");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const context_files = @import("context_files.zig");
const session_log = @import("session_log.zig");

pub const Config = struct {
    /// 单次输入最多允许几轮「请求 + 工具」往返
    max_rounds: u32 = 32,
    /// 单个工具结果缓冲区的字节数
    tool_output_bytes: usize = 64 * 1024,
};

/// 事件派发器，由宿主注入（null = 不派发事件）。
///
/// 用函数指针而不是直接 import host/events.zig：agent 层不该认识宿主内部类型
/// （而且 src/agent 本来就 import 不到 src/host —— 模块边界），测试里也能塞一个
/// 记录用的假派发器。签名与 abi.EmitFn 同形，所以 main 里直接写
/// `Context.apiEmit` 就行。
pub const Dispatcher = struct {
    ctx: *anyopaque,
    call: *const fn (
        ctx: *anyopaque,
        payload: *abi.EventPayload,
        mode: abi.DispatchMode,
    ) callconv(.c) abi.Status,
};

pub const Loop = struct {
    gpa: std.mem.Allocator,
    /// 会话级 arena：历史里的字符串活到这里
    session_arena: std.mem.Allocator,
    io: std.Io,
    client: *llm.Client,
    session: *llm.Session,
    /// 工具表服务（来自工具插件；测试里由 builtinIface 包一份宿主内的表）
    tools_iface: *const tool_api.ToolsIface,
    /// 会话日志（可为 null：记录不是硬依赖）
    log: ?*session_log.Log = null,
    /// 事件派发器（可为 null：不派发事件）
    dispatcher: ?Dispatcher = null,
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
        tools_iface: *const tool_api.ToolsIface,
        log: ?*session_log.Log,
        dispatcher: ?Dispatcher,
        cfg: Config,
    ) !Loop {
        // 工具清单与 system 提示只组装一次 —— 它们在一次会话里不会变。
        // 工具清单是从工具表现读的：宿主并不知道里面有什么。
        const tools_json = try tools.jsonSpec(session_arena, tools_iface);
        const system_prompt = try buildSystemPrompt(session_arena, io, dir);

        const self = Loop{
            .gpa = gpa,
            .session_arena = session_arena,
            .io = io,
            .client = client,
            .session = session,
            .tools_iface = tools_iface,
            .log = log,
            .dispatcher = dispatcher,
            .tools_json = tools_json,
            .system_prompt = system_prompt,
            .cfg = cfg,
            .tool_buf = try gpa.alloc(u8, cfg.tool_output_bytes),
        };

        // system 消息也要落到日志里：复盘时得知道当时到底喂了什么
        if (self.log) |lg| {
            lg.appendMessage(.{ .role = .system, .content = system_prompt }, 0, 0);
        }
        return self;
    }

    pub fn deinit(self: *Loop) void {
        self.gpa.free(self.tool_buf);
    }

    /// 跑完一轮用户输入。返回后 Session 里已经记录了这一轮的全部往返。
    pub fn runTurn(self: *Loop, user_text: []const u8) !void {
        try self.record(.{
            .role = .user,
            .content = try self.session_arena.dupe(u8, user_text),
        }, 0, 0);

        var round: u32 = 0;
        while (round < self.cfg.max_rounds) : (round += 1) {
            // 每轮一个临时 arena：请求体、工具参数这些用完就丢
            var turn = std.heap.ArenaAllocator.init(self.gpa);
            defer turn.deinit();
            const ta = turn.allocator();

            // 请求前给插件一个「注入额外上下文」的机会（agent/request 的 waterfall）。
            // 没有监听器时整条链就是空转，开销等于一次函数调用 —— 不必先问有没人听。
            var inject_buf: [8 * 1024]u8 = undefined;
            var injected: []const u8 = &.{};
            if (self.dispatcher) |d| {
                const info = try std.fmt.allocPrintSentinel(ta, "{{\"messages\":{d}}}", .{
                    self.session.messages.items.len,
                }, 0);
                var p = abi.EventPayload{
                    .name = abi.EventNames.agent_request,
                    .json = info.ptr,
                    .out_ptr = &inject_buf,
                    .out_cap = inject_buf.len,
                };
                _ = d.call(d.ctx, &p, .waterfall);
                injected = p.out();
            }

            const done = try self.client.complete(ta, self.session, self.tools_json, injected);

            if (done.text.len > 0) std.debug.print("{s}\n", .{done.text});

            // assistant 这一轮同样要进历史，且 tool_calls 必须原样保留
            try self.record(.{
                .role = .assistant,
                .content = try self.session_arena.dupe(u8, done.text),
                .tool_calls = try self.keepToolCalls(done.tool_calls),
            }, done.prompt_tokens, done.completion_tokens);

            if (!done.wantsTools()) return;

            for (done.tool_calls) |call| {
                const result = try self.runTool(ta, call);
                try self.record(.{
                    .role = .tool,
                    .tool_call_id = try self.session_arena.dupe(u8, call.id),
                    .content = result,
                }, 0, 0);
            }
        }

        std.debug.print("[loop] 已达 {d} 轮上限，停止本轮（防模型反复调工具）\n", .{self.cfg.max_rounds});
    }

    /// 追加一条消息：进内存历史 + 落日志。所有消息都走这里，不会有只落一边的路径。
    fn record(
        self: *Loop,
        m: llm.Message,
        prompt_tokens: u64,
        completion_tokens: u64,
    ) !void {
        try self.session.append(m);
        if (self.log) |lg| lg.appendMessage(m, prompt_tokens, completion_tokens);
    }

    /// 执行一个工具调用，返回可长期保存（已拷进 session arena）的结果文本。
    ///
    /// ★ 这里**不出现任何工具名**：名字与参数原样交给工具表，由它去认。
    ///   「未知工具」也是它给出的回答（写在 out 里的一段文字”，loop 只负责搬运。
    ///
    /// 接了事件总线之后，一次调用会经过三个点：
    ///   ① tool/call（emit）       广播一声，只观察
    ///   ② tool/pre-execute（waterfall）包住「执行」：监听器能否决，能否决掉
    ///      整次调用；链尾默认行为才是真的执行（见 executeToolDefault）
    ///   ③ 没注入派发器时直接执行（事件总线不参与）
    fn runTool(self: *Loop, ta: std.mem.Allocator, call: llm.ToolCall) ![]const u8 {
        // 跨 ABI 的参数要 C 字符串
        const name_z = try ta.dupeZ(u8, call.name);
        const args_z = try ta.dupeZ(u8, call.arguments_json);

        var out = tools.Buffer{ .ptr = self.tool_buf.ptr, .cap = self.tool_buf.len, .len = 0 };
        var status: abi.Status = .ok;

        if (self.dispatcher) |d| {
            // ① 广播一声（改不了任何东西，它是通知）
            const info = try toolCallJson(ta, call);
            var call_payload = abi.EventPayload{
                .name = abi.EventNames.tool_call,
                .json = info.ptr,
            };
            _ = d.call(d.ctx, &call_payload, .emit);

            // ② waterfall 包住执行。链尾默认行为 = 真的执行这个工具。
            var action = ToolAction{
                .iface = self.tools_iface,
                .name_z = name_z.ptr,
                .args_z = args_z.ptr,
                .out = &out,
            };
            const info2 = try toolCallJson(ta, call);
            var exec_payload = abi.EventPayload{
                .name = abi.EventNames.tool_pre_execute,
                .json = info2.ptr,
                .out_ptr = self.tool_buf.ptr,
                .out_cap = self.tool_buf.len,
                .action_ctx = @ptrCast(&action),
                .default_action = executeToolDefault,
            };
            status = d.call(d.ctx, &exec_payload, .waterfall);

            // 否决时监听器可能什么都没写，而模型只能看到 out 里的文字 ——
            // 空结果会让它以为工具成功了。补一句原因。
            if (status != .ok and out.len == 0) {
                var w = out.writer();
                w.print("工具 {s} 被拒绝（{s}），没有执行", .{ call.name, @tagName(status) }) catch {};
                out.finish(&w);
            }
        } else {
            status = self.tools_iface.execute(
                self.tools_iface.impl,
                name_z.ptr,
                args_z.ptr,
                &out,
            );
        }

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

    /// 把一次工具调用编成事件载荷 JSON。
///
/// `arguments` 用**字符串**序列化（而不是把参数文本直接嵌进去）：模型给的参数
/// 不保证是合法 JSON，直接嵌会把整个载荷弄坏，而载荷一坏，后面所有监听器都遭殃。
fn toolCallJson(arena: std.mem.Allocator, call: llm.ToolCall) ![:0]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("{\"tool\":");
    try std.json.Stringify.value(call.name, .{}, w);
    try w.writeAll(",\"arguments\":");
    try std.json.Stringify.value(call.arguments_json, .{}, w);
    try w.writeAll("}");
    try w.writeByte(0);

    const all = aw.written();
    return all[0 .. all.len - 1 : 0];
}

/// tool/pre-execute 的链尾默认行为：真的去执行这个工具调用。
///
/// ★ **不支持「监听器改参数」**：参数在 action_ctx 里，而不是从 payload.json 重新
///   解析 —— 因为这是个 C 函数，没有分配器，解析 JSON 再转 C 字符串的代价与复杂
///   度都不值。监听器能做的是「否决」（不调 next）和「改写结果」（调完 next 再写 out）。
const ToolAction = struct {
    iface: *const tool_api.ToolsIface,
    name_z: [*:0]const u8,
    args_z: [*:0]const u8,
    out: *tools.Buffer,
};

fn executeToolDefault(payload: *abi.EventPayload) callconv(.c) abi.Status {
    const act: *ToolAction = @ptrCast(@alignCast(payload.action_ctx orelse return .err_internal));
    return act.iface.execute(act.iface.impl, act.name_z, act.args_z, act.out);
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
    tools_iface: tool_api.ToolsIface,
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
        // 单元测试用宿主内那份工具表包一个 iface，这样不必依赖
        // zig-out/lib/libtools.so 存在（插件路径由集成测试覆盖）。
        self.tools_iface = tools.builtinIface(&self.host);
        self.client = llm.Client.init(arena, .{}, "fake-key", replay.asTransport());
        // 参数是 *TestEnv 而不是返回值：Loop 里存的是 &self.client 这类指针，
        // TestEnv 一旦被拷贝（返回结构体值），这些指针就悬空了。
        self.loop = try Loop.init(
            gpa,
            arena,
            io,
            std.Io.Dir.cwd(),
            &self.client,
            &self.session,
            &self.tools_iface,
            null,
            null,
            .{},
        );
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

// ─────────────────────────────────────────────────────────────────────────
//  事件总线接入：tool/call、tool/pre-execute、agent/request
// ─────────────────────────────────────────────────────────────────────────

/// 测试用的派发器：记录收到的事件，可选地否决工具或注入上下文。
/// 它就是插件里那个监听器在宿主侧的等价形状 —— 同一套 ABI 签名。
const TestDispatcher = struct {
    seen: [8][]const u8 = undefined,
    n: usize = 0,
    /// true = 否决一切工具执行
    deny_tools: bool = false,
    /// 非空 = agent/request 时注入这段文本
    inject: []const u8 = "",

    fn call(
        ctx: *anyopaque,
        payload: *abi.EventPayload,
        mode: abi.DispatchMode,
    ) callconv(.c) abi.Status {
        const self: *TestDispatcher = @ptrCast(@alignCast(ctx));
        const name = std.mem.span(payload.name);
        if (self.n < self.seen.len) {
            self.seen[self.n] = name;
            self.n += 1;
        }

        return switch (mode) {
            .emit => .ok,
            .waterfall => blk: {
                if (std.mem.eql(u8, name, abi.EventNames.tool_pre_execute) and self.deny_tools) {
                    payload.setOut("被测试规则拒绝");
                    // 不调 default_action = 工具不会执行
                    break :blk .err_denied;
                }
                if (std.mem.eql(u8, name, abi.EventNames.agent_request) and self.inject.len > 0) {
                    payload.setOut(self.inject);
                }
                // 放行：链尾默认行为该跑就跑
                if (payload.default_action) |act| break :blk act(payload);
                break :blk .ok;
            },
            else => .ok,
        };
    }
};

test "接入事件总线：每轮发 agent/request，每次工具调用发 tool/call 与 tool/pre-execute" {
    var replay = llm.ReplayTransport{ .responses = &.{ round_with_tool_call, round_final }, .gpa = std.testing.allocator };
    defer replay.deinit();
    var env: TestEnv = undefined;
    try env.init(&replay);
    defer env.deinit();

    var disp = TestDispatcher{};
    env.loop.dispatcher = .{ .ctx = @ptrCast(&disp), .call = TestDispatcher.call };

    try env.loop.runTurn("帮我 echo 一下");

    // 顺序：第一轮请求前 -> 工具广播 -> 工具执行前 -> 第二轮请求前
    try std.testing.expectEqual(@as(usize, 4), disp.n);
    try std.testing.expectEqualStrings(abi.EventNames.agent_request, disp.seen[0]);
    try std.testing.expectEqualStrings(abi.EventNames.tool_call, disp.seen[1]);
    try std.testing.expectEqualStrings(abi.EventNames.tool_pre_execute, disp.seen[2]);
    try std.testing.expectEqualStrings(abi.EventNames.agent_request, disp.seen[3]);

    // 链尾默认行为真的执行了工具
    const msgs = env.session.messages.items;
    try std.testing.expect(std.mem.indexOf(u8, msgs[2].content, "hello-from-tool") != null);
}

test "权限门：监听器否决 -> 工具根本没执行，原因回给模型" {
    var replay = llm.ReplayTransport{ .responses = &.{ round_with_tool_call, round_final }, .gpa = std.testing.allocator };
    defer replay.deinit();
    var env: TestEnv = undefined;
    try env.init(&replay);
    defer env.deinit();

    var disp = TestDispatcher{ .deny_tools = true };
    env.loop.dispatcher = .{ .ctx = @ptrCast(&disp), .call = TestDispatcher.call };

    try env.loop.runTurn("帮我 echo 一下");

    const msgs = env.session.messages.items;
    try std.testing.expectEqual(@as(usize, 4), msgs.len);
    // 工具结果里是拒绝原因，**不是**命令输出 —— 说明它真的没跑
    try std.testing.expect(std.mem.indexOf(u8, msgs[2].content, "拒绝") != null);
    try std.testing.expect(std.mem.indexOf(u8, msgs[2].content, "hello-from-tool") == null);
    // 循环没被打断：模型仍然拿到了这一轮的答复
    try std.testing.expectEqualStrings("完成了", msgs[3].content);
}

test "agent/request：注入的上下文进了请求体，但不进会话历史" {
    var replay = llm.ReplayTransport{ .responses = &.{round_final}, .gpa = std.testing.allocator };
    defer replay.deinit();
    var env: TestEnv = undefined;
    try env.init(&replay);
    defer env.deinit();

    var disp = TestDispatcher{ .inject = "额外上下文-ABC" };
    env.loop.dispatcher = .{ .ctx = @ptrCast(&disp), .call = TestDispatcher.call };

    try env.loop.runTurn("你好");

    // 请求体里能看到注入的文本
    try std.testing.expect(std.mem.indexOf(u8, replay.last_request, "额外上下文-ABC") != null);
    // 但它没有沾污会话历史：下一轮重新组装请求时它不会重现
    for (env.session.messages.items) |m| {
        try std.testing.expect(std.mem.indexOf(u8, m.content, "额外上下文-ABC") == null);
    }
}
