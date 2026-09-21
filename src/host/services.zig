//! ═══════════════════════════════════════════════════════════════════════════
//!  阶段 2 · Services —— 服务注册表与依赖门         【草图 / 空壳】
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 这是 Cordis 里 reflect.ts 的 Zig 版：把「谁提供了什么能力」变成一张表，
//! 让插件通过**名字**而不是直接引用来协作。
//!
//!     Cordis:  ctx.tools            ← Proxy 动态属性查找
//!     Zig:     table.get("tools")   ← 显式哈希表查询（没有 Proxy）
//!
//! ★ 依赖门（inject）—— 本阶段最有价值的部分
//! ---------------------------------------------------------------------------
//! 依赖声明**不是一次性检查**，而是一道一直生效的门：
//!
//!     服务出现 → 通知所有依赖它的 fiber → 重算 epoch → 自动加载
//!     服务消失 → 通知所有依赖它的 fiber → 重算 epoch → 自动卸载
//!
//! 于是整个系统是「自愈」的：插件的存活性永远自动跟随依赖关系，
//! 不需要谁去编排重启顺序。热重载本质上就是「故意让某人的 epoch 失效」。
//!
//! 隔离作用域（isolate）
//! ---------------------------------------------------------------------------
//! Cordis 用 Symbol 作为作用域键。Zig 里**不要照抄符号比较**，
//! 改用显式的整数作用域 ID：
//!     scope 0        = 根作用域（全局）
//!     scope N (N>0)  = 某个隔离作用域（同 ID 即合并，对应 Cordis 的同 label）
//! 查表键 = (name, scope)，所以同名服务能在不同 scope 各存一份实现。
//!
//! ⚠️ 空壳。

const std = @import("std");
const abi = @import("dsh_abi");
const fiber_mod = @import("fiber.zig");

/// 一条服务实现记录。
pub const ServiceEntry = struct {
    name: []const u8,
    scope: u64 = 0,

    /// 服务接口表（每个服务自定义的 extern struct，全是函数指针）。
    iface: *const anyopaque,
    /// 提供者的实例指针，调用 iface 方法时作为第一个参数传回。
    impl: *anyopaque,

    /// 谁提供的 —— 卸载时靠它自动摘除（对应 Cordis 里提供者 fiber 拥有服务）。
    owner: *fiber_mod.Fiber,

    /// 可用性谓词（可选）。返回 false 表示「暂时不算可用」，
    /// 依赖它的 fiber 会退回 pending 而不是 active。
    /// Cordis 里对应 Service[Service.check]。
    check: ?*const fn (impl: *anyopaque) callconv(.c) bool = null,

    /// 每次重新提供都递增。用于让持有的旧句柄失效（防 ABA）。
    generation: u32 = 1,
};

/// 服务注册表。
pub const Registry = struct {
    gpa: std.mem.Allocator,
    /// 键是 (name, scope) 的组合。草图先用字符串键 + scope 并存的条目表。
    entries: std.ArrayList(ServiceEntry),

    /// 依赖索引：服务名 → 依赖它的 fiber 列表。
    /// 服务变化时靠它做定向通知，不必遍历全表。
    /// （Cordis 是遍历所有 fiber 逐个检查 inject，Zig 里有更省的写法。）
    dependents: std.StringHashMap(std.ArrayList(*fiber_mod.Fiber)),

    pub fn init(gpa: std.mem.Allocator) Registry {
        _ = gpa;
        @panic("TODO: 阶段 2 —— 初始化空表");
    }

    pub fn deinit(self: *Registry) void {
        _ = self;
        @panic("TODO: 阶段 2");
    }

    /// 注册服务。同名同 scope 已存在 → 返回 err_duplicate。
    ///
    /// 调用方（宿主侧的 HostApi.register_service）会**同时**在提供者 fiber
    /// 的撤销清单里登记一条撤销项，从而保证提供者卸载时服务自动消失。
    /// 这两步必须成对出现。
    pub fn provide(self: *Registry, e: ServiceEntry) abi.Status {
        _ = self;
        _ = e;
        @panic("TODO: 阶段 2 —— 查重 → 入表 → 建索引 → 通知依赖者");
    }

    /// 撤销服务（由 fiber 的撤销清单在卸载时调用）。
    pub fn revoke(self: *Registry, name: []const u8, scope: u64, owner: *fiber_mod.Fiber) void {
        _ = self;
        _ = name;
        _ = scope;
        _ = owner;
        @panic("TODO: 阶段 2 —— 摘除 + 通知依赖者重算");
    }

    /// 查服务接口表。返回 null = 当前不可用（不是错误）。
    ///
    /// ★ 这里就是 Cordis `ctx.tools` 的对应物。区别是 Zig 必须显式 cast：
    ///     const raw = reg.get("tools", 0) orelse return;
    ///     const tools: *const ToolsIface = @ptrCast(@alignCast(raw));
    ///   类型安全由「服务接口定义在共享的 zig 文件里」这一约定保证。
    pub fn get(self: *Registry, name: []const u8, scope: u64) ?*const anyopaque {
        _ = self;
        _ = name;
        _ = scope;
        @panic("TODO: 阶段 2 —— 查表，并校验 owner 处于 active");
    }

    /// 服务变化后，重算所有依赖者的 epoch，返回状态发生变化的 fiber。
    ///
    /// 返回变化者（而不是自己动手加载/卸载）是为了让调度集中在 Context 里，
    /// 避免「在撤销过程中又触发加载」这类重入问题。
    pub fn notify(self: *Registry, name: []const u8, scope: u64) []const *fiber_mod.Fiber {
        _ = self;
        _ = name;
        _ = scope;
        @panic("TODO: 阶段 2 —— 按 dependents 索引定向通知 → 各自 refresh()");
    }
};

/// 隔离作用域管理（对应 Cordis 的 isolate）。
///
/// 用法：某个 agent preset 想要自己独享一份 tools 实例时，
/// 给它分配一个独立 scope，它读到的 tools 就是自己那份。
pub const Scopes = struct {
    next_id: u64 = 1,
    /// label → scope id。同 label 复用同一 id（合并语义）。
    labels: std.StringHashMap(u64),

    /// 取（或创建）一个具名作用域。
    pub fn resolve(self: *Scopes, label: []const u8) u64 {
        _ = self;
        _ = label;
        @panic("TODO: 阶段 2 —— label 复用或分配新 id");
    }

    /// 分配一个私有作用域（对应 Cordis 里 isolate: { tools: true }）。
    pub fn fresh(self: *Scopes) u64 {
        _ = self;
        @panic("TODO: 阶段 2");
    }
};
