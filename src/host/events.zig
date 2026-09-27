//! ═══════════════════════════════════════════════════════════════════════════
//!  阶段 3 · Events —— 事件总线
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 事件是「不产生编译期依赖的协作方式」：发布者不需要知道谁在听。
//! 与服务的分工是清楚的：
//!
//!     服务表   点对点，拉：我要一个能力，谁提供？        -> 定向调用
//!     事件总线 广播，推：这里发生/即将发生一件事，谁想管？ -> 不定向
//!
//! 分发方式（**发布时**指定，见 abi.DispatchMode）
//!
//!     emit       逐个调用全部监听器，忽略返回值   -> 通知（日志、统计、UI）
//!     waterfall  环绕中间件，可改写 payload.out   -> 拦截改写（权限门、注入）
//!     bail       遇到第一个非 ok 的返回就停        -> 竞争认领（谁先答上算谁的）
//!     parallel   未实现
//!
//! ★ 一次 waterfall 分发的形状（洋葱）
//! ---------------------------------------------------------------------------
//!   监听器收到 (payload, next)：调 next() 放行（链尾是「默认行为」，即发布方
//!   预先写进 payload.out 的内容），不调 next() 就是否决。返回值沿链向外包 ——
//!   监听器可以先调 next() 拿到后面的结果，再决定怎么改。
//!
//!   Zig 没有闭包，所以用「显式遍历状态 + 一个静态 next 函数」：
//!   `Walk{name, payload, index}` 放在**调用者的栈上**，next_ctx 指向它，
//!   next 回调推进 index 并递归调用下一个监听器。
//!
//! ★ emit 与 waterfall 的遍历**必须不同**（这是两个独立的循环）
//! ---------------------------------------------------------------------------
//!   emit 是广播：每个监听器都被调到，谁也不影响谁。所以它不走 next 链 ——
//!   一旦走了，「某个监听器忘了调 next」就会让后面的人收不到通知，而通知本来
//!   就不该有这种「谁挡谁」的语义。emit 给监听器一个空操作的 next，保证误调
//!   不会出事，但它不参与推进。
//!
//! 不变量
//! ---------------------------------------------------------------------------
//!   ① 编号单调递增、永不复用；撤销按 (id, generation, owner) 定位，**不按
//!      事件名** —— 同一个插件可以对同一事件注册多个监听。
//!   ② 事件名拷进宿主内存：插件给的字符串在它自己的 arena 里，卸载时整块清空。
//!   ③ **分发过程中禁止注册/撤销**（depth > 0 直接拒绝）：监听器列表正在被
//!      遍历，此刻 append 可能触发 realloc，遍历用的指针当场悬空。
//!      Cordis 靠「先复制一份快照」绕过；这里选择直接拒绝 —— 少一层分配，而且
//!      「分发进行到一半时改监听器」本来就没有非做不可的理由。
//!   ④ 撤销必须早于 dlclose：回调是插件里的函数地址。

const std = @import("std");
const abi = @import("dsh_abi");
const fiber_mod = @import("fiber.zig");

/// 一条监听记录。
pub const Listener = struct {
    /// 稳定编号，由 Bus 分配（等同 Handle.id）。
    id: u64 = 0,
    /// 事件名。**由 Bus 拷贝持有**，不引用插件内存（见不变量 ②）。
    event: []const u8,
    cb: abi.Callback,
    /// 回调第一个参数原样传回的**用户数据**（注册者自己的状态指针）。
    /// Zig 没有闭包，监听器要访问自己的状态只有靠这个。
    user: *anyopaque,
    /// 谁注册的 —— 撤销时校验「这条确实是你的」
    owner: *fiber_mod.Fiber,
    generation: u32 = 1,
};

