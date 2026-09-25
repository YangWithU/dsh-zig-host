//! ═══════════════════════════════════════════════════════════════════════════
//!  ABI —— 宿主与插件之间的唯一契约面        【草图 / 空壳，不含实现】
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 为什么需要这个文件（基调之一：边界必须冻结）
//! ---------------------------------------------------------------------------
//! Zig 没有稳定 ABI。插件是独立编译的 .so，所以两边**绝不能**直接传递 Zig
//! 类型（slice、error union、泛型、arena、带 tag 的 enum……）。本文件把一切
//! 跨边界的东西限制在 C ABI 上：
//!
//!     extern struct    固定内存布局
//!     callconv(.c)     固定调用约定
//!     [*:0]const u8    C 字符串（有结尾零，C 侧可直接用）
//!     整数 / 裸指针     值语义明确
//!
//! 四条契约规则（违反 = 段错误或静默数据损坏）
//! ---------------------------------------------------------------------------
//!   1. 插件**只能**通过 HostApi 触达宿主，不许直接链接宿主符号。
//!   2. 跨边界**不抛 error**，只传 Status 返回码。
//!      （Zig 的 error union 跨编译单元不安全；插件 panic 会连锁杀掉宿主）
//!   3. 跨边界的内存一律由宿主提供（见 HostApi.alloc），谁的生命周期长谁负责。
//!   4. ABI 一旦变更必须递增 ABI_VERSION；加载时校验，不一致直接拒绝。
//!
//! 对应 Cordis 的哪些概念
//! ---------------------------------------------------------------------------
//!     HostApi    ≈  ctx（插件能触及的全部能力）
//!     Handle     ≈  ctx.on()/ctx.provide() 返回的 disposer（可跨边界传的形式）
//!     Status     ≈  替代 JS 异常
//!     ServiceIface ≈ Cordis 里服务对象的 vtable（每个服务自定义）
//!
//! ⚠️ 本文件是空壳：函数指针字段是契约声明，没有实现体。

const std = @import("std");

/// ABI 版本。宿主与插件必须一致，否则加载被拒绝（第一道防线）。
pub const ABI_VERSION: u32 = 1;

/// 跨边界统一返回码。**绝不跨边界抛 Zig error。**
pub const Status = enum(c_int) {
    ok = 0,
    err_invalid_arg = 1,
    err_abi_mismatch = 2,
    err_no_service = 3,
    err_duplicate = 4,
    err_oom = 5,
    err_not_found = 6,
    err_internal = 7,
};

/// 注册句柄。**id 由宿主分配，注册时返回给注册方。**
///
/// ★ 撤销一律按 id 定位，**不按名字**：同一个插件可以对同一事件注册多个
///   监听，也可以在不同 scope 注册同名服务 —— 按名字撤销必然撤错行。
///   ⇒ 宿主每个注册条目占一个稳定编号，撤销项里存的就是这个编号。
///
/// 为什么要 generation：卸载后旧的句柄仍然可能被插件握在手里，
/// 只用 id 会误命中「重新加载后复用了同一 id」的新注册（ABA 问题）。
/// 撤销时递增 generation，旧句柄自然失效。
///
/// 编号在同一个 fiber 存续期内不复用；fiber 销毁后它那批编号整体作废。
pub const Handle = extern struct {
    id: u64 = 0,
    generation: u32 = 0,
};
pub const INVALID_HANDLE: Handle = .{};

pub const LogLevel = enum(c_int) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

/// 事件载荷：用一个 JSON 字符串充当通用载体。
///
/// 权衡说明：结构化（extern struct 逐字段声明）类型安全但每加一种事件就要改
/// ABI；JSON 字符串弱类型但零 ABI 变更代价。草图阶段选后者，跑通后再针对
/// 热点事件结构化。
pub const EventPayload = extern struct {
    /// 事件名，如 "tool/call"
    name: [*:0]const u8,
    /// 事件数据（JSON 文本）
    json: [*:0]const u8,
};

/// 事件监听回调。
///
/// `host_ctx` 是宿主上下文句柄（插件原样回传，用来反查自己是哪个 fiber）。
/// 注意：这是**函数指针**，一旦宿主卸载了插件代码而没撤销这个监听，
/// 再触发就是段错误（实测过）。所以撤销必须在 dlclose 之前完成。
pub const Callback = *const fn (host_ctx: *anyopaque, payload: *const EventPayload) callconv(.c) void;

/// 事件分发模式（对应 Cordis 的 5 种）。
///
/// 草图里先把枚举位留出来；实现阶段建议**先只做 emit 和 waterfall**
/// （事件的绝大多数用法），其余按需补。
pub const DispatchMode = enum(c_int) {
    emit = 0, // 广播，不等待，无返回值
    parallel = 1, // 全部并发，等待全部完成
    bail = 2, // 按序，遇第一个非空返回值即停
    serial = 3, // bail 的异步版
    waterfall = 4, // 环绕中间件：监听器收到 next，不调 next 即否决
};

// ───────────────────────────────────────────────────────────────────────────
//  HostApi：宿主提供给插件的全部能力
// ───────────────────────────────────────────────────────────────────────────

