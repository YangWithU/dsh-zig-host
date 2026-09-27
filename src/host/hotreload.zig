//! ═══════════════════════════════════════════════════════════════════════════
//!  阶段 4 · HotReload —— 改源码后不重启就生效
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 这是本项目最核心的诉求：插件源码改了，宿主进程不重启就换上新实现。
//!
//! ★ 为什么在 Zig 里这件事是「可行但多一步」
//! ---------------------------------------------------------------------------
//!   Node / Cordis 的链路：文件变化 → 清模块缓存 → import() → 拿到新函数对象
//!                        → 替换注册表里的旧指针
//!   Zig 的链路：          文件变化 → **重新编译 .so** → dlopen → 拿到新指针 → 替换
//!                                    ↑ 多了这一步（Node 是运行时编译，Zig 是 AOT）
//!   「替换函数指针」这件事，两边是**同一个抽象层次的操作**。
//!
//! ★ 状态迁移语义（对齐 Cordis 的 reload）
//! ---------------------------------------------------------------------------
//!   新代码 + 原位置 + 原配置 + 依序回卷旧注册。
//!   顺序即安全性：撤销旧注册必须在 dlclose **之前**（那些注册里存着指向旧
//!   .so 的函数指针，先卸代码再撤销就是跳到别人家里执行 —— 实测段错误）。
//!
//! ★ 三条约定的判据（都有实测支撑）
//! ---------------------------------------------------------------------------
//!   ① mtime/size 只当**粗筛**，只能回答「值不值得跑一次编译」：
//!        touch      会让 mtime 变而内容没变（假阳性）
//!        cp -p/rsync 会让内容变而 mtime 不变（假阴性）
//!   ② 真正的判据是**源码内容指纹**。用它而不是产物指纹，因为要先用它决定
//!      「要不要编译」—— 产物指纹必须先编译才能算，顺序上不可能。
//!   ③ 产物必须落在**没被加载过的新路径**上（名字里带指纹）：
//!        覆盖正在被 dlopen 的 .so → 破坏已映射代码页 → 实测 SIGSEGV
//!        旧句柄未释放就 dlopen 同路径 → 静默拿到旧代码（不报错、不崩）
//!      新路径两个问题一起解决，而且「这代换没换」就变成「这名字我加载过没有」。

const std = @import("std");
const abi = @import("dsh_abi");
const fiber_mod = @import("fiber.zig");
const loader = @import("loader.zig");
// 热重载最终要落地成 Context 上的「拆旧 + 装新」动作，所以它认识 Context。
// 方向是单向的（context 不 import 本文件），没有循环。
const Context = @import("context.zig").Context;

/// 指纹取 BLAKE3 的前 8 字节，转成 16 个十六进制字符。
pub const fp_hex_len = 16;

/// 单次读源码的上限（防呆；正常源码远小于它）。
const max_source_bytes = 8 * 1024 * 1024;
/// 编译输出的捕获上限。
const max_compiler_output = 256 * 1024;
/// 一次编译的超时（秒）。首次冷编译要编译整个 std，给足。
const compile_timeout_s = 300;

/// 一个插件的重载描述。
pub const PluginSpec = struct {
    /// 插件名。必须与 build.zig 里 plugin_names 的名字一致 —— 它决定
    /// 构建 step 名（plugin-<name>）与产物名（lib<name>.so）。
    name: []const u8,

    /// 参与指纹的文件（源码 + 它 import 的共享模块），相对仓库根。
    ///
    /// 为什么显式列出而不是自动扫描依赖：依赖关系归 build.zig 的模块系统管，
    /// 在这里再解析一遍等于写第二份真相。列少了只会「改了共享模块却没重载」，
    /// 列多了只是白重编一次（有缓存，很快）。
    sources: []const []const u8,

    /// 当前运行的这一份的指纹。全 '0' = 还没加载过。
    loaded_fingerprint: [fp_hex_len]u8 = [_]u8{'0'} ** fp_hex_len,

    /// 当前运行的是哪个 fiber（重载成功后由 reloadOnce 更新）。
    current: ?*fiber_mod.Fiber = null,

    /// 重载时传给插件 init 的配置（原样保留，不重新拼）。
    config: [:0]const u8 = "{}",
};

