//! ═══════════════════════════════════════════════════════════════════════════
//!  集成测试：真的 dlopen 一个 .so，走完整条装卸链
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 和 context.zig 里的单元测试的区别：那些用 newFiber 手工造实例，验证的是
//! 「注册 -> 记账 -> 撤销」这条链；这里的一切都从磁盘上真实的 libhello.so 来，
//! 验证的是**跨边界**那一段：dlopen、符号查找、ABI 校验、调用插件里的代码。
//!
//! 单独成文件的原因：它依赖示例接口模块（dsh_greeter），而 context.zig 是
//! 产品代码，不该 import 一个示例。
//!
//! 前置：build.zig 里 host 测试依赖了 install step，所以 zig-out/lib/libhello.so
//! 在测试启动前一定已经构建好了。

const std = @import("std");
const abi = @import("dsh_abi");
const greeter = @import("dsh_greeter");
const fiber_mod = @import("fiber.zig");
const context_mod = @import("context.zig");
const Context = context_mod.Context;
const PluginSlot = context_mod.PluginSlot;

const hello_path = "zig-out/lib/libhello.so";

/// hello.zig 里的 GREET_MAGIC，两边必须一致。
/// 写死而不是从插件 import：宿主编译期不认识插件代码，这正是动态加载的意义。
const greet_magic: u32 = 0x9EE7;

fn mountOrFail(ctx: *Context, path: []const u8) !*PluginSlot {
    return switch (ctx.mountPlugin(path, "{}")) {
        .ok => |slot| slot,
        .failed => |st| {
            std.debug.print("[集成测试] 挂载 {s} 失败：{s}\n", .{ path, @tagName(st) });
            return error.MountFailed;
        },
    };
}

test "真加载：dlopen -> init 注册服务 -> 卸载零残留" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const slot = try mountOrFail(&ctx, hello_path);

    // 插件真的跑起来了
    try std.testing.expectEqual(fiber_mod.State.active, slot.fiber.state);
    try std.testing.expectEqualStrings("hello", slot.fiber.name);

    // init 里注册的服务进了表，owner 是这条 fiber
    try std.testing.expectEqual(@as(usize, 1), ctx.registry.count());
    const entry = &ctx.registry.entries.items[0];
    try std.testing.expectEqualStrings(greeter.NAME, entry.name);
    try std.testing.expect(entry.owner == slot.fiber);

    // 记账成对：宿主在注册那一刻就记了一条撤销项
    try std.testing.expectEqual(@as(usize, 1), slot.fiber.disposers.items.len);

    // ★ 真的调用插件里的代码 —— 魔数对得上，证明拿到的是那个 .so 里的函数
    const iface: *const greeter.GreeterIface = @ptrCast(@alignCast(entry.iface));
    try std.testing.expectEqual(greet_magic, iface.greet(entry.impl));

    // 卸载：表空、清单空、登记表也清空
    ctx.unmountPlugin(slot);
    try std.testing.expectEqual(@as(usize, 0), ctx.registry.count());
    try std.testing.expectEqual(@as(usize, 0), ctx.fibers.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.slots.items.len);
}

test "挂载不存在的 .so：明确失败，不留半个插件" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const r = ctx.mountPlugin("zig-out/lib/libdefinitely-not-here.so", "{}");
    const st = switch (r) {
        .ok => return error.ShouldNotLoad,
        .failed => |s| s,
    };
    try std.testing.expectEqual(abi.Status.err_not_found, st);

    // 失败之后什么都没留下 —— 没有 fiber、没有 slot、没有表项
    try std.testing.expectEqual(@as(usize, 0), ctx.fibers.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.slots.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.registry.count());
}

test "反复装卸 15 次：每次结束都零残留，且无内存泄漏" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    // 每一次都必须真正 dlclose 并且撤销干净；testing.allocator 在测试结束
    // 会报告任何未被释放的分配 —— 这条测试同时盯住内存和登记表。
    for (0..15) |i| {
        const slot = try mountOrFail(&ctx, hello_path);
        try std.testing.expectEqual(fiber_mod.State.active, slot.fiber.state);
        try std.testing.expectEqual(@as(usize, 1), ctx.registry.count());

        ctx.unmountPlugin(slot);

        try std.testing.expectEqual(@as(usize, 0), ctx.registry.count());
        try std.testing.expectEqual(@as(usize, 0), ctx.fibers.items.len);
        try std.testing.expectEqual(@as(usize, 0), ctx.slots.items.len);
        _ = i;
    }
}

test "同一个 .so 挂两份：第二份因同名服务被拒 -> 加载失败 -> 完整回滚" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const a = try mountOrFail(&ctx, hello_path);
    try std.testing.expectEqual(@as(usize, 1), ctx.registry.count());

    // 第二份的 init 里会注册同名服务（同名同 scope）—— provide 拒绝它，
    // init 如实返回 err_duplicate，于是整次加载失败。
    // 这条路径正好验证「插件 init 失败必须完整回滚」：
    //   load 内部跑撤销清单 + dlclose + 清 arena，mountPlugin 再从表里摘掉。
    const st = switch (ctx.mountPlugin(hello_path, "{}")) {
        .ok => return error.ShouldNotLoad,
        .failed => |s| s,
    };
    try std.testing.expectEqual(abi.Status.err_duplicate, st);

    // 失败之后什么都没多出来；第一份完全不受影响
    try std.testing.expectEqual(@as(usize, 1), ctx.fibers.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.slots.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.registry.count());
    try std.testing.expectEqual(fiber_mod.State.active, a.fiber.state);
    // 第一份的账也没被动（失败的那份没有往清单里塞任何东西）
    try std.testing.expectEqual(@as(usize, 1), a.fiber.disposers.items.len);

    ctx.unmountPlugin(a);
    try std.testing.expectEqual(@as(usize, 0), ctx.registry.count());
    try std.testing.expectEqual(@as(usize, 0), ctx.fibers.items.len);
}