pub const Bus = struct {
    gpa: std.mem.Allocator,
    listeners: std.ArrayList(Listener),

    /// 单调递增、永不复用
    next_id: u64 = 1,

    /// 分发深度。> 0 表示正在分发（见不变量 ③）。
    depth: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Bus {
        return .{ .gpa = gpa, .listeners = .empty };
    }

    pub fn deinit(self: *Bus) void {
        for (self.listeners.items) |l| self.gpa.free(l.event);
        self.listeners.deinit(self.gpa);
    }

    /// 注册监听：分配编号 → 拷事件名 → 入表。
    /// **分发过程中拒绝注册**，返回无效句柄（调用方会当成「没注册上」）。
    pub fn on(self: *Bus, l: Listener) abi.Handle {
        if (self.depth > 0) return abi.INVALID_HANDLE;

        const event = self.gpa.dupe(u8, l.event) catch return abi.INVALID_HANDLE;

        var entry = l;
        entry.id = self.next_id;
        entry.event = event;
        entry.generation = 1;

        self.listeners.append(self.gpa, entry) catch {
            self.gpa.free(event);
            return abi.INVALID_HANDLE;
        };

        self.next_id += 1;
        return .{ .id = entry.id, .generation = entry.generation };
    }

    /// 撤销监听（由 fiber 的撤销清单在卸载时调用，插件也可主动调）。
    /// 按 (id, generation, owner) 定位；对不上说明早已撤过或本来就不属于你 ——
    /// 静默返回，幂等，不动别人家的行。
    pub fn off(self: *Bus, id: u64, generation: u32, owner: *fiber_mod.Fiber) void {
        if (self.depth > 0) return;

        for (self.listeners.items, 0..) |l, i| {
            if (l.id != id) continue;
            if (l.generation != generation or l.owner != owner) return;
            self.gpa.free(l.event);
            _ = self.listeners.orderedRemove(i);
            return;
        }
    }

    /// 监听器总数（测试断言「零残留」用）
    pub fn count(self: *Bus) usize {
        return self.listeners.items.len;
    }

    /// 某个事件上有几个监听
    pub fn countFor(self: *Bus, event: []const u8) usize {
        var n: usize = 0;
        for (self.listeners.items) |l| {
            if (std.mem.eql(u8, l.event, event)) n += 1;
        }
        return n;
    }

    /// 分发。
    pub fn dispatch(
        self: *Bus,
        name: []const u8,
        payload: *abi.EventPayload,
        mode: abi.DispatchMode,
    ) abi.Status {
        // parallel 尚未实现：明确失败，不假装成功
        if (mode == .parallel) return .err_internal;

        self.depth += 1;
        defer self.depth -= 1;

        switch (mode) {
            .emit => {
                // 广播：逐个调用，谁也不影响谁。给一个空操作的 next —— emit 的
                // 监听器不该用它（它不是中间件），但签名是统一的，误调不能出事。
                for (self.listeners.items) |*l| {
                    if (!std.mem.eql(u8, l.event, name)) continue;
                    _ = l.cb(l.user, payload, @ptrCast(l), noopNext);
                }
                // 返回值一律忽略：通知就是通知，监听器说什么都不影响发布方
                return .ok;
            },
            .waterfall, .bail => {
                var walk = Walk{ .bus = self, .name = name, .payload = payload, .index = 0 };
                return walk.step();
            },
            .parallel => unreachable,
        }
    }
};

/// 一次 waterfall / bail 分发的遍历状态。
/// **放在调用者的栈上** —— Zig 没有闭包，next 回调要靠一个不透明指针拿到
/// 「链走到哪了」。
const Walk = struct {
    bus: *Bus,
    name: []const u8,
    payload: *abi.EventPayload,
    index: usize,

    fn step(self: *Walk) abi.Status {
        while (self.index < self.bus.listeners.items.len) {
            const l = &self.bus.listeners.items[self.index];
            self.index += 1;
            if (!std.mem.eql(u8, l.event, self.name)) continue;
            // 下标已经推进过了：监听器里再调 next() 就是从下一个开始，
            // 不调 next() 就直接把当前返回值交出去（＝否决）。
            return l.cb(l.user, self.payload, @ptrCast(self), nextFn);
        }
        // 链尾 = 默认行为。发布方已经把默认内容写进 payload.out 了，
        // 这里没有额外要做的事 —— 事件没有「内置实现」这个概念。
        return .ok;
    }
};

/// 给监听器用的放行把手。控制权回到总线，由它推进一步。
fn nextFn(next_ctx: *anyopaque, payload: *abi.EventPayload) callconv(.c) abi.Status {
    const w: *Walk = @ptrCast(@alignCast(next_ctx));
    // 监听器可能换了一份 payload（理论上不该），以它传进来的为准
    w.payload = payload;
    return w.step();
}

/// emit 用的空操作把手：满足签名，什么都不做。
fn noopNext(_: *anyopaque, _: *abi.EventPayload) callconv(.c) abi.Status {
    return .ok;
}

// ───────────────────────────────────────────────────────────────────────────
//  测试：监听器直接写成宿主侧的 C 回调（形状与插件里要写的一模一样）
// ───────────────────────────────────────────────────────────────────────────

