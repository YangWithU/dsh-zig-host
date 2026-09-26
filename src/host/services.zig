//! ═══════════════════════════════════════════════════════════════════════════
//!  阶段 2 · Services —— 服务注册表
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 把「谁提供了什么能力」变成一张表，让插件通过**名字**而不是直接引用来协作。
//!
//!     Cordis:  ctx.tools                    ← Proxy 动态属性查找
//!     Zig:     registry.get("tools", 0)     ← 显式哈希表查询（没有 Proxy）
//!
//! 数据流
//! ---------------------------------------------------------------------------
//!   插件 init 里调 api.register_service(ctx, "tools", iface)
//!     -> Registry.provide() 分配编号 -> 拷名字 -> 入表 -> 返回 Handle
//!     -> 宿主把这个 Handle 记进该插件的撤销清单（注册与记账成对）
//!   别人要用：Registry.get("tools", 0) -> cast 成该服务自己的 iface 结构体
//!   插件卸载：撤销清单里那一条按编号调 Registry.revoke() -> 删行
//!
//! 不变量
//! ---------------------------------------------------------------------------
//!   ① 编号单调递增、**永不复用** —— id 一旦回收再利用，握在插件手里的旧
//!      handle 就会复活并指向别人（ABA）。撤销只按 id 定位，不按名字：
//!      同一个插件可以对同一名字注册多份，凭名字撤销会撤错行。
//!   ② 服务名必须拷进宿主内存 —— 插件给的字符串在它自己的 arena 里，那个
//!      arena 卸载时整块清空，表里还留着就是悬空指针。
//!   ③ 同名同 scope 已存在 -> 拒绝，不覆盖也不静默替换（覆盖会让前一个
//!      提供者的撤销项指向一行已经不在表里的记录）。
//!
//! 第二批再做（现在刻意不做）
//! ---------------------------------------------------------------------------
//!   依赖门（inject）：服务出现/消失 -> 通知依赖它的 fiber 重算 epoch ->
//!     自动加载/卸载。这是「自愈」的来源、也是热重载的基础，但它需要 fiber
//!     状态机先稳，且会引入 services <-> fiber 的双向协作 —— 留到装卸闭环
//!     有测试保护之后再上。
//!   隔离作用域（Scopes）：Cordis 用 Symbol 作键，Zig 改用整数 scope id，
//!     同 id 即合并。字段（scope）已在表里，分配器第二批再写。

const std = @import("std");
const abi = @import("dsh_abi");
const fiber_mod = @import("fiber.zig");