/// 一次重载的结果。
pub const ReloadReport = struct {
    outcome: Outcome,
    /// 编译器输出原文（失败时是唯一有用的东西）
    log: []const u8 = "",
    /// 新产物路径（成功时）
    artifact: []const u8 = "",

    pub const Outcome = enum {
        /// 换上了新实现
        ok,
        /// 源码没变，什么都不用做
        unchanged,
        /// 新代码编译不过 —— 旧实现照常运行
        compile_failed,
        /// 编译过了但校验/加载失败 —— 旧实现照常运行
        load_failed,
        /// 变化与这个插件无关
        skipped,
    };
};

// ───────────────────────────────────────────────────────────────────────────
//  指纹
// ───────────────────────────────────────────────────────────────────────────

/// 算一组文件的合并指纹：把每个文件的「相对路径 + 内容」依次喂给 BLAKE3。
///
/// 读不到的文件不会被跳过，而是把「MISSING + 路径 + 错误名」一起喂进去 ——
/// 否则「文件被删了」会算出一个和「文件还在且内容相同」一样的指纹，
/// 重载就不会发生，而源码明明已经变了。
pub fn fingerprint(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    sources: []const []const u8,
) ![fp_hex_len]u8 {
    var h = std.crypto.hash.Blake3.init(.{});
    const dir = std.Io.Dir.cwd();

    for (sources) |rel| {
        const abs = try std.fs.path.join(gpa, &.{ cwd, rel });
        defer gpa.free(abs);

        const data = dir.readFileAlloc(io, abs, gpa, .limited(max_source_bytes)) catch |e| {
            h.update("MISSING\x00");
            h.update(rel);
            h.update("\x00");
            h.update(@errorName(e));
            h.update("\x00");
            continue;
        };
        defer gpa.free(data);

        h.update(rel);
        // 分隔符不是装饰：没有它，「路径 a + 内容 b」与「路径 ab + 内容空」
        // 会算出同一个指纹。
        h.update("\x00");
        h.update(data);
        h.update("\x00");
    }

    var digest: [32]u8 = undefined;
    h.final(&digest);
    return hexPrefix(digest[0..8]);
}

fn hexPrefix(bytes: []const u8) [fp_hex_len]u8 {
    const digits = "0123456789abcdef";
    var out: [fp_hex_len]u8 = undefined;
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0f];
    }
    return out;
}

// ───────────────────────────────────────────────────────────────────────────
//  编译
// ───────────────────────────────────────────────────────────────────────────

pub const CompileOutcome = struct {
    /// 成功时的产物绝对路径；null = 编译失败
    artifact: ?[]const u8 = null,
    /// 编译器输出（成功时通常为空，失败时是错误原文）。由调用方的分配器持有。
    log: []const u8 = "",
};

/// 编译插件，产物落在「每代一个目录」里，返回它的绝对路径。
///
/// ★ 为什么用 `zig build plugin-<name> --prefix <目录>`，而不是手工拼
///   `zig build-lib -Mroot=... -Mdsh_abi=...`：
///   模块依赖关系已经在 build.zig 里定义好了，在命令行再拼一遍等于第二份真相
///   （实测：漏一个 --dep 就是 "module 'dsh_abi' declared but not used" 报错，
///   而 tools 插件现在依赖三个模块）。另外 zig build 的缓存按内容判定，
///   没有实质改动时会立刻返回。
///
/// ★ 产物必须落在没被加载过的新路径上（目录名里带指纹）：见文件头约定 ③。
pub fn compile(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    name: []const u8,
    fp: [fp_hex_len]u8,
) !CompileOutcome {
    // 用绝对 prefix：cwd 已经决定了 build.zig 在哪，产物路径就不该再依赖它
    const prefix = try std.fmt.allocPrint(gpa, "{s}/zig-out/reload/{s}", .{ cwd, fp });
    defer gpa.free(prefix);

    const step = try std.fmt.allocPrint(gpa, "plugin-{s}", .{name});
    defer gpa.free(step);

    const res = std.process.run(gpa, io, .{
        .argv = &.{ "zig", "build", step, "--prefix", prefix },
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(max_compiler_output),
        .stderr_limit = .limited(max_compiler_output),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromSeconds(compile_timeout_s),
            .clock = .awake,
        } },
    }) catch |e| {
        const msg = try std.fmt.allocPrint(gpa, "无法运行 zig 编译器：{s}", .{@errorName(e)});
        return .{ .artifact = null, .log = msg };
    };

    // stdout/stderr 合并留着：成功时通常为空，失败时它是唯一有用的东西
    const log = try std.mem.concat(gpa, u8, &.{ res.stdout, res.stderr });

    const exit_ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exit_ok) return .{ .artifact = null, .log = log };

    const artifact = try std.fmt.allocPrint(gpa, "{s}/lib/lib{s}.so", .{ prefix, name });
    return .{ .artifact = artifact, .log = log };
}

