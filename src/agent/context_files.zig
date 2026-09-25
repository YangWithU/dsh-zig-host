//! 收集 AGENTS.md：当前目录 + 所有父目录，作为对话开头的规范。
//!
//! 职责: 让模型一上来就知道这个仓库在哪、怎么构建、有哪些规矩。
//! 数据流: main -> collect() 从工作目录逐级向上找文件 -> render() 拼成一段文本
//!         -> 作为第一条 system 消息的第一段。
//! 不变量: 顺序为「从最外层到最内层」，内层在后 —— 越具体的指令越晚出现，
//!         冲突时以后者为准；每个目录只取一个文件；读不到就跳过，不算错误。
//! 不可简化: 不能只读当前目录那一个文件。仓库根写的规范必须对子目录生效，
//!           否则在子目录里启动就丢掉了全部约束。
//!
//! 接入点: 本模块只负责产出「项目上下文」那一段。完整的第一条 system 消息
//!         由 loop 组装（前言 + 工具说明 + 本段 + 工作目录），见 llm.Message。

const std = @import("std");

/// 每个目录按这个顺序找，取第一个命中的。
/// override 让「临时覆盖」不必改动原文件（删掉即恢复），这一条值得留。
const candidates = [_][]const u8{ "AGENTS.override.md", "AGENTS.md" };

/// 单个文件的大小上限，防止一个巨型文件把上下文灌满。
const max_file_bytes: usize = 64 * 1024;

pub const Entry = struct {
    path: []const u8,
    content: []const u8,
};

/// 从工作目录逐级向上收集，返回顺序为「最外层在前、工作目录自己在最后」。
pub fn collect(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]Entry {
    const cwd = try std.process.currentPathAlloc(io, gpa);

    var list: std.ArrayList(Entry) = .empty;
    var current: ?[]const u8 = cwd;
    while (current) |d| {
        try appendFromDir(gpa, io, dir, d, &list);
        current = std.fs.path.dirname(d);
    }

    // 上面是从内层往外收集的，反转成「外层在前」，让更具体的规则出现在后面。
    std.mem.reverse(Entry, list.items);
    return list.toOwnedSlice(gpa);
}

fn appendFromDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    d: []const u8,
    list: *std.ArrayList(Entry),
) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (candidates) |name| {
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ d, name }) catch continue;
        // 读不到就当这个目录没有它：缺 AGENTS.md 是完全正常的情况
        const content = dir.readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch continue;
        try list.append(gpa, .{ .path = try gpa.dupe(u8, path), .content = content });
        return; // 一个目录只取一个文件
    }
}

/// 拼成给模型看的一段文本。没有命中任何文件时什么都不写（不发空段落）。
///
/// 用 XML 风格标签包住每个文件（pi 的做法，标签名沿用它的 project_instructions）：
///   有明确边界，文件内容里即使出现「忽略以上指令」之类的句子，模型仍能分辨
///   哪些是项目规范、哪些是它自己的任务；path 属性标出来源，多文件冲突时
///   模型知道该听谁。
pub fn render(w: *std.Io.Writer, entries: []const Entry) !void {
    if (entries.len == 0) return;
    try w.writeAll("Project-specific instructions and guidelines:\n\n");
    for (entries, 0..) |e, i| {
        if (i > 0) try w.writeAll("\n\n");
        try w.print("<project_instructions path=\"{s}\">\n{s}\n</project_instructions>", .{ e.path, e.content });
    }
}

test "render: 每个文件包在 project_instructions 里，外层在前" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const entries = [_]Entry{
        .{ .path = "/repo/AGENTS.md", .content = "# 根" },
        .{ .path = "/repo/sub/AGENTS.md", .content = "# 子" },
    };

    var aw: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try render(&aw.writer, &entries);
    const out = aw.written();

    try std.testing.expect(std.mem.startsWith(u8, out, "Project-specific instructions and guidelines:"));
    try std.testing.expect(std.mem.indexOf(u8, out, "<project_instructions path=\"/repo/AGENTS.md\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<project_instructions path=\"/repo/sub/AGENTS.md\">") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "</project_instructions>"));

    const root_at = std.mem.indexOf(u8, out, "/repo/AGENTS.md").?;
    const sub_at = std.mem.indexOf(u8, out, "/repo/sub/AGENTS.md").?;
    try std.testing.expect(root_at < sub_at);
}

test "render: 没有文件时不产出任何内容" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try render(&aw.writer, &.{});
    try std.testing.expectEqual(@as(usize, 0), aw.written().len);
}
