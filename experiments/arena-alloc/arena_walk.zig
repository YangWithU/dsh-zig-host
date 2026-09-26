// 问题: std.heap.ArenaAllocator.alloc() 内部那条四级流程（1 快路径 bump → 2 就地扩容 →
//       3 复用空闲 chunk → 4 找子分配器要新 chunk）分别在什么条件下被走到？
//       对齐填充浪费多少字节？free() 对 Arena 究竟做了什么？
// 结论: 见运行输出（下方断言即结论）：
//       · 单线程下 `free_list` 恒为空 —— 第 3 级是「多线程抢挂链表失败后留下的多余 chunk」
//         的回收站，本文件用「手工塞一个节点进 free_list」的方式把这一级单独验证了一遍。
//       · bump 失败时 end_index 会永久停在高位（可以超过 buf_len），那块尾部空间再也回不来。
//       · free() 只对「当前 head chunk 的最后一次分配」真的回退 end_index，乱序释放一律空操作。
//       · 新 chunk 尺寸 = alignForward(1.5 × (上一个 chunk 可用容量 + 本次需求 + 头部 + 16), 2)。
// 怎么复现: cd experiments/arena-alloc && zig run arena_walk.zig
//
// 注意: `Node` 类型在 std 里不是 pub，这里用字段等价的 extern struct 去读它，
//       只为打印/构造观察，不依赖任何 std 内部函数。
const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;

/// 与 std 内部 `Node` 字段一一对应（size 在 std 里是 packed struct(usize)，
/// 最低位是 resizing 标志，这里按 usize 读、自己屏蔽最低位）。
const Hdr = extern struct { size: usize, end_index: usize, next: ?*anyopaque };

// ── 会记账的「子分配器」，用来观察 arena 到底向它要了什么 ────────────────────
const Probe = struct {
    child: std.mem.Allocator,
    verbose: bool = false,
    live: usize = 0,
    n_alloc: usize = 0,
    n_resize_ok: usize = 0,
    n_resize_no: usize = 0,
    n_free: usize = 0,

    const vt: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn allocator(self: *Probe) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vt };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ra);
        if (p != null) {
            self.n_alloc += 1;
            self.live += len;
        }
        if (self.verbose) std.debug.print("        [child] rawAlloc(len={d}) -> {s}\n", .{ len, if (p != null) "ok" else "null (OOM)" });
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        const ok = self.child.rawResize(memory, alignment, new_len, ra);
        if (ok) {
            self.n_resize_ok += 1;
            self.live = self.live - memory.len + new_len;
        } else {
            self.n_resize_no += 1;
        }
        if (self.verbose) std.debug.print("        [child] rawResize({d} -> {d}) -> {s}\n", .{ memory.len, new_len, if (ok) "ok" else "拒绝" });
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, new_len, ra);
        if (p != null) self.live = self.live - memory.len + new_len;
        if (self.verbose) std.debug.print("        [child] rawRemap({d} -> {d}) -> {s}\n", .{ memory.len, new_len, if (p != null) "ok" else "拒绝" });
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.n_free += 1;
        self.live -= memory.len;
        if (self.verbose) std.debug.print("        [child] rawFree(len={d})\n", .{memory.len});
        self.child.rawFree(memory, alignment, ra);
    }
};

// ── 观察 arena 内部链表 ────────────────────────────────────────────────────
var g_arena: *ArenaAllocator = undefined;
var g_verbose: bool = false;

fn castNode(p: anytype) ?*const Hdr {
    return if (p) |q| @ptrCast(@alignCast(q)) else null;
}
fn castNext(p: ?*anyopaque) ?*const Hdr {
    return if (p) |q| @ptrCast(@alignCast(q)) else null;
}
fn listStat(first: ?*const Hdr) struct { count: usize, capacity: usize } {
    var count: usize = 0;
    var capacity: usize = 0;
    var it = first;
    while (it) |n| : (it = castNext(n.next)) {
        count += 1;
        capacity += (n.size & ~@as(usize, 1)) - @sizeOf(Hdr);
    }
    return .{ .count = count, .capacity = capacity };
}

fn dump(tag: []const u8) void {
    if (!g_verbose) return;
    std.debug.print("  ▸ {s}\n", .{tag});
    const lists = [_]struct { name: []const u8, head: ?*const Hdr }{
        .{ .name = "used", .head = castNode(g_arena.state.used_list) },
        .{ .name = "free", .head = castNext(g_arena.state.free_list) },
    };
    for (lists) |l| {
        const st = listStat(l.head);
        if (st.count == 0) {
            std.debug.print("     {s}[] 空\n", .{l.name});
            continue;
        }
        std.debug.print("     {s}: {d} 个 chunk，可用容量共 {d} 字节\n", .{ l.name, st.count, st.capacity });
        var it = l.head;
        var i: usize = 0;
        while (it) |n| : (i += 1) {
            const size = n.size & ~@as(usize, 1);
            std.debug.print("        {s}[{d}] node=0x{x} size={d} buf_len={d} end_index={d}{s}\n", .{
                l.name, i, @intFromPtr(n), size, size - @sizeOf(Hdr), n.end_index,
                if (n.size & 1 == 1) "  <resizing>" else "",
            });
            it = castNext(n.next);
        }
    }
}

