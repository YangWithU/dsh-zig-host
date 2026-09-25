//! ═══════════════════════════════════════════════════════════════════════════
//!  dsh_zig —— Zig 版 Cordis 内核 + 最小 agent
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 当前进度：**MVP 优先**。插件机制（阶段 1–4）仍是空壳，先把能跑的东西做出来。
//!
//!     dsh_zig                                   REPL：与模型对话，模型可调四个工具
//!     dsh_zig "帮我看看 xxx"                    单轮提问
//!     dsh_zig --tool bash '{"command":"ls"}'    直接调一个工具（不联网，用于验证）
//!
//! 为什么先做 MVP 而不是先做插件：
//!   · 网络通路与 agent 循环是「只能靠真跑才知道」的风险，必须提前消掉
//!     （Zig 0.16 的 HTTP/TLS/文件/进程 API 与所有 0.11–0.15 教程都不兼容）；
//!   · 工具四件套本身就是将来第一个真实插件，用它来验插件机制比造 mock 强。
//!
//! 五阶段与文件
//!   阶段 1  动态装卸闭环  host/fiber.zig   host/loader.zig   plugins/hello.zig
//!   阶段 2  服务表+依赖门 host/services.zig
//!   阶段 3  事件总线      host/events.zig
//!   阶段 4  热重载闭环    host/hotreload.zig
//!   阶段 5  agent+四工具  agent/llm.zig  agent/loop.zig  agent/tools.zig
//!   装配                  host/context.zig（阶段 1–3）、本文件
//!
//! 插件装配路径见文件末尾 `runWithPlugins`：故意不调用（理由见其注释）。

const std = @import("std");
const abi = @import("dsh_abi");
const Context = @import("host/context.zig").Context;
const hotreload = @import("host/hotreload.zig");
const tools = @import("agent/tools.zig");
const context_files = @import("agent/context_files.zig");
const llm = @import("agent/llm.zig");
const loop_mod = @import("agent/loop.zig");

pub fn main(init: std.process.Init) !void {
    // 进程级 arena：活到进程结束的东西放这里
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = init.minimal.args.toSlice(gpa) catch &.{};

    // ── dsh_zig --tool <名字> '<json 参数>' ────────────────────────────────
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--tool")) {
        const json: []const u8 = if (args.len >= 4) args[3] else "{}";
        try runToolCli(gpa, io, args[2], json);
        return;
    }

    // ── dsh_zig --context   打印启动时会注入 system 消息的规范文本 ─────────
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--context")) {
        try runContextCli(gpa, io);
        return;
    }

    // ── dsh_zig "问题" → 跑一轮；dsh_zig → 进 REPL ────────────────────────
    //   以 - 开头的参数留给选项，否则当成一句提问。
    if (args.len >= 2 and args[1].len > 0 and args[1][0] != '-') {
        try runAgent(gpa, io, init.environ_map, args[1]);
        return;
    }
    try runAgent(gpa, io, init.environ_map, null);
}

/// 建好「客户端 + 工具 + 循环」，然后要么跑一轮提问，要么进交互式 REPL。
///
/// 两件事共用同一套装配，因为它们的区别只在于「输入从哪儿来」：
/// 命令行参数给一次，或者从 stdin 反复读。
fn runAgent(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    once: ?[]const u8,
) !void {
    const key = env.get("DEEPSEEK_API_KEY") orelse {
        std.debug.print(
            "缺少环境变量 DEEPSEEK_API_KEY。\n" ++
                "本机已经在 shell 配置里设好；若在新终端里失效，先确认它已导出。\n",
            .{},
        );
        return error.NoApiKey;
    };

    // 会话级 arena：历史里的字符串活到 REPL 结束
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var http = llm.HttpTransport.init(gpa, io);
    defer http.deinit();
    var client = llm.Client.init(gpa, .{}, key, http.asTransport());

    var session = llm.Session.init(gpa);
    defer session.deinit();

    // 工具内部用的临时分配器，每次调用前不重置也没关系（arena 会一直涨到会话结束）
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    var host = tools.Host{
        .gpa = gpa,
        .scratch = scratch_state.allocator(),
        .io = io,
        .dir = std.Io.Dir.cwd(),
    };

    var lp = try loop_mod.Loop.init(gpa, arena, io, std.Io.Dir.cwd(), &client, &session, &host, .{});
    defer lp.deinit();

    if (once) |text| {
        lp.runTurn(text) catch |e| std.debug.print("[错误] {s}\n", .{@errorName(e)});
        return;
    }

    std.debug.print(
        \\dsh_zig REPL。可用工具：read / write / edit / bash。
        \\直接描述你想做的事；输入 exit 或 Ctrl-D 退出。
        \\
    , .{});

    var stdin_buf: [8192]u8 = undefined;
    var file_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    while (true) {
        std.debug.print("\n> ", .{});
        // null = 输入结束（Ctrl-D / 管道读完）
        const line = (try file_reader.interface.takeDelimiter('\n')) orelse break;
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0) continue;
        if (std.mem.eql(u8, text, "exit") or std.mem.eql(u8, text, "quit")) break;

        // text 指向 reader 的内部缓冲区（下次读就失效），runTurn 会先拷走
        lp.runTurn(text) catch |e| std.debug.print("[错误] {s}\n", .{@errorName(e)});
    }
    std.debug.print("\n再见。\n", .{});
}