// ───────────────────────────────────────────────────────────────────────────
//  为什么没有 Watcher
//
//  原设计里有一个轮询 mtime 的 Watcher 做「粗筛」，现在不需要了：判据是源码
//  内容指纹，而算一次指纹只是读几个文件（几十 KB）—— 这点开销远小于它想省掉
//  的那次编译（有缓存时也是几十毫秒起步）。而 Watcher 自己还要维护快照表、
//  处理文件增删、并且要时刻记住「粗筛不等于判据」。判据直接用它自己，
//  不引入中间层。
// ───────────────────────────────────────────────────────────────────────────

// ───────────────────────────────────────────────────────────────────────────
//  一次完整的重载（下一步实现）
// ───────────────────────────────────────────────────────────────────────────

/// poll（粗筛）-> 指纹（判据）-> compile -> inspect -> 拆旧 -> 装新。
///
/// 失败处理是这套流程的重点：
///   · 指纹没变 / 编译失败 / 校验失败 → **什么都不做**，旧实现照常服务
///     （磁盘上那份编译产物丢掉即可，旧文件从头到尾没被碰过）
///   · 走到「拆旧」之后再失败 → 已经没有旧实现可回滚了（旧 .so 已经 dlclose），
///     按「插件暂时消失」处理，等下一次修好再来
pub fn reloadOnce(
    ctx: *Context,
    spec: *PluginSpec,
    io: std.Io,
    arena: std.mem.Allocator,
    cwd: []const u8,
) ReloadReport {
    // ① 判据：源码内容指纹。没变就是真正的「什么都不用做」。
    const fp = fingerprint(arena, io, cwd, spec.sources) catch {
        return .{ .outcome = .skipped };
    };
    if (std.mem.eql(u8, &fp, &spec.loaded_fingerprint)) {
        return .{ .outcome = .unchanged };
    }

    // ② 编译到新路径（目录名带指纹）。失败时旧实现照常跑。
    const out = compile(arena, io, cwd, spec.name, fp) catch {
        return .{ .outcome = .compile_failed };
    };
    if (out.artifact == null) {
        return .{ .outcome = .compile_failed, .log = out.log };
    }
    const artifact = out.artifact.?;

    // ③ 先校验新产物再动旧的：能打开？符号齐？ABI 版本匹配？
    //    这一步通过之前，旧的 .so 连碰都没被碰过。
    {
        var probe = loader.open(artifact) catch {
            return .{ .outcome = .load_failed, .log = out.log, .artifact = artifact };
        };
        loader.close(&probe);
    }

    // ④ 拆旧。走到这里就没有退路了（旧代码即将被卸载）。
    if (spec.current) |old_fiber| {
        if (ctx.slotOfFiber(old_fiber)) |old_slot| {
            ctx.unmountPlugin(old_slot); // 撤销全部注册 -> dlclose -> 释放 arena
        }
        spec.current = null;
    }

    // ⑤ 装新
    const mounted = switch (ctx.mountPlugin(artifact, spec.config)) {
        .ok => |slot| blk: {
            spec.current = slot.fiber;
            break :blk true;
        },
        .failed => false,
    };
    if (!mounted) {
        return .{ .outcome = .load_failed, .artifact = artifact, .log = out.log };
    }

    // 成功之后把**上一代**的产物目录删掉：它已经 dlclose（引用归零），
    // 留着只会让 zig-out/reload/ 每改一次代码就多十几 MB。
    // 首次重载时旧指纹对应的目录并不存在（进程启动时加载的是 zig-out/lib/
    // 里那份），deleteTree 失败忽略即可。
    if (!allZero(spec.loaded_fingerprint)) {
        const old_dir = std.fmt.allocPrint(arena, "{s}/zig-out/reload/{s}", .{
            cwd, &spec.loaded_fingerprint,
        }) catch "";
        if (old_dir.len > 0) std.Io.Dir.cwd().deleteTree(io, old_dir) catch {};
    }

    spec.loaded_fingerprint = fp;
    return .{ .outcome = .ok, .artifact = artifact, .log = out.log };
}

