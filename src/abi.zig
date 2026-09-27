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
///
/// 1 -> 2：HostApi 增加 read_file / write_file / run_shell 三个基础能力
///（把工具搬进 .so 需要它们），Status 增加 err_too_large / err_timeout。
/// 2 -> 3：事件总线上线。Callback 的签名必须变 —— 旧签名没有放行把手、没有
/// 返回值、payload 还是只读的，装不下 waterfall（环绕中间件）。同时 on_event
/// 去掉了 mode 参数（改由发布方指定），HostApi 增加 emit。
/// 3 -> 4：EventPayload 增加 default_action / action_ctx —— waterfall 的「链尾
/// 默认行为」（比如「真的去执行这个工具」）必须有个地方挂。
/// 旧插件会被 loader 拒绝加载 —— 这正是版本号存在的意义：
/// 跨边界类型的布局一旦改变，调用不会报错，只会崩。
pub const ABI_VERSION: u32 = 4;

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
    /// 结果超过宿主设定的上限（文件太大 / 命令输出太多）。
    /// 与 err_invalid_arg 分开：这不是调用方用法错，是数据本身放不下。
    err_too_large = 8,
    /// 超时（目前只有 run_shell 会返回它）。
    err_timeout = 9,
    /// 监听器否决了这次事件（waterfall 里不调 next 就是否决）。
    /// 与 err_internal 分开：这是监听器**有意的决定**，不是出了故障。
    err_denied = 10,
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

/// 事件载荷。
///
/// 用一个 JSON 字符串充当通用载体：结构化（逐事件声明 extern struct）类型安全，
/// 但每加一种事件就要动 ABI；JSON 弱类型但零 ABI 代价。
///
/// `out_*` 是**供监听器写回结果**的缓冲区，由发布方提供（out_ptr 为 null 就是
/// 本次分发不允许改写）。waterfall 的「改写」就写在这上面 —— 不新开一套「返回
/// 值里带内存」的机制，与项目里 Buffer 的做法一致：谁调用谁提供内存。
pub const EventPayload = extern struct {
    /// 事件名，如 "tool/pre-execute"
    name: [*:0]const u8,
    /// 事件数据（JSON 文本，只读输入）
    json: [*:0]const u8,

    out_ptr: ?[*]u8 = null,
    out_cap: usize = 0,
    out_len: usize = 0,

    /// 链尾「默认行为」的上下文（发布方给）。默认行为是个普通 C 函数，没有它
    /// 就找不回自己的状态 —— 与 Callback 的 user 参数同构。
    action_ctx: ?*anyopaque = null,

    /// 链尾的「默认行为」。整条链都放行之后才会执行；任何一个监听器不调
    /// next()（否决），它就永远不会执行 —— 这就是「权限门」为什么能拦住动作。
    /// null = 没有默认行为（比如纯通知类事件），链尾直接返回 ok。
    default_action: ?*const fn (payload: *EventPayload) callconv(.c) Status = null,

    pub fn out(self: *const EventPayload) []const u8 {
        const p = self.out_ptr orelse return &.{};
        return p[0..self.out_len];
    }

    /// 把结果写回输出缓冲（waterfall 的监听器改用它改写）
    pub fn setOut(self: *EventPayload, data: []const u8) void {
        const p = self.out_ptr orelse return;
        const n = @min(data.len, self.out_cap);
        @memcpy(p[0..n], data[0..n]);
        self.out_len = n;
    }
};

/// 环绕中间件的「放行」把手。
///
/// 监听器调它，把控制权交给链上的下一个监听器（全部走完后是「默认行为」，
/// 也就是发布方预先写进 payload.out 的那份内容）。
/// **不调它就是否决** —— 后面的监听器与默认行为都不执行。
pub const NextFn = *const fn (next_ctx: *anyopaque, payload: *EventPayload) callconv(.c) Status;