/// 一条服务实现记录。
pub const ServiceEntry = struct {
    /// 稳定编号，由 Registry 分配（等同 Handle.id）。
    id: u64 = 0,

    /// 服务名。**由 Registry 拷贝持有**，不引用插件内存（见文件头不变量 ②）。
    name: []const u8,
    scope: u64 = 0,

    /// 服务接口表（每个服务自定义的 extern struct，全是函数指针）。
    iface: *const anyopaque,
    /// 提供者的实例指针，调用 iface 的方法时作为第一个参数传回。
    impl: *anyopaque,

    /// 谁提供的 —— 撤销时校验「这条确实是你注册的」。
    owner: *fiber_mod.Fiber,

    /// 每次重新提供都递增，让旧句柄失效（防 ABA）。
    /// 第一批没有「重新提供」这条路，恒为 1；字段先留着。
    generation: u32 = 1,
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(ServiceEntry),

    /// 下一个待分配的条目编号。单调递增，永不复用。
    next_id: u64 = 1,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa, .entries = .empty };
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |e| self.gpa.free(e.name);
        self.entries.deinit(self.gpa);
    }

    /// 注册服务：查重 → 分配编号 → 拷名字 → 入表 → 返回 Handle。
    /// 同名同 scope 已存在、或内存分配失败 → 返回 INVALID_HANDLE。
    ///
    /// 调用方（宿主侧的 apiRegisterService）**必须同时**在提供者 fiber 的
    /// 撤销清单里登记一条「按这个编号撤销」的项 —— 两步成对，责任在宿主。
    pub fn provide(self: *Registry, e: ServiceEntry) abi.Handle {
        for (self.entries.items) |ex| {
            if (ex.scope == e.scope and std.mem.eql(u8, ex.name, e.name)) {
                return abi.INVALID_HANDLE;
            }
        }

        // 名字拷进宿主内存：插件 arena 卸载时清空，表里不能留它的指针
        const name = self.gpa.dupe(u8, e.name) catch return abi.INVALID_HANDLE;

        var entry = e;
        entry.id = self.next_id;
        entry.name = name;
        entry.generation = 1;

        self.entries.append(self.gpa, entry) catch {
            self.gpa.free(name);
            return abi.INVALID_HANDLE;
        };

        self.next_id += 1;
        return .{ .id = entry.id, .generation = entry.generation };
    }

    /// 撤销服务（由 fiber 的撤销清单在卸载时调用，插件也可主动调）。
    /// 按编号定位那一行；generation 或 owner 对不上说明这条早已撤过、或者
    /// 本来就不属于你 -> 静默返回（幂等，不报错、不改别人家的行）。
    pub fn revoke(self: *Registry, id: u64, generation: u32, owner: *fiber_mod.Fiber) void {
        for (self.entries.items, 0..) |e, i| {
            if (e.id != id) continue;
            if (e.generation != generation or e.owner != owner) return;
            self.gpa.free(e.name);
            _ = self.entries.orderedRemove(i);
            return;
        }
    }

    /// 按名字查接口表。返回 null = 当前没有这个服务（不是错误）。
    ///
    /// ★ 这里就是 Cordis `ctx.tools` 的对应物。区别是 Zig 必须显式 cast：
    ///     const raw = reg.get("tools", 0) orelse return;
    ///     const tools: *const ToolsIface = @ptrCast(@alignCast(raw));
    ///   类型安全由「服务接口定义在共享的 zig 文件里」这一约定保证。
    pub fn get(self: *Registry, name: []const u8, scope: u64) ?*const anyopaque {
        for (self.entries.items) |e| {
            if (e.scope != scope) continue;
            if (!std.mem.eql(u8, e.name, name)) continue;
            return e.iface;
        }
        return null;
    }

    /// 按编号查整行（诊断与测试用）。
    pub fn lookup(self: *Registry, id: u64) ?*ServiceEntry {
        for (self.entries.items) |*e| {
            if (e.id == id) return e;
        }
        return null;
    }

    /// 当前表里有多少条。测试断言「零残留」用。
    pub fn count(self: *Registry) usize {
        return self.entries.items.len;
    }
};

// ───────────────────────────────────────────────────────────────────────────
//  测试
// ───────────────────────────────────────────────────────────────────────────

/// owner 字段只被比较指针值，不解引用，所以测试里一个 undefined 的 fiber
/// 就够用（不必先实装 fiber.zig）。
fn ownerStub() *fiber_mod.Fiber {
    const S = struct {
        var fiber: fiber_mod.Fiber = undefined;
    };
    return &S.fiber;
}

fn ownerStub2() *fiber_mod.Fiber {
    const S = struct {
        var fiber: fiber_mod.Fiber = undefined;
    };
    return &S.fiber;
}

var iface_stub: u32 = 1;

test "provide -> get -> revoke：注册可用，撤销后零残留" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const owner = ownerStub();
    const h = reg.provide(.{
        .name = "greeter",
        .iface = @ptrCast(&iface_stub),
        .impl = @ptrCast(&iface_stub),
        .owner = owner,
    });

    try std.testing.expect(h.id != 0);
    try std.testing.expectEqual(@as(usize, 1), reg.count());
    try std.testing.expect(reg.get("greeter", 0) != null);
    try std.testing.expectEqual(@as(u64, 1), reg.lookup(h.id).?.id);

    reg.revoke(h.id, h.generation, owner);

    try std.testing.expectEqual(@as(usize, 0), reg.count());
    try std.testing.expect(reg.get("greeter", 0) == null);
    try std.testing.expect(reg.lookup(h.id) == null);

    // 幂等：再撤一次不崩、不报错、依然 0 行
    reg.revoke(h.id, h.generation, owner);
    try std.testing.expectEqual(@as(usize, 0), reg.count());
}

