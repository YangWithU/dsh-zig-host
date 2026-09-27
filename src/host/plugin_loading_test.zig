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
const tool_api = @import("dsh_tools");
const fiber_mod = @import("fiber.zig");
const context_mod = @import("context.zig");
const Context = context_mod.Context;
const PluginSlot = context_mod.PluginSlot;

const hello_path = "zig-out/lib/libhello.so";
const tools_path = "zig-out/lib/libtools.so";

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
    // （一等服务 + 两个事件监听 = 三条账）
    try std.testing.expectEqual(@as(usize, 3), slot.fiber.disposers.items.len);

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
    try std.testing.expectEqual(@as(usize, 3), a.fiber.disposers.items.len);

    ctx.unmountPlugin(a);
    try std.testing.expectEqual(@as(usize, 0), ctx.registry.count());
    try std.testing.expectEqual(@as(usize, 0), ctx.fibers.items.len);
}

// ───────────────────────────────────────────────────────────────────────────
//  tools 插件：四个工具真的跑在 .so 里
// ───────────────────────────────────────────────────────────────────────────

/// 从服务表拿工具接口。
/// 按接口约定，第一个字段就是 impl（提供者实例）—— 所以一句就能拿到两个东西。
fn getTools(ctx: *Context) !*const tool_api.ToolsIface {
    const raw = ctx.registry.get(tool_api.SERVICE_NAME, 0) orelse return error.NoToolsService;
    return @ptrCast(@alignCast(raw));
}

test "tools 插件：列得出四个工具，且四个都真能执行" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    _ = try mountOrFail(&ctx, tools_path);
    const tools = try getTools(&ctx);

    // ① 列表：宿主拿到的只有指针，名字与 Schema 全从插件里读
    try std.testing.expectEqual(@as(usize, 4), tools.count(tools.impl));
    var names: [4][]const u8 = undefined;
    for (0..4) |i| {
        const spec = tools.at(tools.impl, i).?;
        names[i] = std.mem.span(spec.name);
        try std.testing.expect(std.mem.span(spec.description).len > 0);
        try std.testing.expect(std.mem.span(spec.parameters_json).len > 0);
    }
    try std.testing.expectEqualStrings("read", names[0]);
    try std.testing.expectEqualStrings("write", names[1]);
    try std.testing.expectEqualStrings("edit", names[2]);
    try std.testing.expectEqualStrings("bash", names[3]);
    try std.testing.expect(tools.at(tools.impl, 4) == null);

    // ② 执行：四个工具依次真跑一遍（全部经由 HostApi 的能力）
    const path = "/tmp/dsh-tools-plugin-test.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var buf: [4096]u8 = undefined;
    var out: tool_api.Buffer = .{ .ptr = &buf, .cap = buf.len };

    out.len = 0;
    try std.testing.expectEqual(abi.Status.ok, tools.execute(
        tools.impl,
        "write",
        "{\"path\":\"" ++ path ++ "\",\"content\":\"alpha\\nbeta\\n\"}",
        &out,
    ));
    try std.testing.expect(std.mem.indexOf(u8, out.slice(), "已写入") != null);

    out.len = 0;
    try std.testing.expectEqual(abi.Status.ok, tools.execute(
        tools.impl,
        "read",
        "{\"path\":\"" ++ path ++ "\"}",
        &out,
    ));
    // 行号格式来自插件里的实现，不是宿主拼的
    try std.testing.expect(std.mem.indexOf(u8, out.slice(), "1\talpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.slice(), "2\tbeta") != null);

    out.len = 0;
    try std.testing.expectEqual(abi.Status.ok, tools.execute(
        tools.impl,
        "edit",
        "{\"path\":\"" ++ path ++ "\",\"oldText\":\"beta\",\"newText\":\"BETA\"}",
        &out,
    ));

    out.len = 0;
    try std.testing.expectEqual(abi.Status.ok, tools.execute(
        tools.impl,
        "read",
        "{\"path\":\"" ++ path ++ "\"}",
        &out,
    ));
    try std.testing.expect(std.mem.indexOf(u8, out.slice(), "BETA") != null);

    out.len = 0;
    try std.testing.expectEqual(abi.Status.ok, tools.execute(
        tools.impl,
        "bash",
        "{\"command\":\"echo from-plugin\"}",
        &out,
    ));
    try std.testing.expect(std.mem.indexOf(u8, out.slice(), "from-plugin") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.slice(), "[exit 0]") != null);

    // ③ 未知工具：不崩，把原因写进 out 让模型看到
    out.len = 0;
    try std.testing.expect(tools.execute(tools.impl, "frobnicate", "{}", &out) != .ok);
    try std.testing.expect(std.mem.indexOf(u8, out.slice(), "未知工具") != null);

    // ④ 参数不合法：同样不崩
    out.len = 0;
    try std.testing.expect(tools.execute(tools.impl, "read", "not json", &out) != .ok);
    try std.testing.expect(out.slice().len > 0);
}

