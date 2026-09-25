// 问题: Zig 0.16 里文件读写与子进程执行怎么写（工具四件套的基础）？
// 结论: 全部可用，但 API 与 0.11–0.15 教程完全不同：
//       · 文件: std.Io.Dir.cwd() + dir.writeFile(io, .{ .sub_path, .data })
//                + dir.readFileAlloc(io, path, gpa, .limited(n))
//       · 子进程: std.process.run(gpa, io, .{ .argv, .timeout = ... }) -> RunResult{ term, stdout, stderr }
//       · 超时: Io.Clock.Duration 是 { raw: Io.Duration, clock: Io.Clock }，clock 用 .awake
//                （没有 .monotonic；Io.Duration 有 fromSeconds 等构造器）
//       · 超时触发时 run 返回 error.Timeout（不是返回一个"被 kill"的 term）
//       · 在测试里起子进程要用 std.testing.io（专供测试的 Io.Threaded 实例）；
//         用 std.Options.debug_io 会让 run 直接失败（bash 工具返回 err_internal），
//         这是被一次真实测试逮到的
// 怎么复现: zig build-exe fs_and_process.zig -lc -femit-bin=fs_and_process && ./fs_and_process
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const dir = std.Io.Dir.cwd();

    try dir.writeFile(io, .{ .sub_path = "probe.txt", .data = "line1\nline2\n" });
    defer dir.deleteFile(io, "probe.txt") catch {};

    const data = try dir.readFileAlloc(io, "probe.txt", gpa, .limited(1 << 20));
    std.debug.print("[file] 读回 {d} 字节: {s}", .{ data.len, data });

    const res = try std.process.run(gpa, io, .{
        .argv = &.{ "bash", "-lc", "echo from-bash; wc -l < probe.txt" },
    });
    std.debug.print("[run] term={any} stdout={s}", .{ res.term, res.stdout });

    if (std.process.run(gpa, io, .{
        .argv = &.{ "bash", "-lc", "sleep 10" },
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromSeconds(1),
            .clock = .awake,
        } },
    })) |r| {
        std.debug.print("[timeout] 意外完成: {any}\n", .{r.term});
    } else |e| {
        std.debug.print("[timeout] 1 秒后按预期失败: {any}\n", .{e});
    }
}