/// 打印启动时会作为第一条 system 消息注入的规范文本。
/// 单猬一个入口是为了能脱离 LLM 验证「找到了哪些文件、拼成了什么样」。
fn runContextCli(gpa: std.mem.Allocator, io: std.Io) !void {
    const entries = try context_files.collect(gpa, io, std.Io.Dir.cwd());

    if (entries.len == 0) {
        std.debug.print("未找到任何 AGENTS.md（从工作目录向上逐级查找）\n", .{});
        return;
    }

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try context_files.render(&aw.writer, entries);

    std.debug.print("命中 {d} 个文件：\n", .{entries.len});
    for (entries) |e| std.debug.print("  {s}  ({d} 字节)\n", .{ e.path, e.content.len });
    std.debug.print("\n---- 注入内容预览 ----\n{s}\n", .{aw.written()});
}

/// 直接调用一个工具并打印结果。**不联网、不花钱**，专门用来独立验证四件套。
///
/// 存在的意义：工具的正确性不该等到 LLM 接上才能验证 —— 那会把两类错误
/// （工具写错了 / 接线接错了）混在一起，最难查。
fn runToolCli(gpa: std.mem.Allocator, io: std.Io, name: []const u8, args_json: []const u8) !void {
    const t = tools.find(name) orelse {
        std.debug.print("未知工具：{s}（可用：read / write / edit / bash）\n", .{name});
        return;
    };

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    var host = tools.Host{
        .gpa = gpa,
        .scratch = scratch.allocator(),
        .io = io,
        .dir = std.Io.Dir.cwd(),
    };

    const buf = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(buf);
    var out = tools.Buffer{ .ptr = buf.ptr, .cap = buf.len };

    // 命令行给的是 Zig 风格的 slice，工具签名要 [*:0]const u8（将来跨 ABI 的形态）
    const args_z = try gpa.dupeZ(u8, args_json);
    defer gpa.free(args_z);

    const status = t.exec(&host, args_z.ptr, &out);
    std.debug.print("[{s} -> {s}]\n{s}", .{ name, @tagName(status), out.slice() });
}

/// 插件装配路径（阶段 1–4 的产物在这里被缝到一起）。
///
/// MVP 阶段故意不调用：Context.init 等仍是 @panic("TODO")，调它必崩。
/// 留在这里是为了让「宿主 -> 插件 -> agent」的装配关系不丢，等阶段 1–3
///    实现后由 main 按开关切回来；届时 agent 循环直接复用 MVP 的 loop。
fn runWithPlugins(gpa: std.mem.Allocator, io: std.Io) !void {
    // ── 装配宿主（阶段 1–3 的产物在这里被缝到一起） ───────────────────────
    var ctx = Context.init(gpa, io);
    defer ctx.deinit();

    // ── 阶段 1：挂一个插件，验证装卸闭环 ─────────────────────────────────
    //   内置插件：路径为 null，代码编译进宿主
    //   外部插件：指向 .so，运行时 dlopen（产物名带指纹，见 hotreload.PluginSpec）
    const tools_plugin = try ctx.mountPlugin("zig-out/lib/libtools.so", "{}");
    defer ctx.unmountPlugin(tools_plugin);

    // ── 阶段 4：热重载监视 ───────────────────────────────────────────────
    //   每轮：poll → compile（新文件名）→ inspect → 拆旧 → 装新 → 重放依赖
    var watcher = hotreload.Watcher.init(gpa, &.{"src/plugins"});
    var spec = hotreload.PluginSpec{
        .source_path = "src/plugins/tools.zig",
        .output_path = "zig-out/lib/libtools.so",
        .current = tools_plugin,
    };
    const report = hotreload.reloadOnce(&watcher, &spec, io);
    _ = report; // ReloadReport.outcome 里有 ok/compile_failed/... 供上层决策
}

/// 编译插件 .so 的命令行（阶段 4 会 fork/exec 它）。
///
/// 实测要点：
///   · `-dynamic` 生成 .so；**必须 -lc**：不链 libc 时 Linux 走 Zig 自带的
///     ElfDynLib，动态加载会段错误
///   · **必须显式写模块映射**（--dep / -Mroot / -Mdsh_abi）：`dsh_abi` 是构建图
///     里的名字，命令行不带映射会直接报
///     「no module named 'dsh_abi' available within module」
///     （原草稿那条 `--name {name} {source}` 就是这么失败的，已核实）
///   · {output} 带版本/指纹，且**不覆盖**已加载的旧文件
///   · 相对路径按当前工作目录解析，调用时要把 cwd 设成仓库根
pub const PLUGIN_BUILD_CMDLINE =
    "zig build-lib -dynamic -lc --dep dsh_abi -Mroot={source} " ++
    "-Mdsh_abi=src/abi.zig --name {name} -femit-bin={output}";

comptime {
    // 编译期断言：契约表里的字段数量/顺序一旦被误改，这里立刻报错。
    // （ABI 是双方共享的冻结面，改动必须是有意识的。）
    std.debug.assert(@sizeOf(abi.Handle) == 16);
    std.debug.assert(abi.ABI_VERSION == 1);
}