/// 事件监听回调。
///
/// ★ 所有分发方式共用这一个签名，区别只在**发布方**怎么用它：
///     emit       忽略返回值（监听者只能观察）
///     waterfall  用返回值与 payload.out（监听者能改写、能否决）
///     bail       遇到第一个非 ok 的返回就停
///
/// ★ payload 是**可变**指针：waterfall 里监听器要能改写它。
///
/// `user` 是注册时给的**用户数据指针**（C 里的 user data）。
/// **不能省**：Zig 没有闭包，监听器要访问自己的状态只有靠它。
/// `next_ctx`/`next` 是本轮分发的放行把手，对监听器不透明。
///
/// ⚠️ 这是函数指针：一旦宿主卸载了插件代码而没撤销这个监听，再触发就是段错误
///    （实测过）。所以撤销必须在 dlclose 之前完成。
pub const Callback = *const fn (
    user: *anyopaque,
    payload: *EventPayload,
    next_ctx: *anyopaque,
    next: NextFn,
) callconv(.c) Status;

/// 事件分发方式。**发布时指定**，不是注册时的属性 ——
/// 同一个事件可以被不同方式分发，而监听器不需要知道自己会怎么被调用
/// （Cordis 也是这个语义：ctx.emit / ctx.waterfall 是发布动作）。
///
/// 原草图里的 serial 去掉了：它是 JS 世界「bail 的异步版」，而 Zig 这边一切
/// 都是同步的，两者没有区别。parallel 保留声明但**尚未实现**（agent 主循环是
/// 串行的；要做得引入线程池）。
pub const DispatchMode = enum(c_int) {
    /// 广播：逐个调用全部监听器，忽略返回值 —— 通知（日志、统计、UI 刷新）
    emit = 0,
    /// 环绕中间件：监听器能改写 payload.out、能否决；发布方拿结果
    waterfall = 1,
    /// 按序问，遇到第一个非 ok 的返回即停 —— 竞争认领 / 多级判定
    bail = 2,
    /// 全部并发、等齐（未实现）
    parallel = 3,
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

/// 注册事件监听。返回 Handle 供撤销。
/// **不带分发方式** —— 那是发布方的事（见 DispatchMode 的说明）。
///
/// `user` 是调用方自己的数据指针，回调时原样传回第一个参数。
/// 少了它就等于没有闭包可用（Zig 里监听器只是个函数指针）。
pub const OnEventFn = *const fn (
    host_ctx: *anyopaque,
    event: [*:0]const u8,
    cb: Callback,
    user: *anyopaque,
) callconv(.c) Handle;

/// 发布事件。
///
/// 事件名在 `payload.name` 里。payload 的输出缓冲由调用方准备：
/// waterfall 的「默认行为」就是它预先写进去的那份内容，链上的监听器可以改写。
pub const EmitFn = *const fn (
    host_ctx: *anyopaque,
    payload: *EventPayload,
    mode: DispatchMode,
) callconv(.c) Status;

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

// ───────────────────────────────────────────────────────────────────────────
//  基础能力：文件与进程
//
//  为什么是宿主给的能力、而不是插件自己调 std.fs / std.process：
//  插件是被加载进来的陌生代码，它**没有资格**自己碰文件系统与进程。
//  能力由宿主授予（将来才能做审计、限流、沙箱），所以它和 alloc/log 同级，
//  而不是「某个插件提供的服务」—— 后者会让基础能力依赖另一个插件的存活。
// ───────────────────────────────────────────────────────────────────────────

/// 跨边界的一段内存。
///
/// ★ **由宿主分配，从「调用者所属 fiber 的 arena」切**，随该 fiber 卸载一起
///   回收。插件拿到后不需要也无法释放它 —— 调用者自己就是它的主人。
pub const Bytes = extern struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,

    pub fn slice(self: *const Bytes) []const u8 {
        const p = self.ptr orelse return &.{};
        return p[0..self.len];
    }
};

/// 命令的终止方式。
/// 为什么不用 `?i32` 表示「没有退出码」：extern struct 不允许非指针 optional
///（没有保证的内存布局）。用显式的枚举 + 一个 code 字段代替。
pub const TermKind = enum(c_int) {
    /// 正常退出，此时 code 是退出码（0-255）
    exited = 0,
    /// 被信号终止，此时 code 是信号编号
    signal = 1,
    /// 其它（stopped / 未知）
    other = 2,
};

