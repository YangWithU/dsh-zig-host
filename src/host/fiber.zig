//! ═══════════════════════════════════════════════════════════════════════════
//!  阶段 1 · Fiber —— 一次插件挂载的运行时身份        【草图 / 空壳】
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 一个 Fiber 代表「一个插件在某处的一份运行实例」，它掌管三样东西：
//!
//!     1. 状态机      什么时候加载 / 卸载
//!     2. 撤销清单    卸载时按什么顺序、撤销哪些注册
//!     3. 专属 arena  这个插件的内存在哪、什么时候整块回收
//!
//! 状态迁移（对应 Cordis 的 FiberState）
//! ---------------------------------------------------------------------------
//!
//!        ┌──────────┐  依赖就绪   ┌─────────┐  执行成功  ┌────────┐
//!        │ pending  │ ─────────→ │ loading │ ─────────→ │ active │
//!        └──────────┘             └─────────┘            └────────┘
//!              ↑                        │ 执行失败            │
//!              │ 依赖消失               ↓                     │ 卸载
//!        ┌───────────┐            ┌────────┐                 │
//!        │ unloading │ ←──────────┴────────┴─────────────────┘
//!        └───────────┘                 │
//!              │                       ↓
//!              └────────────────→ ┌──────────┐
//!                                 │ disposed │ 不可重启
//!                                 └──────────┘
//!
//!   · pending 是**合法状态**，不是错误：依赖没齐就静静等着。
//!   · 依赖回来 → 自动重新加载（自愈）。
//!
//! ★ 与 Cordis 的三个关键差异（这是基调，必须记住）
//! ---------------------------------------------------------------------------
//!   1. Cordis 用闭包捕获实现回卷；Zig 用**显式 disposer 栈**（Disposable）。
//!   2. Cordis 靠 GC 兜内存；Zig 靠 **arena 整体释放**，泄漏不可能。
//!   3. Cordis 漏清理最多内存泄漏；Zig **漏清理 = 段错误**（已实测）。
//!      ⇒ 撤销清单不是「好设计」，是「安全硬前提」。
//!
//! ⚠️ 空壳：以下函数体均为占位，只表达签名与职责。

const std = @import("std");
const abi = @import("dsh_abi");

pub const State = enum {
    pending,
    loading,
    active,
    unloading,
    disposed,
    failed,
};

/// 一条可撤销的注册。
///
/// 为什么要显式结构体而不是靠闭包：Zig 没有闭包捕获，撤销逻辑必须
/// 自己携带「撤销时需要的全部信息」。`data` 就是那个上下文。
pub const Disposable = struct {
    /// 对应的注册编号（等于宿主侧那个 Handle.id）。
    /// ★ 撤销按编号定位，不按名字 —— 同名注册可以有多份，凭名字会撤错。
    ///   插件主动撤销（apiRevoke）时，就是靠它在清单里找到这一条。
    id: u64 = 0,
    /// 真正执行撤销的函数。
    run: *const fn (self: *Disposable) void,
    /// 撤销所需的状态。**由宿主分配器分配**，不放插件 arena：
    /// 撤销清单的生命周期必须独立于 arena，否则 arena 一旦先清空，
    /// 清单本身就没了，撤销无从谈起。
    data: *anyopaque,
    /// 诊断标签，如 "on_event(tool/call)"。卸载时打日志用。
    label: []const u8,
};

