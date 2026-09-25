//! 会话日志：把对话逐条追加到 jsonl（一行一个 JSON 对象）。
//!
//! 职责: 留下可复查、可统计的运行记录 —— 谁说了什么、调了哪些工具、花了多少 token。
//! 数据流: Loop 每追加一条消息 -> 同时写一行；会话结束关闭文件。
//! 不变量: ① 一行必须是完整合法的 JSON（内部不换行），这样 grep/jq/awk 可直接处理；
//!         ② 写日志失败只告警，不中断对话 —— 记录是辅助，不该拖垮主流程；
//!         ③ 只追加不重写，历史不能被后来的写入抹掉。
//! 不可简化: 不能把整个会话攒在内存里最后一次性写 —— 崩了或被杀就全丢，
//!           而崩溃现场恰恰是最需要记录的时刻。
//!
//! 落点: <base_dir>/<cwd 里的分隔符换成横线>/<unix 纳秒>.jsonl
//!       base_dir 由调用方给（生产是 $HOME/.dsh/sessions）；取纳秒做文件名
//!       是为了同一秒内多次启动不会互相覆盖。

const std = @import("std");
const llm = @import("llm.zig");

/// 固定 schema 是刻意的：不同消息类型用同一组字段，统计时不必写特判。
pub const ToolCallEntry = struct {
    id: []const u8,
    name: []const u8,
    /// 模型给的参数原文（JSON 文本）
    arguments: []const u8,
};

pub const Log = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// 文件绝对路径（关闭时释放）
    path: []const u8,
    file: std.Io.File,

    /// 建目录、建文件、写头部行。
    /// 失败直接返回错误，由调用方决定要不要继续无日志运行 —— 记录不是硬依赖。
    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        base_dir: []const u8,
        cwd: []const u8,
        model: []const u8,
    ) !Log {
        const started_at = std.Io.Timestamp.now(io, .real).nanoseconds;
        const cwd_dir = std.Io.Dir.cwd();

        // 把 cwd 编成一层目录名：一个项目一个目录，便于按项目统计
        const encoded = try gpa.alloc(u8, cwd.len);
        defer gpa.free(encoded);
        for (cwd, 0..) |c, i| encoded[i] = if (c == '/') '-' else c;

        const dir_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_dir, encoded });
        defer gpa.free(dir_path);
        try cwd_dir.createDirPath(io, dir_path);

        const path = try std.fmt.allocPrint(gpa, "{s}/{d}.jsonl", .{ dir_path, started_at });
        const file = try cwd_dir.createFile(io, path, .{ .truncate = true });

        var self = Log{ .gpa = gpa, .io = io, .path = path, .file = file };
        errdefer self.close();

        try self.writeValue(.{
            .@"type" = "session",
            .version = 1,
            .cwd = cwd,
            .model = model,
            .started_at = started_at,
        });
        return self;
    }

    pub fn close(self: *Log) void {
        self.file.close(self.io);
        self.gpa.free(self.path);
        self.path = &.{};
    }

    /// 追加一条对话消息。token 用量只有 assistant 消息才有意义，其余传 0。
    pub fn appendMessage(
        self: *Log,
        m: llm.Message,
        prompt_tokens: u64,
        completion_tokens: u64,
    ) void {
        // 栈上固定数组：一次回复里的工具调用多不到需要分配；
        // 真超了就截断 —— 记录少几条，好过整条写不进去。
        var calls_buf: [16]ToolCallEntry = undefined;
        const n = @min(m.tool_calls.len, calls_buf.len);
        for (m.tool_calls[0..n], 0..) |c, i| {
            calls_buf[i] = .{ .id = c.id, .name = c.name, .arguments = c.arguments_json };
        }

        self.writeValue(.{
            .@"type" = "message",
            .role = m.role.wire(),
            .content = m.content,
            .tool_call_id = m.tool_call_id,
            .tool_calls = calls_buf[0..n],
            .prompt_tokens = prompt_tokens,
            .completion_tokens = completion_tokens,
        }) catch |e| {
            std.debug.print("[log] 写会话日志失败（{s}），这条记录丢失\n", .{@errorName(e)});
        };
    }

    fn writeValue(self: *Log, value: anytype) !void {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        try std.json.Stringify.value(value, .{}, &aw.writer);
        try aw.writer.writeAll("\n");
        try self.file.writeStreamingAll(self.io, aw.written());
    }
};

// ───────────────────────────────────────────────────────────────────────────
//  测试
// ───────────────────────────────────────────────────────────────────────────

test "每行都是能独立解析的 JSON，类型与字段可读回" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd_dir = std.Io.Dir.cwd();
    const base = "/tmp/dsh-session-log-test";

    cwd_dir.deleteTree(io, base) catch {};

    var log = try Log.create(gpa, io, base, "/repo/proj", "deepseek-flash");
    const path = try gpa.dupe(u8, log.path);
    defer gpa.free(path);

    log.appendMessage(.{ .role = .system, .content = "你是助手" }, 0, 0);
    log.appendMessage(.{ .role = .user, .content = "你好\n带换行" }, 0, 0);
    log.appendMessage(.{
        .role = .assistant,
        .content = "我调个工具",
        .tool_calls = &.{.{ .id = "c1", .name = "bash", .arguments_json = "{\"command\":\"ls\"}" }},
    }, 12, 7);
    log.appendMessage(.{ .role = .tool, .tool_call_id = "c1", .content = "a\nb" }, 0, 0);
    log.close();

    const raw = try cwd_dir.readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(raw);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    var count: usize = 0;
    var saw_session = false;
    var saw_tool_call = false;
    var saw_tool_result = false;
    var saw_usage = false;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        count += 1;

        // 每一行都必须能独立解析 —— 这就是「一行一个 JSON」的全部意义
        const v = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer v.deinit();

        const kind = v.value.object.get("type").?.string;
        if (std.mem.eql(u8, kind, "session")) {
            saw_session = true;
            continue;
        }

        const role = v.value.object.get("role").?.string;
        if (std.mem.eql(u8, role, "assistant")) {
            const calls = v.value.object.get("tool_calls").?.array;
            if (calls.items.len == 1 and
                std.mem.eql(u8, calls.items[0].object.get("name").?.string, "bash") and
                std.mem.eql(u8, calls.items[0].object.get("arguments").?.string, "{\"command\":\"ls\"}"))
            {
                saw_tool_call = true;
            }
            if (v.value.object.get("prompt_tokens").?.integer == 12 and
                v.value.object.get("completion_tokens").?.integer == 7)
            {
                saw_usage = true;
            }
        }
        if (std.mem.eql(u8, role, "tool")) {
            // 换行必须被转义，而不是把一行拆成两行
            if (std.mem.eql(u8, v.value.object.get("content").?.string, "a\nb")) saw_tool_result = true;
        }
    }

    // 头部 1 行 + 4 条消息 = 5 行（内容里的换行被转义，没多出行）
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expect(saw_session);
    try std.testing.expect(saw_tool_call);
    try std.testing.expect(saw_tool_result);
    try std.testing.expect(saw_usage);

    cwd_dir.deleteTree(io, base) catch {};
}