fn allZero(fp: [fp_hex_len]u8) bool {
    for (fp) |c| if (c != '0') return false;
    return true;
}

// ───────────────────────────────────────────────────────────────────────────
//  测试
// ───────────────────────────────────────────────────────────────────────────

test "fingerprint: 内容变了指纹变，内容没变指纹不变，文件消失指纹也变" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = std.Io.Dir.cwd();
    const base = "/tmp/dsh-fingerprint-test";
    dir.deleteTree(io, base) catch {};
    defer dir.deleteTree(io, base) catch {};
    try dir.createDirPath(io, base);

    const f1 = try std.fs.path.join(gpa, &.{ base, "a.zig" });
    defer gpa.free(f1);
    const f2 = try std.fs.path.join(gpa, &.{ base, "b.zig" });
    defer gpa.free(f2);

    try dir.writeFile(io, .{ .sub_path = f1, .data = "const a = 1;\n" });
    try dir.writeFile(io, .{ .sub_path = f2, .data = "const b = 2;\n" });

    const srcs = [_][]const u8{ "a.zig", "b.zig" };

    const fp1 = try fingerprint(gpa, io, base, &srcs);
    // 同样的内容 -> 同样的指纹
    const fp_again = try fingerprint(gpa, io, base, &srcs);
    try std.testing.expectEqualStrings(&fp1, &fp_again);

    // 改一个字节 -> 指纹变
    try dir.writeFile(io, .{ .sub_path = f1, .data = "const a = 9;\n" });
    const fp2 = try fingerprint(gpa, io, base, &srcs);
    try std.testing.expect(!std.mem.eql(u8, &fp1, &fp2));

    // 只改 mtime、内容不变 -> 指纹不变（这正是 mtime 不能当判据的原因）
    try dir.writeFile(io, .{ .sub_path = f1, .data = "const a = 9;\n" });
    const fp3 = try fingerprint(gpa, io, base, &srcs);
    try std.testing.expectEqualStrings(&fp2, &fp3);

    // 删掉一个文件 -> 指纹变（而不是静默地与「文件还在」算出同一个值）
    try dir.deleteFile(io, f2);
    const fp4 = try fingerprint(gpa, io, base, &srcs);
    try std.testing.expect(!std.mem.eql(u8, &fp3, &fp4));
}

test "fingerprint: 喂入顺序会影响结果（调用方应保持 sources 顺序稳定）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = std.Io.Dir.cwd();
    const base = "/tmp/dsh-fingerprint-order";
    dir.deleteTree(io, base) catch {};
    defer dir.deleteTree(io, base) catch {};
    try dir.createDirPath(io, base);

    const f1 = try std.fs.path.join(gpa, &.{ base, "x.zig" });
    defer gpa.free(f1);
    const f2 = try std.fs.path.join(gpa, &.{ base, "y.zig" });
    defer gpa.free(f2);
    try dir.writeFile(io, .{ .sub_path = f1, .data = "x\n" });
    try dir.writeFile(io, .{ .sub_path = f2, .data = "y\n" });

    // 同一顺序 -> 同一指纹
    const fp_a = try fingerprint(gpa, io, base, &.{ "x.zig", "y.zig" });
    const fp_a2 = try fingerprint(gpa, io, base, &.{ "x.zig", "y.zig" });
    try std.testing.expectEqualStrings(&fp_a, &fp_a2);

    // 换一种排列 -> 不同指纹。指纹是按喂入顺序累积的，这条测试固化的是
    // **实际行为**：调用方必须每次用同一个顺序，否则会把「顺序变了」误判成
    // 「源码变了」，每轮都白白重编一次。
    const fp_b = try fingerprint(gpa, io, base, &.{ "y.zig", "x.zig" });
    try std.testing.expect(!std.mem.eql(u8, &fp_a, &fp_b));
}

