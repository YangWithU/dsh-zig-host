//! ═══════════════════════════════════════════════════════════════════════════
//!  阶段 5 · Agent Loop —— 主循环                        【草图 / 空壳】
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 一个 agent 的骨架只有三条线：
//!
//!      用户输入
//!         │
//!         ▼
//!   ┌─→ ① 组装 messages → 发请求 → 解析回复
//!   │        │
//!   │        ├─ 模型要求调工具 ──→ ② 执行工具 → 结果当 tool 消息追加 ─┐
//!   │        │                                                        │
//!   │        └─ 模型给了文本   ──→ 打印，本轮结束                      │
//!   └────────────────────────────────────────────────────────────────┘
//!
//!   （图里出现「轮次/步骤」的分层：一次请求 + 它触发的工具 = 一个**步骤**；
//!     一个**轮次**包含零个或多个步骤。dsh 的生命周期事件就是按这个分的，
//!     草图里先不过度建模，只需知道这个区分存在。）
//!
//! ★ 为什么这套东西要放在最后写
//! ---------------------------------------------------------------------------
//!   它是**串行**的：请求 → 工具 → 请求，天然不需要并发。
//!   所以它可以先把「框架」放在一边，用最土的方式跑通；
//!   等框架（阶段 1–4）就位后，再把循环里的每个动作换成
//!   「发事件 → 各插件有机会拦截/改写」。
//!
//!   这条路径的收益：你会在写框架之前就知道它的调用点长什么样，
//!   从而避免设计出一堆猜错形状的抽象。
//!
//! ⚠️ 空壳。

const std = @import("std");
const llm = @import("llm.zig");
const abi = @import("dsh_abi");

/// 循环的依赖：客户端 + 工具查询能力 + 事件总线。
///
/// 注意这里是**用接口而不是具体类型**：一旦接上阶段 2/3，
/// 工具和事件都通过 ctx 取，循环本身不认识任何具体插件。
pub const Deps = struct {
    client: *llm.Client,
    /// 取工具表（对应 ctx.getService("tools")）
    get_tools: *const fn (ctx: *anyopaque) callconv(.c) ?*const anyopaque,
    /// 分发事件（对应 ctx.emit / ctx.waterfall）
    emit: *const fn (ctx: *anyopaque, payload: *const abi.EventPayload) callconv(.c) void,
    ctx: *anyopaque,
};

/// 一次工具调用的执行结果。
pub const ToolResult = struct {
    call_id: []const u8,
    ok: bool,
    output: []const u8,
};

pub const Loop = struct {
    arena: std.mem.Allocator,
    deps: Deps,
    session: llm.Session,
    /// 防止模型陷入「调工具 → 再调同一个工具」的死循环
    max_steps: u32 = 32,

    pub fn init(arena: std.mem.Allocator, deps: Deps, session: llm.Session) Loop {
        _ = arena;
        _ = deps;
        _ = session;
        @panic("TODO: 阶段 5 —— 初始化");
    }

    /// 跑一个完整轮次：反复「请求 → 执行工具」直到模型不再要求调工具。
    ///
    /// ★ 扩展点就位后，这里会插进若干 intercept 机会：
    ///     · agent/pre-step      —— 决定接纳哪些输入（可拒绝）
    ///     · agent/request       —— 发请求前改写消息（waterfall，可否决）
    ///     · tool/pre-execute     —— 工具执行前把关（可拒绝某次调用）
    ///     · tool/post-execute    —— 结果返回后加工
    ///   草图先把它们标在注释里，实现阶段逐个接上。
    pub fn runTurn(self: *Loop, user_input: []const u8) !void {
        _ = self;
        _ = user_input;
        @panic("TODO: 阶段 5 —— 追加用户消息 → 循环请求/执行工具 → 直到无工具调用");
    }

    /// 执行一批工具调用（模型可能一次要求多个）。
    ///
    /// 关键点：
    ///   · 按名字从工具表找到实现，找不到就回一条「工具不存在」给模型
    ///     （**不要**直接失败——让模型有机会自己纠正）
    ///   · 每个结果的输出都要截断（否则一次大输出就撑爆上下文）
    ///   · 异常一律转成 tool 消息文本回给模型，而不是让进程崩
    pub fn executeTools(self: *Loop, calls: []const llm.ToolCall) ![]ToolResult {
        _ = self;
        _ = calls;
        @panic("TODO: 阶段 5 —— 逐个派发到工具实现，收集结果");
    }

    /// 单次工具派发：查表 → 调 iface → 包装结果。
    pub fn dispatchOne(self: *Loop, call: llm.ToolCall) ToolResult {
        _ = self;
        _ = call;
        @panic("TODO: 阶段 5 —— getService('tools') → find(name) → 调 execute");
    }
};
