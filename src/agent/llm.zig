//! ═══════════════════════════════════════════════════════════════════════════
//!  阶段 5 · LLM —— DeepSeek 客户端                     【草图 / 空壳】
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 为什么这个文件放在阶段 5，而不是阶段 1
//! ---------------------------------------------------------------------------
//!   它是**最容易验证**的部分：一个 HTTPS 请求 + JSON 解析。
//!   所以它适合当「第一个跑通的东西」（验证 Zig 0.16 的 Io / TLS / JSON
//!   三件事真实可用），但**不适合**当架构的起点。
//!   建议：写在阶段 5，但**实验可以提前做**——先拿它把网络通路验证掉，
//!   然后回到阶段 1 的框架主线，最后再把两者接起来。
//!
//! 关键事实（已核实的环境）
//! ---------------------------------------------------------------------------
//!   · 端点：https://api.deepseek.com/chat/completions（OpenAI 兼容）
//!   · 可用模型：deepseek-flash（便宜）、deepseek-v4-pro（强）
//!   · 密钥：环境变量 DEEPSEEK_API_KEY（已持久化）
//!   · TLS：需要 CA bundle（/etc/ssl/certs/ca-certificates.crt 存在）
//!     Zig 的 std.crypto.tls 支持 CA bundle 校验；若折腾不顺，
//!     备选是 @cImport libcurl（已装 8.22 + 头文件齐全）。
//!
//! ⚠️ 空壳。

const std = @import("std");

/// 一条对话消息（对应 OpenAI 的 message）。
pub const Message = struct {
    role: Role,
    /// 文本内容（assistant 发起工具调用时可能为空）
    content: []const u8 = "",
    /// 工具调用结果专用：对应哪个 tool_call
    tool_call_id: []const u8 = "",
    /// assistant 发起的工具调用列表
    tool_calls: []const ToolCall = &.{},

    pub const Role = enum { system, user, assistant, tool };
};

/// 模型请求的一次工具调用。
pub const ToolCall = struct {
    /// 模型给的调用 id，回传结果时要用它对应
    id: []const u8,
    name: []const u8,
    /// 参数 JSON 文本（**模型可能给出非法 JSON**，必须容错）
    arguments_json: []const u8,
};

/// 会话：agent 的完整可见上下文。
///
/// ★ 一条重要原则（来自 dsh 的设计）：「模型可见即已记录」。
///   凡是喂给模型的东西都必须能从会话日志重建。
///   草图先用纯内存 list；持久化留到需要时再加。
pub const Session = struct {
    gpa: std.mem.Allocator,
    messages: std.ArrayList(Message),

    pub fn init(gpa: std.mem.Allocator) Session {
        _ = gpa;
        @panic("TODO: 阶段 5 —— 初始化空会话");
    }

    pub fn deinit(self: *Session) void {
        _ = self;
        @panic("TODO: 阶段 5");
    }

    pub fn append(self: *Session, m: Message) !void {
        _ = self;
        _ = m;
        @panic("TODO: 阶段 5 —— 追加消息（同时登记到日志）");
    }
};

/// 模型的一次回复。
pub const Completion = struct {
    /// 文本回复（可能为空）
    text: []const u8 = "",
    /// 如果模型要求调用工具，这里是列表
    tool_calls: []const ToolCall = &.{},
    /// 结束原因："stop" / "tool_calls" / "length" ……
    finish_reason: []const u8 = "",
    /// token 用量（用于成本观察）
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
};

/// 客户端配置。
pub const Config = struct {
    base_url: []const u8 = "https://api.deepseek.com",
    model: []const u8 = "deepseek-flash",
    /// 从环境变量读，别硬编码（也不要写进任何文件）
    api_key_env: []const u8 = "DEEPSEEK_API_KEY",
    /// 单次请求上限
    max_tokens: u32 = 8192,
    /// 采样温度
    temperature: f32 = 0.0,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    /// std.http.Client 实例（0.16 里 I/O 走 Io）
    http: ?*anyopaque = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cfg: Config) Client {
        _ = gpa;
        _ = io;
        _ = cfg;
        @panic("TODO: 阶段 5 —— 建 std.http.Client（含 CA bundle）");
    }

    pub fn deinit(self: *Client) void {
        _ = self;
        @panic("TODO: 阶段 5");
    }

    /// 组装请求体 JSON。
    ///
    /// 要带上：
    ///   · model / messages
    ///   · tools（把 ctx.tools 里的工具描述转成 OpenAI 的 tools 数组）
    ///   · tool_choice: "auto"
    ///
    /// 直接用 std.json 手工构造（或写一个小的 JSON writer），
    /// 不引入第三方库。
    pub fn buildRequest(self: *Client, session: *const Session, tools_json: []const u8, out: *std.ArrayList(u8)) !void {
        _ = self;
        _ = session;
        _ = tools_json;
        _ = out;
        @panic("TODO: 阶段 5 —— 拼 JSON 请求体");
    }

    /// 发请求并解析回复。
    ///
    /// 注意几个真实的坑（dsh 的源码里都处理过）：
    ///   · 网络可能中途断流 → 需要超时
    ///   · 返回的 arguments 可能不是合法 JSON → 要容错并回报给模型
    ///   · 限流/5xx → 需要退避重试（草图先不实现）
    pub fn complete(self: *Client, session: *const Session, tools_json: []const u8, arena: std.mem.Allocator) !Completion {
        _ = self;
        _ = session;
        _ = tools_json;
        _ = arena;
        @panic("TODO: 阶段 5 —— POST → 解析 choices[0] → 得到 Completion");
    }
};

/// 模型目录（本账号网关实测只提供这两个）。
pub const known_models = [_][]const u8{ "deepseek-flash", "deepseek-v4-pro" };