fn head() *const Hdr {
    return @ptrCast(g_arena.state.used_list.?);
}

/// 指针落在某个 chunk 的 buffer 里的偏移。
fn off(node: *const Hdr, p: [*]u8) usize {
    return @intFromPtr(p) - (@intFromPtr(node) + @sizeOf(Hdr));
}

fn whereIs(p: [*]u8) void {
    if (!g_verbose) return;
    var it = castNode(g_arena.state.used_list);
    while (it) |n| : (it = castNext(n.next)) {
        const size = n.size & ~@as(usize, 1);
        if (@intFromPtr(p) >= @intFromPtr(n) + @sizeOf(Hdr) and @intFromPtr(p) < @intFromPtr(n) + size)
            std.debug.print("      → 指针在 used[0x{x}] 的缓冲区偏移 {d}\n", .{ @intFromPtr(n), off(n, p) });
    }
}

var failures: usize = 0;
fn check(cond: bool, label: []const u8) void {
    if (cond) {
        std.debug.print("   [OK]   {s}\n", .{label});
    } else {
        failures += 1;
        std.debug.print("   [FAIL] {s}\n", .{label});
    }
}

fn worker(a: std.mem.Allocator) void {
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        _ = a.alloc(u8, 1 + (i % 64)) catch return;
    }
}

