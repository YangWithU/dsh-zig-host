//! ═══════════════════════════════════════════════════════════════════════════
//!  dsh_zig —— 用 Zig 复刻 Cordis 内核 + 最小 agent    【草图 / 空壳】
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 这个文件是**骨架的骨架**：它把五个阶段串成一条调用链，让整个设计
//! 的结构一眼可见。所有被调用的函数都是 TODO 占位，跑起来会 panic，
//! 但**类型检查是通过的** —— 这本身就验证了各模块之间的契约成立。
//!
//! 五阶段与文件对应
//! ---------------------------------------------------------------------------
//!   阶段 1  动态装卸闭环      src/host/fiber.zig      src/host/loader.zig
//!            abi 契约          src/abi.zig           src/plugins/hello.zig
//!   阶段 2  服务表 + 依赖门   src/host/services.zig
//!   阶段 3  事件总线          src/host/events.zig
//!   阶段 4  热重载闭环        src/host/hotreload.zig
//!   阶段 5  agent + 四工具    src/agent/llm.zig      src/agent/loop.zig
//!            src/plugins/tools.zig
//!   装配     宿主门面         src/host/context.zig
//!
//! 主线（记住这一条就够了）
//! ---------------------------------------------------------------------------
//!   建宿主 ctx  →  挂插件(.so)  →  插件注册服务/监听  →  agent 跑轮次
//!                    ↑                                      │
//!                    └──── 源码变了就重新编译并热替换 ←───────┘
//!
//! ⚠️ 这是草图。所有函数体是 @panic("TODO")，不含实现。

const std = @import("std");
const abi = @import("dsh_abi");
const Context = @import("host/context.zig").Context;
const loader = @import("host/loader.zig");
const hotreload = @import("host/hotreload.zig");
const llm = @import("agent/llm.zig");
const agent_loop = @import("agent/loop.zig");

pub fn main(init: std.process.Init) !void {
    // 进程级 arena：活到进程结束的东西放这里
    const gpa = init.arena.allocator();
    const io = init.io;

    // ── 装配宿主（阶段 1–3 的产物在这里被缝到一起） ───────────────────────
    var ctx = Context.init(gpa, io);
    defer ctx.deinit();

    // ── 阶段 1：挂一个内置/外部插件，验证装卸闭环 ────────────────────────
    //   内置插件：路径为 null，代码编译进宿主
    //   外部插件：指向 .so，运行时 dlopen
    //   （路径对应 build.zig 里 addLibrary 的产物：zig-out/lib/lib<name>.so）
    const tools_plugin = try ctx.mountPlugin("zig-out/lib/libtools.so", "{}");
    defer ctx.unmountPlugin(tools_plugin);

    // ── 阶段 5：建 agent 循环 ────────────────────────────────────────────
    var client = llm.Client.init(gpa, io, .{});
    defer client.deinit();

    var session = llm.Session.init(gpa);
    defer session.deinit();

    var loop = agent_loop.Loop.init(gpa, .{
        .client = &client,
        .get_tools = &Context.cGetTools,
        .emit = &Context.cEmit,
        .ctx = ctx.handle(),
    }, session);

    // ── 主流程：跑一个轮次 ───────────────────────────────────────────────
    const args = init.minimal.args.toSlice(gpa) catch &.{};
    const prompt: []const u8 = if (args.len > 1) args[1] else "hello";
    try loop.runTurn(prompt);

    // ── 阶段 4：进入热重载监视循环（可选，用 --watch 开启） ───────────────
    //   每轮：poll 源码变化 → 重新编译 → 撤销旧注册 → dlopen 新实现
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