/// 测试用的调用记录。data 指针就是它，监听器往里追加自己是谁。
const Trace = struct {
    seen: [8]u8 = [_]u8{0} ** 8,
    n: usize = 0,

    fn push(self: *Trace, tag: u8) void {
        if (self.n < self.seen.len) {
            self.seen[self.n] = tag;
            self.n += 1;
        }
    }

    fn text(self: *const Trace) []const u8 {
        return self.seen[0..self.n];
    }
};

/// 只记录、然后放行
fn traceNext(ctx: *anyopaque, payload: *abi.EventPayload, next_ctx: *anyopaque, next: abi.NextFn) callconv(.c) abi.Status {
    const t: *Trace = @ptrCast(@alignCast(ctx));
    t.push('A');
    return next(next_ctx, payload);
}

/// 不调 next —— 否决
fn denyNext(ctx: *anyopaque, payload: *abi.EventPayload, next_ctx: *anyopaque, next: abi.NextFn) callconv(.c) abi.Status {
    _ = payload;
    _ = next_ctx;
    _ = next;
    const t: *Trace = @ptrCast(@alignCast(ctx));
    t.push('D');
    return .err_denied;
}

/// 先放行、拿到结果后再改写输出（洋葱模型的「after」）
fn wrapNext(ctx: *anyopaque, payload: *abi.EventPayload, next_ctx: *anyopaque, next: abi.NextFn) callconv(.c) abi.Status {
    const t: *Trace = @ptrCast(@alignCast(ctx));
    t.push('W');
    const st = next(next_ctx, payload);
    if (st != .ok) return st;
    const inner = payload.out();
    var buf: [256]u8 = undefined;
    const wrapped = std.fmt.bufPrint(&buf, "wrapped({s})", .{inner}) catch return .err_too_large;
    payload.setOut(wrapped);
    t.push('w');
    return .ok;
}

fn traceFor(tag: u8) abi.Callback {
    return switch (tag) {
        'A' => traceNext,
        'D' => denyNext,
        'W' => wrapNext,
        else => unreachable,
    };
}

/// 测试用的 fiber（回调里只用它的指针值做 owner 校验，不解引用）。
///
/// ★ `marker` 不能省：没有它，不同 tag 会命中**同一个匿名类型**（于是同一个
///   静态变量、同一个地址），测试里的「别人」就变成了「本人」—— 而断言照样
///   能过，于是这条测试就白写了。
fn ownerStub(comptime tag: u8) *fiber_mod.Fiber {
    const S = struct {
        var fiber: fiber_mod.Fiber = undefined;
        pub const marker: u8 = tag;
    };
    return &S.fiber;
}

var test_iface_blob: u32 = 0;

test "emit: 每个监听器都被调到，谁也不影响谁" {
    const gpa = std.testing.allocator;
    var bus = Bus.init(gpa);
    defer bus.deinit();

    const owner = ownerStub(0);
    var t = Trace{};

    _ = bus.on(.{ .event = "x", .cb = traceNext, .user = @ptrCast(&t), .owner = owner });
    // 中间插一个「否决型」的监听器：emit 里它不该挡住后面的人
    _ = bus.on(.{ .event = "x", .cb = denyNext, .user = @ptrCast(&t), .owner = owner });
    _ = bus.on(.{ .event = "x", .cb = traceNext, .user = @ptrCast(&t), .owner = owner });

    var payload = abi.EventPayload{ .name = "x", .json = "{}" };
    try std.testing.expectEqual(abi.Status.ok, bus.dispatch("x", &payload, .emit));

    // A 记了两次（两个 traceNext），D 一次；顺序就是注册顺序
    try std.testing.expectEqualStrings("ADA", t.text());
    try std.testing.expectEqual(@as(usize, 3), t.n);
}

test "waterfall: 洋葱模型 —— 放行者包在外面，否决者截断后面" {
    const gpa = std.testing.allocator;
    var bus = Bus.init(gpa);
    defer bus.deinit();

    const owner = ownerStub(1);
    var t = Trace{};
    var out_buf: [256]u8 = undefined;

    _ = bus.on(.{ .event = "prompt", .cb = wrapNext, .user = @ptrCast(&t), .owner = owner });
    _ = bus.on(.{ .event = "prompt", .cb = traceNext, .user = @ptrCast(&t), .owner = owner });

    var payload = abi.EventPayload{
        .name = "prompt",
        // 发布方预先写进 out 的就是「默认行为」的结果
        .json = "{}",
        .out_ptr = &out_buf,
        .out_cap = out_buf.len,
    };
    payload.setOut("base");

    try std.testing.expectEqual(abi.Status.ok, bus.dispatch("prompt", &payload, .waterfall));

    // 先 W（外层放行）→ A（内层放行）→ 链尾 → A 返回 → W 改写
    try std.testing.expectEqualStrings("WAw", t.text());
    try std.testing.expectEqualStrings("wrapped(base)", payload.out());
}

