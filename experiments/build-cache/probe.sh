#!/usr/bin/env bash
# 问题:
#     判断「插件源码变了没」，该用 mtime 还是内容指纹？
#
# 结论 (2026-09-25 实测，zig 0.16.0):
#     什么都不改再编一次            37 ms，产物 hash 与 mtime 都不变（缓存命中，连文件都不重写）
#     只 touch 源文件（内容没变）    37 ms，产物 hash 与 mtime 都不变
#     只改一句注释                  224 ms，产物 hash 变了（Debug 信息里带行号）
#     改一行逻辑                    223 ms，产物 hash 变了
#     => mtime 是假信号：zig 自己的缓存按内容判定，touch 不触发重编。
#     => 「要不要重新编译」交给 zig 缓存回答即可；判断「要不要重载」应该比产物内容指纹（BLAKE3），
#        而不是比源码 mtime。
#
# 怎么复现: bash probe.sh   （在 /tmp 里建一个临时项目，跑完自动删除）
set -euo pipefail

W=$(mktemp -d /tmp/zz-cache-probe.XXXXXX)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/src"

cat > "$W/build.zig" <<'EOF'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const m = b.createModule(.{
        .root_source_file = b.path("src/plug.zig"),
        .target = target, .optimize = optimize,
    });
    m.link_libc = true;
    b.installArtifact(b.addLibrary(.{ .linkage = .dynamic, .name = "plug", .root_module = m }));
}
EOF

cat > "$W/src/plug.zig" <<'EOF'
// v1
pub export fn plugin_version() callconv(.c) i32 {
    return 1;
}
EOF

cd "$W"
snap() {
    local t0 t1
    t0=$(date +%s%N)
    zig build >/dev/null 2>&1
    t1=$(date +%s%N)
    printf '%-26s %6d ms  hash=%s  mtime=%s\n' "$1" $(( (t1 - t0) / 1000000 )) \
        "$(sha256sum zig-out/lib/libplug.so | cut -c1-12)" \
        "$(stat -c '%y' zig-out/lib/libplug.so | cut -c12-23)"
}

snap "1 首次编译"
snap "2 什么都不改"
touch src/plug.zig
snap "3 只 touch"
sed -i 's|// v1|// v1 with a longer comment line|' src/plug.zig
snap "4 只改注释"
sed -i 's/return 1;/return 2;/' src/plug.zig
snap "5 改一行逻辑"