pub fn main() void {
    std.debug.print("std 的 Node 头部 = {d} 字节（本文件按同尺寸的 Hdr 读它）\n\n", .{@sizeOf(Hdr)});

    // ═══ A. 单线程四级流程走一遍 ═══════════════════════════════════════════
    std.debug.print("════ A. 单线程：一次分配走哪一级 ════\n", .{});
    g_verbose = true;
    var probe_a: Probe = .{ .child = std.heap.page_allocator, .verbose = true };
    var arena_a = ArenaAllocator.init(probe_a.allocator());
    g_arena = &arena_a;
    const a = arena_a.allocator();

    dump("初始：两条链表都空");
    const p1 = a.alloc(u8, 100) catch unreachable;
    dump("① alloc(u8,100)：used 空 → 跳过 1/2/3 级，第 4 级向子分配器要新 chunk");
    check(probe_a.n_alloc == 1, "第 1 次分配只发生了一次 rawAlloc");
    check(off(head(), p1.ptr) == 0 and head().end_index == 100, "① 落在偏移 0，end_index=100");

    const p2 = a.alloc(u8, 50) catch unreachable;
    dump("② alloc(u8,50)：end_index 100+50=150 ≤ buf_len 188 → 第 1 级 bump 直接成交");
    check(off(head(), p2.ptr) == 100 and head().end_index == 150, "② 落在偏移 100，end_index=150，没有再要 chunk");
    check(probe_a.n_alloc == 1 and probe_a.n_resize_no == 0, "② 没碰子分配器");

    const p3 = a.alloc(u8, 10) catch unreachable;
    dump("③ alloc(u8,10)：同样走第 1 级");
    check(off(head(), p3.ptr) == 150 and head().end_index == 160, "③ 落在偏移 150，end_index=160");

    // 乱序释放：先放最早的 → 空操作
    a.free(p1);
    dump("④ free(最早的 p1)：不是最后一次分配 → 空操作");
    check(head().end_index == 160, "④ end_index 仍是 160，什么都没发生");

    a.free(p3);
    dump("⑤ free(最后的 p3)：这次是最后一次分配 → end_index 真的回退");
    check(head().end_index == 150, "⑤ end_index 160 → 150");

    a.free(p2);
    dump("⑥ free(p2)：此时 p2 又成了最后一次分配");
    check(head().end_index == 100, "⑥ end_index 150 → 100");

    const p4 = a.alloc(u8, 170) catch unreachable;
    dump("⑦ alloc(u8,170)：100+170=270 > buf_len 188 → bump 失败 → 第 2 级就地扩容成交，地址没变");
    check(off(head(), p4.ptr) == 270, "⑦ 落在同一个 chunk 的偏移 270");
    check(probe_a.n_alloc == 1 and probe_a.n_resize_ok == 1, "⑦ 走的是第 2 级：rawResize 成功，没有新开 chunk");
    check(head().end_index == 440, "⑦ end_index = 270+170 = 440，把扩容来的空间用满了");

    const p5 = a.alloc(u8, 4000) catch unreachable;
    dump("⑧ alloc(u8,4000)：bump 失败 → 扩容被拒 → free 空 → 第 4 级向子分配器要新 chunk");
    check(probe_a.n_alloc == 2 and probe_a.n_resize_no >= 1, "⑧ rawResize 被拒，只能新开 chunk");
    check(off(head(), p5.ptr) == 0, "⑧ 落在新 chunk 的偏移 0");
    const old: *const Hdr = @ptrCast(g_arena.state.used_list.?.next.?);
    const old_buf_len = (old.size & ~@as(usize, 1)) - @sizeOf(Hdr);
    std.debug.print("   老 chunk: buf_len {d}，end_index {d}（超出 {d} 字节）\n", .{ old_buf_len, old.end_index, old.end_index - old_buf_len });
    check(old.end_index > old_buf_len, "⑧ 老 chunk 水位线冲过了 buf_len：bump 预占的 4000 字节没还回来，尾部永久作废");
    check(probe_a.n_free == 0, "到此为止 arena 一次都没向子分配器 free 过（arena 不还钱）");

    arena_a.deinit();
    std.debug.print("   deinit 后子分配器存活 = {d} 字节（一次性全还）\n", .{probe_a.live});
    check(probe_a.live == 0, "deinit 把两个 chunk 全部 rawFree 掉");

    // ═══ B. 对齐填充：为什么 bump 要先多占 n+align-1 ═══════════════════════
    std.debug.print("\n════ B. 对齐填充与「把多占的还回去」 ════\n", .{});
    var probe_b: Probe = .{ .child = std.heap.page_allocator };
    var arena_b = ArenaAllocator.init(probe_b.allocator());
    g_arena = &arena_b;
    const b = arena_b.allocator();
    _ = b.alloc(u8, 2) catch unreachable; // end_index = 2
    const q = b.alignedAlloc(u8, .@"8", 1) catch unreachable;
    const h = head();
    std.debug.print("先 alloc(u8,2) → end_index=2；再要 8 字节对齐的 1 字节：\n", .{});
    std.debug.print("   bump 先按 2 + (1+8-1) = 10 预占，实际落在偏移 {d}，end_index = {d}\n", .{ off(h, q.ptr), h.end_index });
    check(off(h, q.ptr) == 8, "满足 8 字节对齐（偏移 2 被向前顶到 8）");
    check(h.end_index == 9, "end_index = 8+1：多占的那 1 字节已被一次 cmpxchg 还掉（否则会是 10）");
    arena_b.deinit();

    // ═══ C. 第 3 级：手工造一个 free_list 节点 ════════════════════════════
    std.debug.print("\n════ C. 第 3 级（复用 free_list）——单线程下只能手工造出来 ════\n", .{});
    var probe_c: Probe = .{ .child = std.heap.page_allocator };
    var arena_c = ArenaAllocator.init(probe_c.allocator());
    g_arena = &arena_c;
    const c = arena_c.allocator();
    const raw_c = probe_c.child.alignedAlloc(u8, .@"8", @sizeOf(Hdr) + 128) catch unreachable;
    const fake: *Hdr = @ptrCast(@alignCast(raw_c.ptr));
    fake.* = .{ .size = @sizeOf(Hdr) + 128, .end_index = 0, .next = null };
    arena_c.state.free_list = @ptrCast(fake); // ← 直接把节点挂进 free_list
    const before_alloc = probe_c.n_alloc;
    const p6 = c.alloc(u8, 64) catch unreachable;
    dump("把 152 字节的节点手工挂进 free_list，然后 alloc(u8,64)");
    check(probe_c.n_alloc == before_alloc, "第 3 级成交：没有向子分配器要新 chunk");
    check(off(fake, p6.ptr) == 0, "复用的正是手工挂进去的那个节点，偏移 0");
    check(fake.end_index == 64, "end_index=64");
    check(head() == fake, "该节点已被挂到 used_list 头");
    check(listStat(castNext(arena_c.state.free_list)).count == 0, "free_list 已被取下（空了）");
    check(probe_c.n_resize_no == 0 and probe_c.n_resize_ok == 0, "第 3 级里节点本来装得下，连 resize 都不用");

    // ═══ D. 多线程：free_list 是「抢挂失败」的回收站 ═══════════════════════
    std.debug.print("\n════ D. 多线程竞争 ════\n", .{});
    g_verbose = false;
    var probe_d: Probe = .{ .child = std.heap.page_allocator };
    var arena_d = ArenaAllocator.init(probe_d.allocator());
    g_arena = &arena_d;
    const d = arena_d.allocator();
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = std.Thread.spawn(.{}, worker, .{d}) catch unreachable;
    for (threads) |t| t.join();
    const used_st = listStat(castNode(arena_d.state.used_list));
    const free_st = listStat(castNext(arena_d.state.free_list));
    std.debug.print("8 线程 × 500 次分配：used {d} 个 chunk / 共 {d} 字节容量；free {d} 个 chunk\n", .{ used_st.count, used_st.capacity, free_st.count });
    std.debug.print("子分配器账本: alloc={d} resize_ok={d} resize_拒绝={d}\n", .{ probe_d.n_alloc, probe_d.n_resize_ok, probe_d.n_resize_no });
    arena_d.deinit();
    std.debug.print("deinit 后子分配器存活 = {d} 字节\n", .{probe_d.live});
    check(probe_d.live == 0, "4000 次并发分配后 deinit 零残留");

    std.debug.print("\n失败断言数 = {d}\n", .{failures});
    if (failures != 0) std.process.exit(1);
}