test "同名同 scope 拒绝；不同 scope 允许共存；编号不复用" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const owner = ownerStub();
    const a = reg.provide(.{ .name = "tools", .iface = @ptrCast(&iface_stub), .impl = @ptrCast(&iface_stub), .owner = owner });
    try std.testing.expect(a.id != 0);

    // 同名同 scope -> 拒绝
    const dup = reg.provide(.{ .name = "tools", .iface = @ptrCast(&iface_stub), .impl = @ptrCast(&iface_stub), .owner = owner });
    try std.testing.expect(dup.id == 0);
    try std.testing.expectEqual(@as(usize, 1), reg.count());

    // 同名不同 scope -> 允许
    const other = reg.provide(.{ .name = "tools", .scope = 7, .iface = @ptrCast(&iface_stub), .impl = @ptrCast(&iface_stub), .owner = owner });
    try std.testing.expect(other.id != 0);
    try std.testing.expect(other.id != a.id);
    try std.testing.expectEqual(@as(usize, 2), reg.count());
    try std.testing.expect(reg.get("tools", 7) != null);
    try std.testing.expect(reg.get("tools", 8) == null);

    // 撤掉 scope 0 那份，scope 7 那份不受影响
    reg.revoke(a.id, a.generation, owner);
    try std.testing.expectEqual(@as(usize, 1), reg.count());
    try std.testing.expect(reg.get("tools", 0) == null);
    try std.testing.expect(reg.get("tools", 7) != null);

    // 编号不复用：新注册拿到的 id 比之前两个都大
    const next = reg.provide(.{ .name = "other", .iface = @ptrCast(&iface_stub), .impl = @ptrCast(&iface_stub), .owner = owner });
    try std.testing.expect(next.id > other.id);
}

test "撤销时 owner 对不上 -> 不动别人家的行" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const owner = ownerStub();
    const intruder = ownerStub2();
    const h = reg.provide(.{ .name = "greeter", .iface = @ptrCast(&iface_stub), .impl = @ptrCast(&iface_stub), .owner = owner });

    // 别人拿着正确的 id 来撤 -> 不应动这一行
    reg.revoke(h.id, h.generation, intruder);
    try std.testing.expectEqual(@as(usize, 1), reg.count());

    // generation 对不上 -> 同样不动
    reg.revoke(h.id, h.generation + 1, owner);
    try std.testing.expectEqual(@as(usize, 1), reg.count());

    // 本人来撤 -> 撤掉
    reg.revoke(h.id, h.generation, owner);
    try std.testing.expectEqual(@as(usize, 0), reg.count());
}

test "服务名被拷贝持有：插件那边的原字符串失效后表里仍可用" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    // 模拟插件 arena：注册后就整块释放
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    const plugin_gpa = plugin_arena.allocator();

    const owner = ownerStub();
    const name_in_plugin = try plugin_gpa.dupe(u8, "greeter");
    const h = reg.provide(.{ .name = name_in_plugin, .iface = @ptrCast(&iface_stub), .impl = @ptrCast(&iface_stub), .owner = owner });

    plugin_arena.deinit(); // 插件内存没了

    // 表里那行仍然可用（因为名字是拷贝的）
    try std.testing.expect(reg.get("greeter", 0) != null);
    try std.testing.expectEqualStrings("greeter", reg.lookup(h.id).?.name);

    reg.revoke(h.id, h.generation, owner);
    try std.testing.expectEqual(@as(usize, 0), reg.count());
}
