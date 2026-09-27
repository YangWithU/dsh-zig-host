const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════
//  构建图 —— 三个「基调」决策固化在这里
// ═══════════════════════════════════════════════════════════════════════════
//
//   决策 1：**ABI 契约是独立的共享模块**（`dsh_abi`）
//          宿主和每个插件都 import 同一份 `src/abi.zig`。
//          为什么必须这样：Zig 的类型在不同编译单元里是「不同的类型」，
//          如果宿主用相对路径包含 abi.zig、插件用另一种方式包含，
//          就会出现「布局相同但在编译器眼里类型不同」的隐患。
//          统一成唯一的模块，是「边界只有一份定义」的物理保证。
//
//   决策 2：**宿主必须链 libc**（`link_libc = true`）
//          实测结论：不链 libc 时 Linux 会走 Zig 自带的 ElfDynLib
//          （纯 Zig 写的 ELF 加载器），加载稍复杂的 .so 后一调用就段错误；
//          链了 libc 才走真正的 dlopen，稳定工作。
//
//   决策 3：**插件是独立的动态库**（`addLibrary(.linkage = .dynamic)`）
//          每个插件单独编译成 .so，宿主运行时按路径加载。
//          这正是热重载的基础：替换磁盘上的 .so → 重新加载 → 新代码生效。
//
// ⚠️ 草图阶段：函数体都是 TODO，`zig build` 能通过编译但没有可运行功能。

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ───────────────────────────────────────────────────────────────────────
    //  决策 1：共享 ABI 契约模块
    // ───────────────────────────────────────────────────────────────────────
    const abi_mod = b.addModule("dsh_abi", .{
        .root_source_file = b.path("src/abi.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 工具能力的跨边界形状：宿主与工具插件共享同一份（见 src/tool_api.zig）。
    const tools_api_mod = b.addModule("dsh_tools", .{
        .root_source_file = b.path("src/tool_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dsh_abi", .module = abi_mod },
        },
    });

    // 示例服务接口：宿主与用它的插件共享同一份类型定义。
    // 单独成模块，而不是塑进 dsh_abi —— dsh_abi 只放每个插件都要用的通用
    // 契约（Handle / Status / HostApi），具体服务的接口布局各自成模块，
    // 这样加一个新服务不需要动 ABI。
    const greeter_mod = b.addModule("dsh_greeter", .{
        .root_source_file = b.path("src/example/greeter.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ───────────────────────────────────────────────────────────────────────
    //  宿主可执行文件
    // ───────────────────────────────────────────────────────────────────────
    const host_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dsh_abi", .module = abi_mod },
            .{ .name = "dsh_tools", .module = tools_api_mod },
        },
    });
    // 决策 2：必须链 libc，否则动态加载会段错误（见文件头说明）
    host_mod.link_libc = true;

    const host = b.addExecutable(.{
        .name = "dsh_zig",
        .root_module = host_mod,
    });
    b.installArtifact(host);

    // ───────────────────────────────────────────────────────────────────────
    //  决策 3：插件 = 独立 .so
    //
    //  加一个插件 = 在这里加一个名字。宿主不需要重新编译。
    //  （将来若要「加载运行时才知道的插件」，只需让宿主扫描目录，
    //    不需要改这里的任何代码——这就是决策 3 的价值。）
    // ───────────────────────────────────────────────────────────────────────
    const plugin_names = [_][]const u8{ "hello", "tools" };
    for (plugin_names) |name| {
        const pmod = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/plugins/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dsh_abi", .module = abi_mod },
                .{ .name = "dsh_greeter", .module = greeter_mod },
                .{ .name = "dsh_tools", .module = tools_api_mod },
            },
        });
        pmod.link_libc = true;

        const lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = name,
            .root_module = pmod,
        });
        b.installArtifact(lib);

        // 单独构建并安装某一个插件。热重载用它：
        //   · 只编译目标插件，不碰宿主
        //   · 配合 `--prefix <每代一个目录>`，产物不会覆盖任何已加载的文件
        //     （覆盖正在被 dlopen 的 .so 会直接段错误，已实测）
        const only_this = b.step(
            b.fmt("plugin-{s}", .{name}),
            b.fmt("只构建并安装 {s} 插件（热重载用）", .{name}),
        );
        only_this.dependOn(&b.addInstallArtifact(lib, .{}).step);
    }

    // ───────────────────────────────────────────────────────────────────────
    //  zig build run
    // ───────────────────────────────────────────────────────────────────────
    const run_step = b.step("run", "运行宿主");
    const run_cmd = b.addRunArtifact(host);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ───────────────────────────────────────────────────────────────────────
    //  zig build test
    //
    //  阶段 1 的验收测试将放在这里，命题是：
    //      「挂载插件 → 注册 N 项 → 卸载 → 确认 N 项全部撤销且无残留」
    //  这条测试通过之前，后面的阶段都建立在不安全的地基上。
    // ───────────────────────────────────────────────────────────────────────
    const abi_tests = b.addTest(.{ .root_module = abi_mod });
    const test_step = b.step("test", "运行测试");
    test_step.dependOn(&b.addRunArtifact(abi_tests).step);

    // agent 目录的测试（MVP 部分）。各文件的 test 由 tests.zig 聚合。
    const agent_test_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dsh_abi", .module = abi_mod },
            .{ .name = "dsh_tools", .module = tools_api_mod },
        },
    });
    agent_test_mod.link_libc = true;
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = agent_test_mod })).step);

    // host 目录的测试（插件内核）。各文件的 test 由 tests.zig 聚合。
    //
    // 阶段 1 的验收命题在这里兑现：
    //     「挂载插件 -> 注册 N 项 -> 卸载 -> 确认 N 项全部撤销且无残留」
    // 这条测试通过之前，后面的阶段都建立在不安全的地基上。
    const host_test_mod = b.createModule(.{
        .root_source_file = b.path("src/host/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dsh_abi", .module = abi_mod },
            .{ .name = "dsh_greeter", .module = greeter_mod },
            .{ .name = "dsh_tools", .module = tools_api_mod },
        },
    });
    host_test_mod.link_libc = true;
    const host_tests = b.addRunArtifact(b.addTest(.{ .root_module = host_test_mod }));
    // 集成测试要 dlopen zig-out/lib/libhello.so，所以先把插件构建出来。
    // （顺序有保证：install 先跑完，测试才启动。）
    host_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&host_tests.step);
}