test "waterfall: 否决 —— 后面的监听器与默认行为都不执行" {
    const gpa = std.testing.allocator;
    var bus = Bus.init(gpa);
    defer bus.deinit();

    const owner = ownerStub(2);
    var t = Trace{};
    var out_buf: [64]u8 = undefined;

    _ = bus.on(.{ .event = "cmd", .cb = denyNext, .user = @ptrCast(&t), .owner = owner });
    _ = bus.on(.{ .event = "cmd", .cb = traceNext, .user = @ptrCast(&t), .owner = owner });

    var payload = abi.EventPayload{
        .name = "cmd",
        .json = "{}",
        .out_ptr = &out_buf,
        .out_cap = out_buf.len,
    };
    payload.setOut("should-not-change");

    try std.testing.expectEqual(abi.Status.err_denied, bus.dispatch("cmd", &payload, .waterfall));

    // 只有 D 被调到；第二个监听器没跑，out 也没被动过
    try std.testing.expectEqualStrings("D", t.text());
    try std.testing.expectEqualStrings("should-not-change", payload.out());
}

test "撤销按 (id, generation, owner)：别人的、对不上代次的一律不动" {
    const gpa = std.testing.allocator;
    var bus = Bus.init(gpa);
    defer bus.deinit();

    const owner = ownerStub(3);
    const intruder = ownerStub(4);
    var t = Trace{};

    const h = bus.on(.{ .event = "x", .cb = traceNext, .user = @ptrCast(&t), .owner = owner });
    try std.testing.expect(h.id != 0);
    try std.testing.expectEqual(@as(usize, 1), bus.count());
    try std.testing.expectEqual(@as(usize, 1), bus.countFor("x"));

    // 别人拿着正确的 id 来撤 -> 不动
    bus.off(h.id, h.generation, intruder);
    try std.testing.expectEqual(@as(usize, 1), bus.count());
    // 代次对不上 -> 不动
    bus.off(h.id, h.generation + 1, owner);
    try std.testing.expectEqual(@as(usize, 1), bus.count());

    // 本人来撤 -> 撤掉
    bus.off(h.id, h.generation, owner);
    try std.testing.expectEqual(@as(usize, 0), bus.count());
    // 幂等
    bus.off(h.id, h.generation, owner);
    try std.testing.expectEqual(@as(usize, 0), bus.count());
}

test "事件名被拷贝持有：插件那边的原字符串失效后总线仍可用" {
    const gpa = std.testing.allocator;
    var bus = Bus.init(gpa);
    defer bus.deinit();

    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    const plugin_gpa = plugin_arena.allocator();

    const owner = ownerStub(5);
    var t = Trace{};
    const name_in_plugin = try plugin_gpa.dupe(u8, "x");
    _ = bus.on(.{ .event = name_in_plugin, .cb = traceNext, .user = @ptrCast(&t), .owner = owner });

    plugin_arena.deinit(); // 插件内存没了

    try std.testing.expectEqual(@as(usize, 1), bus.countFor("x"));
    var payload = abi.EventPayload{ .name = "x", .json = "{}" };
    try std.testing.expectEqual(abi.Status.ok, bus.dispatch("x", &payload, .emit));
    try std.testing.expectEqualStrings("A", t.text());
}

test "同一事件挂多个监听：编号互不相同、撤销其中一个不影响另一个" {
    const gpa = std.testing.allocator;
    var bus = Bus.init(gpa);
    defer bus.deinit();

    const owner = ownerStub(6);
    var t = Trace{};

    const h1 = bus.on(.{ .event = "x", .cb = traceNext, .user = @ptrCast(&t), .owner = owner });
    const h2 = bus.on(.{ .event = "x", .cb = traceNext, .user = @ptrCast(&t), .owner = owner });
    try std.testing.expect(h1.id != h2.id);
    try std.testing.expectEqual(@as(usize, 2), bus.countFor("x"));

    bus.off(h1.id, h1.generation, owner);
    try std.testing.expectEqual(@as(usize, 1), bus.countFor("x"));
}