/// 一条命令的执行结果。stdout / stderr 的内存同样来自调用者的 arena。
pub const ShellResult = extern struct {
    term: TermKind = .other,
    /// term 为 exited 时是退出码；为 signal 时是信号编号；other 时无意义
    code: i32 = 0,

    stdout_ptr: ?[*]u8 = null,
    stdout_len: usize = 0,
    stderr_ptr: ?[*]u8 = null,
    stderr_len: usize = 0,

    pub fn stdout(self: *const ShellResult) []const u8 {
        const p = self.stdout_ptr orelse return &.{};
        return p[0..self.stdout_len];
    }

    pub fn stderr(self: *const ShellResult) []const u8 {
        const p = self.stderr_ptr orelse return &.{};
        return p[0..self.stderr_len];
    }
};

/// 读一个文件，内容写进 out（内存由宿主从调用者 arena 分配）。
pub const ReadFileFn = *const fn (
    host_ctx: *anyopaque,
    path: [*:0]const u8,
    out: *Bytes,
) callconv(.c) Status;

/// 写一个文件（覆盖）。data 只在调用期间需要有效。
pub const WriteFileFn = *const fn (
    host_ctx: *anyopaque,
    path: [*:0]const u8,
    data: [*]const u8,
    len: usize,
) callconv(.c) Status;

/// 用 `bash -lc` 跑一条命令。
///
/// ★ **命令非 0 退出不算失败**：返回 ok，调用方自己看 exit_code。
///   模型需要看到错误输出来自己纠正，把非 0 当失败会把它挡在真相外面。
pub const RunShellFn = *const fn (
    host_ctx: *anyopaque,
    command: [*:0]const u8,
    timeout_s: u32,
    out: *ShellResult,
) callconv(.c) Status;

/// 宿主给插件的全部能力。插件**只能**通过这个结构触达宿主。
pub const HostApi = extern struct {
    abi_version: u32,
    /// 宿主上下文句柄（不透明）。插件把它原样回传给每个调用。
    ctx: *anyopaque,

    alloc: AllocFn,
    log: LogFn,

    // 基础能力（文件 / 进程）—— 宿主授予，插件不得自己碰 std.fs / std.process
    read_file: ReadFileFn,
    write_file: WriteFileFn,
    run_shell: RunShellFn,

    register_service: RegisterServiceFn,
    get_service: GetServiceFn,

    on_event: OnEventFn,
    emit: EmitFn,
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

/// 内置事件名。
///
/// 用常量而不是让发布方与监听方各写一遍字符串：事件名拼错是**最难查的一类
/// bug** —— 不报错、不崩，只是那个监听永远不触发，看起来像“插件没生效”。
pub const EventNames = struct {
    /// 工具即将执行（waterfall）。监听器可以否决（不调 next），也可以先调
    /// next 拿到执行结果再改写。链尾默认行为 = 真的执行这个工具。
    pub const tool_pre_execute = "tool/pre-execute";

    /// 一次工具调用发生了（emit）。只观察，改不了任何东西 —— 日志、统计、UI。
    pub const tool_call = "tool/call";

    /// 请求即将发出（waterfall）。监听器往 payload.out 写「额外要注入的上下文」，
    /// 宿主把它拼进这一轮的 system 消息（不写进会话历史）。
    pub const agent_request = "agent/request";

    /// 模型说了一段话（emit）。文本为空时不发 —— 否则界面上一堆空行。
    /// 终端渲染层靠它显示「助手说了什么」。
    pub const assistant_text = "assistant-text";

    /// 一次工具调用结束（emit）：payload 是 {"tool":…,"ok":…,"bytes":…}。
    /// 与 tool_call 配对，一前一后。
    pub const tool_result = "tool/result";

    /// 状态变化（emit）：payload 是 {"state":"thinking"|"idle"}。
    pub const agent_status = "agent/status";
};
