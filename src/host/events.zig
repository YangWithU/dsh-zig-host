//! ═══════════════════════════════════════════════════════════════════════════
//!  阶段 3 · Events —— 事件总线                        【草图 / 空壳】
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 事件是「不产生编译期依赖的协作方式」：发布者不需要知道谁在听。
//! 在 agent 场景里，这是拦截/改写请求、附加策略的主要手段。
//!
//! 五种分发模式（对应 Cordis）
//! ---------------------------------------------------------------------------
//!   emit       广播，不等返回值          —— 通知
//!   parallel   全部并发，等全部完成       —— 扇出
//!   bail       按序，遇第一个非空返回即停  —— 短路
//!   serial     bail 的异步版             —— 顺序短路
//!   waterfall  环绕中间件（见下）         —— 拦截改写 ★最重要
//!
//! ★ waterfall 是整套扩展点的核心
//! ---------------------------------------------------------------------------
//!   监听器签名是 (...args, next)：
//!       调用 next()  → 交给下一个监听器（最后是内置默认行为）
//!       不调 next()  → **否决**，后面的监听器和默认行为都不执行
//!   返回值沿 next() 一层层向外包装。
//!
//!   对应到 agent：
//!       agent/request  = waterfall → 可以在发请求前改写 messages
//!       tool/pre-execute = waterfall → 可以拒绝或改写工具调用
//!
//! ⚠️ 草图建议：**先只实现 emit 与 waterfall**，覆盖绝大多数用法；
//!    parallel/bail/serial 留接口，等真实需要时再补（避免过早设计）。
//!
//! ⚠️ 跨 ABI 的现实约束
//! ---------------------------------------------------------------------------
//!   C ABI 下无法像 JS 那样传任意参数列表。草图选择：
//!     载荷统一为 JSON 字符串（abi.EventPayload），
//!     waterfall 的「改写结果」通过可变的载荷缓冲区回传。
//!   跑通之后再针对高频事件做结构化（extern struct）优化。
//!
//! ⚠️ 空壳。

const std = @import("std");
const abi = @import("dsh_abi");
const fiber_mod = @import("fiber.zig");

/// 一条监听记录。
pub const Listener = struct {
    /// 事件名
    event: []const u8,
    mode: abi.DispatchMode,
    cb: abi.Callback,
    /// 谁注册的 —— 卸载时据此撤销（撤销必须在 dlclose 之前！）
    owner: *fiber_mod.Fiber,
    /// prepend=true 时插到队首（少数需要抢在最前执行的策略用它）
    prepend: bool = false,
    /// 便于撤销时定位（用于从列表中摘除自己）
    generation: u32 = 1,
};

/// 事件总线。
pub const Bus = struct {
    gpa: std.mem.Allocator,
    /// 事件名 → 监听器列表（按注册顺序）。
    listeners: std.StringHashMap(std.ArrayList(Listener)),

    /// 关闭「递归分发」的护栏。事件处理里再发同类事件容易写出无限递归，
    /// 这里用一个深度计数挡住（JS 里靠栈溢出才发现，Zig 里直接崩）。
    depth: u32 = 0,
    max_depth: u32 = 32,

    pub fn init(gpa: std.mem.Allocator) Bus {
        _ = gpa;
        @panic("TODO: 阶段 3 —— 初始化空表");
    }

    pub fn deinit(self: *Bus) void {
        _ = self;
        @panic("TODO: 阶段 3");
    }

    /// 注册监听。
    ///
    /// ★ 宿主侧还必须把「撤销这条监听」登记进 owner fiber 的撤销清单，
    ///   两步成对。否则插件卸载后监听还在 → 段错误。
    pub fn on(self: *Bus, l: Listener) abi.Handle {
        _ = self;
        _ = l;
        @panic("TODO: 阶段 3 —— 入表（按 prepend 决定位置）");
    }

    /// 撤销监听（由 fiber 的撤销清单调用）。
    pub fn off(self: *Bus, h: abi.Handle) abi.Status {
        _ = self;
        _ = h;
        @panic("TODO: 阶段 3 —— 从列表摘除 + 使 generation 失效");
    }

    /// 广播：同步调用所有监听器，忽略返回值。
    pub fn emit(self: *Bus, payload: *const abi.EventPayload) void {
        _ = self;
        _ = payload;
        @panic("TODO: 阶段 3 —— 逐个调用，吞掉监听器的错误（不能让它炸掉发布者）");
    }

    /// 环绕中间件。
    ///
    /// `next` 是「剩余链条」的延续。草图用一个显式索引表达：
    ///     调用方传 next 回调；链上每个监听器收到同一个 next，
    ///     由总线推进索引。Cordis 用 JS 闭包递归，Zig 用索引迭代。
    ///
    /// 返回 false 表示被某层否决（未调用 next）。
    pub fn waterfall(self: *Bus, payload: *abi.EventPayload, next: *const fn () callconv(.c) void) bool {
        _ = self;
        _ = payload;
        _ = next;
        @panic("TODO: 阶段 3 —— 索引推进式环绕分发，支持否决");
    }

    /// 并发分发：全部跑完，等齐，失败聚合上报。
    /// （Zig 里用 Io / 线程池；草图先留签名。agent 主循环是串行的，
    ///   所以这个模式优先级最低。）
    pub fn parallel(self: *Bus, payload: *const abi.EventPayload, io: std.Io) void {
        _ = self;
        _ = payload;
        _ = io;
        @panic("TODO: 阶段 3（按需）—— 并发分发 + 错误聚合");
    }
};

/// dsh 风格的事件名常量。
///
/// 用常量而非散落字符串：拼错事件名是最难查的一类 bug
/// （Cordis 靠 TS 声明合并 + 生成的目录做交叉校验，Zig 里靠常量）。
pub const Names = struct {
    pub const tool_call = "tool/call";
    pub const tool_pre_execute = "tool/pre-execute";
    pub const tool_post_execute = "tool/post-execute";
    pub const agent_request = "agent/request";
    pub const llm_stream = "llm/stream";
    pub const session_event = "session/event";
};
