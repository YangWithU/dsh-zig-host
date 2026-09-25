const std = @import("std");

// 实验用：编出两个版本的插件 .so（v0.1 与 v0.2），供 dlopen-reload/walk.py 使用。
// 怎么复现: 在本目录跑 `zig build`，产物在 zig-out/lib/lib{v01,v02}.so
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    for ([_][]const u8{ "v01", "v02" }) |n| {
        const m = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/plugin_{s}.zig", .{n})),
            .target = target,
            .optimize = optimize,
        });
        m.link_libc = true;
        b.installArtifact(b.addLibrary(.{
            .linkage = .dynamic,
            .name = n,
            .root_module = m,
        }));
    }
}
