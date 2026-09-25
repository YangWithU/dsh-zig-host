// 问题: 解析 DeepSeek 的响应、以及构造请求体（含换行引号转义）该怎么做？
// 结论:
//       · 解析用 std.json.parseFromSlice(T, gpa, raw, .{ .ignore_unknown_fields = true })；
//         必须加 ignore_unknown_fields，否则响应里的 reasoning_content 等字段会报错。
//       · tool_calls[].function.arguments 是**嵌套的 JSON 字符串**，要再解析一次。
//       · 序列化用 std.json.Stringify.value(v, .{}, &writer)，换行/引号/tab 转义正确。
//       · deepseek-flash 是推理模型，响应里可能只有 reasoning_content 而 content 为空，
//         要给它留足 max_tokens。
// 怎么复现: 先用 curl 抓一份真实响应存成 resp.json，再
//          zig build-exe json_roundtrip.zig -lc -femit-bin=json_roundtrip && ./json_roundtrip
const std = @import("std");

const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: struct { name: []const u8, arguments: []const u8 },
};
const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
};
const Choice = struct { index: i64, message: Message, finish_reason: ?[]const u8 = null };
const Response = struct { id: []const u8 = "", choices: []const Choice };

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const dir = std.Io.Dir.cwd();

    const raw = dir.readFileAlloc(io, "resp.json", gpa, .limited(4 << 20)) catch {
        std.debug.print("没有 resp.json，只验证序列化部分\n", .{});
        return stringifyDemo(gpa);
    };

    const parsed = try std.json.parseFromSlice(Response, gpa, raw, .{ .ignore_unknown_fields = true });
    const ch = parsed.value.choices[0];
    std.debug.print("[parse] finish_reason={?s} content={?s}\n", .{ ch.finish_reason, ch.message.content });

    if (ch.message.tool_calls) |tcs| {
        for (tcs) |tc| {
            std.debug.print("[parse] tool_call {s} name={s} arguments={s}\n", .{ tc.id, tc.function.name, tc.function.arguments });
            const args = try std.json.parseFromSlice(std.json.Value, gpa, tc.function.arguments, .{});
            if (args.value.object.get("command")) |cmd| {
                std.debug.print("[parse] 二次解析 arguments -> command = {s}\n", .{cmd.string});
            }
        }
    }
    try stringifyDemo(gpa);
}

fn stringifyDemo(gpa: std.mem.Allocator) !void {
    const buf = try gpa.alloc(u8, 512);
    var w = std.Io.Writer.fixed(buf);
    try std.json.Stringify.value(.{
        .role = "tool",
        .tool_call_id = "call_x",
        .content = "line1\nline\"2\"\tend",
    }, .{}, &w);
    std.debug.print("[stringify] {s}\n", .{w.buffered()});
}