/// 从「本插件专属 arena」分配。卸载时整体释放，所以**不需要 free**。
///
/// 这是 Zig 相对 Cordis 的最大简化：Cordis 要靠 disposer 链表 + 异步等待
/// 保证不泄漏；Zig 里 arena.deinit() 一把清空，泄漏在物理上不可能。
/// 代价：插件无法在卸载后保留内存（本来也不该）。
///
/// ⚠️ 由此推出一条硬规则：**这块内存不得跨边界长期外借**。
///   插件从这里切一块交给宿主长期持有（比如工具返回的结果字符串），
///   插件一卸载 arena 整体清空 → 宿主手里那块当场悬空。
///   跨边界、宿主之后还要用的内存，必须由宿主自己分配并提供。
pub const AllocFn = *const fn (host_ctx: *anyopaque, len: usize, alignment: u32) callconv(.c) ?*anyopaque;

pub const LogFn = *const fn (host_ctx: *anyopaque, level: LogLevel, msg: [*:0]const u8) callconv(.c) void;

/// 注册一个服务实现。
///
/// `iface` 指向该服务的接口表（每个服务自己的 extern struct，全是函数指针，
/// 由服务定义方与消费方共享的 zig 文件约定）。宿主只做存取，不理解内容。
/// `owner_impl` 是提供者自己的实例指针，调用 iface 里的方法时作为第一个参数传回。
pub const RegisterServiceFn = *const fn (
    host_ctx: *anyopaque,
    name: [*:0]const u8,
    iface: *const anyopaque,
    owner_impl: *anyopaque,
    scope: u64, // 隔离作用域 ID（0 = 全局/根作用域）
) callconv(.c) Handle;

/// 按名字查服务接口表。返回 null 表示当前不可用（不是错误）。
/// 消费者负责 cast 回具体类型：`const tools: *const ToolsIface = @ptrCast(@alignCast(p));`
pub const GetServiceFn = *const fn (host_ctx: *anyopaque, name: [*:0]const u8, scope: u64) callconv(.c) ?*anyopaque;

/// 注册事件监听。返回的 Handle 用于撤销。
pub const OnEventFn = *const fn (
    host_ctx: *anyopaque,
    event: [*:0]const u8,
    mode: DispatchMode,
    cb: Callback,
) callconv(.c) Handle;

/// 撤销任意注册（服务 / 监听器 ……）。按 Handle.id 定位，不按名字。
///
/// ★ 这是整套体系里最重要的一个函数。
///
/// ★ 谁负责：**宿主负责，插件不负责**（基调，不要改成「插件自觉清理」）。
///   注册发生的那一刻宿主就知道「收到了什么」，它顺手把「怎么撤掉它」记进
///   调用者 fiber 的撤销清单。于是插件忘了、init 半路失败、插件崩了，
///   都不影响宿主把自己恢复干净 —— 安全不建立在插件的正确性上。
///   插件调这个函数只有一个用途：**主动提前撤销**（可选能力）。
///
/// 语义：幂等。同一个 handle 撤两次，第二次返回 err_not_found，不崩。
pub const RevokeFn = *const fn (host_ctx: *anyopaque, handle: Handle) callconv(.c) Status;

/// 宿主给插件的全部能力。插件**只能**通过这个结构触达宿主。
pub const HostApi = extern struct {
    abi_version: u32,
    /// 宿主上下文句柄（不透明）。插件把它原样回传给每个调用。
    ctx: *anyopaque,

    alloc: AllocFn,
    log: LogFn,

    register_service: RegisterServiceFn,
    get_service: GetServiceFn,

    on_event: OnEventFn,
    revoke: RevokeFn,

    /// ABI 守卫。插件 init 的第一件事应该是检查它。
    pub fn check(self: *const HostApi) Status {
        return if (self.abi_version == ABI_VERSION) .ok else .err_abi_mismatch;
    }
};

// ───────────────────────────────────────────────────────────────────────────
//  插件侧必须导出的符号（宿主用 dlsym 按名字查找）
// ───────────────────────────────────────────────────────────────────────────

/// 插件导出的 ABI 版本获取函数。
pub const PluginAbiVersionFn = *const fn () callconv(.c) u32;

/// 插件入口。返回 Status（绝不允许 panic 逃出去）。
///
/// `config_json` 是这一行的配置（对应 Cordis 里 entry 的 config）。
/// 实现约定：在 init 里完成全部注册，并保证每一项都有对应的撤销路径。
pub const PluginInitFn = *const fn (api: *const HostApi, config_json: [*:0]const u8) callconv(.c) Status;

/// 插件**可选**导出：主动收尾钩子。
///
/// 责任边界（一句话）：**经由 HostApi 注册的东西由宿主撤；绕开 HostApi 自己
/// 搞的东西（起了线程、开了文件、注册了系统信号）只有插件知道，插件自己收。**
/// 一个规矩使用 HostApi 的插件不需要导出它（hello 就不需要）。
///
/// ⚠️ 宿主**不得依赖**它：它是在卸载过程中被调用的插件代码，插件在里面 panic
///   或死循环会把宿主一起带走，而且此时 .so 还没卸。
///   它是「给插件一个善后的机会」，不是「宿主清理工作的依赖」。
pub const PluginDeinitFn = *const fn () callconv(.c) void;

/// dlsym 用的符号名常量（避免字符串散落各处写错）。
pub const SYM_ABI_VERSION = "dsh_plugin_abi_version";
pub const SYM_INIT = "dsh_plugin_init";
pub const SYM_DEINIT = "dsh_plugin_deinit";