/// 一个插件实例。
pub const Fiber = struct {
    id: u64,
    state: State = .pending,

    /// 插件来源：.so 的绝对路径。内置插件（编译进宿主）为 null。
    plugin_path: ?[]const u8 = null,

    /// dlopen 句柄。dispose 时必须 dlclose（**每代都真正卸载**）。
    ///
    /// ★ 定案：两条一起做，各管一件事，缺一不可。
    ///   · dlclose          —— 负责把内存还回去。
    ///       实测：同一文件「加载+卸载」各 20 次，物理内存 13.5MB → 13.7MB
    ///       基本不动；20 份同时保持着则累积（每份约 2.4MB 虚拟 / 275KB 物理）。
    ///   · 产物名带版本/指纹 —— 负责「即使某次没卸干净，也一定加载到新代码」。
    ///       dlclose 依赖引用计数归零且无 NODELETE 标记；一旦没真卸载，
    ///       同路径 dlopen 会把旧的那份**原样还给你**：不报错、不崩，
    ///       静默跑在旧代码上（实测确认）。换成新文件名，这件事不可能发生。
    ///
    /// ⚠️ 因此绝不允许「覆盖正在被加载的那个 .so 文件」：已映射进内存的
    ///   代码页会被破坏，下一次调用直接段错误（实测 SIGSEGV）。
    lib: ?std.DynLib = null,

    /// ★ 插件专属 arena。该插件一切与自身同生命周期的分配都从这里出。
    ///   卸载时 arena.deinit() 一块清空 —— 这是 Zig 相对 Cordis 的最大红利。
    arena: std.heap.ArenaAllocator,

    /// ★ 撤销清单。存放 arena 管不到的**外部资源**：
    ///   事件监听、服务注册、子 fiber、打开的文件/进程。
    ///
    /// · 由**宿主分配器**持有（不是本 fiber 的 arena），生命周期独立于 arena。
    /// · 卸载时**逆序**执行（后注册的先撤销）。
    /// · 「加载失败回滚」复用同一份清单、同一段执行逻辑 —— 回滚与卸载
    ///   走的是同一条路，不需要写两套。
    /// · 责任在宿主：注册那一刻宿主就顺手记一条，不依靠插件自觉。
    disposers: std.ArrayList(Disposable),

    /// 依赖的服务名（对应 Cordis 的 inject）。
    /// 这些服务全部可用时才能从 pending 进入 loading。
    inject: []const []const u8 = &.{},

    /// 依赖指纹。把每个依赖实现的 (id, generation) 拼起来算一个数。
    /// 指纹变化 = 依赖被替换或消失 → 需要重算状态。
    /// 这是 Cordis 里那个 epoch 字符串的 Zig 版（用整数而非字符串）。
    epoch: u64 = 0,

    /// 树结构：子插件是父插件的一个「可回收物」。
    /// 卸载父 fiber 时，子 fiber 会随撤销清单一起被卸载 → 级联卸载就这样自动发生。
    parent: ?*Fiber = null,
    children: std.ArrayList(*Fiber),

    /// 宿主上下文（用于日志、分配器等回调）。
    host: ?*abi.HostApi = null,

    /// 用于诊断的插件名（从 .so 路径推导或插件自报）。
    name: []const u8 = "anonymous",

    // ── 构造与销毁 ─────────────────────────────────────────────────────────

    /// 创建一个 fiber。此时**不**加载插件代码，只是登记一个身份。
    /// arena 也在这时建立（插件后续所有分配都走它）。
    ///
    /// ⚠️ arena 与 fiber 是同一份生命周期的**两处记录**（fiber.arena 与
    ///   Context 里的记账表）。销毁 fiber 时必须同步删掉那一处，否则要么
    ///   累积，要么在 id 被复用后指错。后续应合并成只有一处真相。
    pub fn create(host: *abi.HostApi, gpa: std.mem.Allocator, path: ?[]const u8) !*Fiber {
        _ = host;
        _ = gpa;
        _ = path;
        @panic("TODO: 阶段 1 —— 建 fiber 身份 + arena + 空的撤销清单");
    }

    /// 登记一条撤销项。注册类操作（on_event / register_service / 子插件）
    /// **一律**先做注册、再登记撤销，顺序不能反。
    pub fn addDisposable(self: *Fiber, d: Disposable) !void {
        _ = self;
        _ = d;
        @panic("TODO: 阶段 1 —— 追加到 disposers");
    }

    /// 检查依赖是否齐全，算出新的 epoch。
    /// 返回 true 表示依赖齐了（可以加载）。
    pub fn refresh(self: *Fiber, svc: *anyopaque) bool {
        _ = self;
        _ = svc;
        @panic("TODO: 阶段 2 —— 查服务表，拼 epoch，与旧值比较");
    }

    /// 加载：dlopen → 查符号 → 校验 ABI → 调 plugin_init。
    ///
    /// 失败必须**完全回滚**，而且回滚就是 unload()：跑同一份撤销清单（把 init
    /// 里已经注册掉的东西撤掉）+ dlclose + arena 清空。
    /// 不留半个插件 —— 半加载状态是后续所有诡异崩溃的源头。
    pub fn load(self: *Fiber) void {
        _ = self;
        @panic("TODO: 阶段 1 —— dlopen/dlsym/init，失败时完整回滚");
    }

    /// 卸载：**先**逆序撤销全部注册，**再** dlclose，**最后** arena 清空。
    ///
    /// 顺序不可调换：
    ///   ① 必须先于 ② —— 撤销清单里每一条做的都是「去宿主表里删一行」，而那
    ///      些行里存的函数地址就指向 .so 里的代码。先卸代码再撤销，撤销过程
    ///      自己就跑到别人家去了（实测：漏撤销 → 段错误）。
    ///   ③ 必须在 ① 之后 —— 撤销项携带的上下文（Disposable.data）可能是 arena
    ///      里的内存，先清 arena 就没得用了。
    ///
    /// 撤销按编号（Disposable.id）定位，不按名字。
    /// 撤销过程中若引起依赖者需要重算状态，**只收集、不立即加载**，交给
    /// Context 统一调度 —— 避免「在撤销里又触发加载」的重入。
    pub fn unload(self: *Fiber) void {
        _ = self;
        @panic("TODO: 阶段 1 —— 逆序跑 disposers → dlclose → arena.deinit()");
    }

    /// 彻底销毁：卸载 + 从父 fiber 摘除 + 释放自身结构。
    pub fn dispose(self: *Fiber) void {
        _ = self;
        @panic("TODO: 阶段 1 —— unload() + 摘除 + 释放");
    }
};