test "compile: 真的编出一个产物，且它能通过 loader 的 ABI 校验" {    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);

    const sources = [_][]const u8{ "src/plugins/tools.zig", "src/tool_api.zig", "src/abi.zig" };
    const fp = try fingerprint(gpa, io, cwd, &sources);

    const out = try compile(gpa, io, cwd, "tools", fp);
    defer {
        if (out.artifact) |a| gpa.free(a);
        gpa.free(out.log);
    }

    if (out.artifact == null) {
        std.debug.print("[compile] 编译失败，编译器输出：\n{s}\n", .{out.log});
        return error.CompileFailed;
    }

    // 产物必须存在，而且能被 loader 打开（符号齐、ABI 版本匹配）
    var loaded = try loader.open(out.artifact.?);
    defer loader.close(&loaded);
}

test "reloadOnce: 指纹没变 -> unchanged，不碰正在运行的实例" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var ctx = Context.init(gpa, io);
    defer ctx.deinit();

    const sources = [_][]const u8{ "src/plugins/tools.zig", "src/tool_api.zig", "src/abi.zig" };
    const fp = try fingerprint(arena_state.allocator(), io, cwd, &sources);

    const slot = switch (ctx.mountPlugin("zig-out/lib/libtools.so", "{}")) {
        .ok => |s| s,
        .failed => |st| {
            std.debug.print("挂载失败：{s}\n", .{@tagName(st)});
            return error.MountFailed;
        },
    };

    var spec = PluginSpec{
        .name = "tools",
        .sources = &sources,
        .loaded_fingerprint = fp,
        .current = slot.fiber,
    };

    const r = reloadOnce(&ctx, &spec, io, arena_state.allocator(), cwd);
    try std.testing.expectEqual(ReloadReport.Outcome.unchanged, r.outcome);
    // 原来的实例还在、服务还在：unchanged 就是真的没动过任何东西
    try std.testing.expectEqual(@as(usize, 1), ctx.registry.count());
    try std.testing.expect(spec.current == slot.fiber);
    try std.testing.expectEqual(fiber_mod.State.active, slot.fiber.state);
}

test "reloadOnce: 指纹变了 -> 真的拆旧装新（服务表干净、换代）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var ctx = Context.init(gpa, io);
    defer ctx.deinit();

    const sources = [_][]const u8{ "src/plugins/tools.zig", "src/tool_api.zig", "src/abi.zig" };
    const slot = switch (ctx.mountPlugin("zig-out/lib/libtools.so", "{}")) {
        .ok => |s| s,
        .failed => |st| {
            std.debug.print("挂载失败：{s}\n", .{@tagName(st)});
            return error.MountFailed;
        },
    };
    const old_id = slot.fiber.id;

    // 把「已加载的指纹」写成一个不可能的值，等价于「源码变了」——
    // 这样不必真去改工作区里的源码就能驱动整条重载流程。
    var spec = PluginSpec{
        .name = "tools",
        .sources = &sources,
        .loaded_fingerprint = [_]u8{'0'} ** fp_hex_len,
        .current = slot.fiber,
    };

    const r = reloadOnce(&ctx, &spec, io, arena_state.allocator(), cwd);
    if (r.outcome != .ok) {
        std.debug.print("重载失败（{s}）：\n{s}\n", .{ @tagName(r.outcome), r.log });
        return error.ReloadFailed;
    }

    // 换代了：fiber id 不同、新的处于 active
    try std.testing.expect(spec.current != null);
    try std.testing.expect(spec.current.?.id != old_id);
    try std.testing.expectEqual(fiber_mod.State.active, spec.current.?.state);

    // ★ 关键：服务表里恰好一行，登记表恰好一个 fiber/slot
    //   （旧的全被撤销、dlclose、销毁干净了）
    try std.testing.expectEqual(@as(usize, 1), ctx.registry.count());
    try std.testing.expectEqual(@as(usize, 1), ctx.fibers.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.slots.items.len);

    // 记下来的指纹更新了 -> 再跑一次就是 unchanged
    const r2 = reloadOnce(&ctx, &spec, io, arena_state.allocator(), cwd);
    try std.testing.expectEqual(ReloadReport.Outcome.unchanged, r2.outcome);
}