/// hello 插件监听的两个事件（必须与 hello.zig 里的常量一致；宿主编译期不认识
/// 插件代码，所以只能在这里各写一遍 —— 写错了测试就会失败，这是可接受的）。
const ping_event = "demo/ping";
const prompt_event = "demo/prompt";

test "事件总线跨 ABI：回调真的进了插件代码；waterfall 能改写结果" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const slot = try mountOrFail(&ctx, hello_path);

    // 插件 init 里注册的两个监听进了总线
    try std.testing.expectEqual(@as(usize, 2), ctx.bus.count());
    try std.testing.expectEqual(@as(usize, 1), ctx.bus.countFor(ping_event));
    try std.testing.expectEqual(@as(usize, 1), ctx.bus.countFor(prompt_event));
    // 一份服务 + 两个监听 = 三条账
    try std.testing.expectEqual(@as(usize, 3), slot.fiber.disposers.items.len);

    // ① emit：回调研到的是 libhello.so 里的函数（会往日志打一行）
    var ping_payload = abi.EventPayload{ .name = ping_event, .json = "{}" };
    try std.testing.expectEqual(
        abi.Status.ok,
        slot.api.emit(slot.api.ctx, &ping_payload, .emit),
    );

    // ② waterfall：发布方先写「默认行为」，插件在链上把它改写掉
    var out_buf: [256]u8 = undefined;
    var prompt_payload = abi.EventPayload{
        .name = prompt_event,
        .json = "{}",
        .out_ptr = &out_buf,
        .out_cap = out_buf.len,
    };
    prompt_payload.setOut("base prompt");
    try std.testing.expectEqual(
        abi.Status.ok,
        slot.api.emit(slot.api.ctx, &prompt_payload, .waterfall),
    );
    try std.testing.expectEqualStrings("[hello 加料] base prompt", prompt_payload.out());

    // 卸载 -> 服务与监听一起消失
    // （监听回调是插件里的函数地址，必须早于 dlclose 撤掉，否则下次分发就是段错误）
    ctx.unmountPlugin(slot);
    try std.testing.expectEqual(@as(usize, 0), ctx.registry.count());
    try std.testing.expectEqual(@as(usize, 0), ctx.bus.count());
    try std.testing.expectEqual(@as(usize, 0), ctx.fibers.items.len);
}

test "tools 插件：卸载后服务消失、登记表清零" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    const slot = try mountOrFail(&ctx, tools_path);
    try std.testing.expectEqual(@as(usize, 1), ctx.registry.count());
    try std.testing.expectEqual(@as(usize, 1), slot.fiber.disposers.items.len);

    ctx.unmountPlugin(slot);

    try std.testing.expectEqual(@as(usize, 0), ctx.registry.count());
    try std.testing.expect(ctx.registry.get(tool_api.SERVICE_NAME, 0) == null);
    try std.testing.expectEqual(@as(usize, 0), ctx.fibers.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.slots.items.len);
}

test "tools 插件：反复装卸 10 次，每次都能重新拿到可用的工具表" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa, std.testing.io);
    defer ctx.deinit();

    for (0..10) |_| {
        const slot = try mountOrFail(&ctx, tools_path);
        const tools = try getTools(&ctx);
        try std.testing.expectEqual(@as(usize, 4), tools.count(tools.impl));

        var buf: [512]u8 = undefined;
        var out: tool_api.Buffer = .{ .ptr = &buf, .cap = buf.len };
        try std.testing.expectEqual(abi.Status.ok, tools.execute(
            tools.impl,
            "bash",
            "{\"command\":\"echo again\"}",
            &out,
        ));
        try std.testing.expect(std.mem.indexOf(u8, out.slice(), "again") != null);

        ctx.unmountPlugin(slot);
        try std.testing.expectEqual(@as(usize, 0), ctx.registry.count());
    }
}
