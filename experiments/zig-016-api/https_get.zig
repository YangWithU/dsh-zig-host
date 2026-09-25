// 问题: Zig 0.16 能否直接发出 HTTPS 请求（DeepSeek 聊天端点）？
// 结论: 可以，一次跑通。Client 自带 ca_bundle，系统根证书自动加载，不用手动指定路径。
//       完整形状见下方 main。
// 怎么复现: zig build-exe https_get.zig -lc -femit-bin=https_get && ./https_get
//          （需要 DEEPSEEK_API_KEY 环境变量）
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const key = init.environ_map.get("DEEPSEEK_API_KEY") orelse {
        std.debug.print("未设置 DEEPSEEK_API_KEY，跳过\n", .{});
        return;
    };

    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{key});
    const payload =
        \\{"model":"deepseek-flash","messages":[{"role":"user","content":"reply with one word: pong"}],"max_tokens":16}
    ;

    const res = try client.fetch(.{
        .location = .{ .url = "https://api.deepseek.com/chat/completions" },
        .method = .POST,
        .payload = payload,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth },
        },
        .response_writer = &aw.writer,
    });

    std.debug.print("status = {d}\n", .{@intFromEnum(res.status)});
    const body = aw.written();
    std.debug.print("body({d} 字节) = {s}\n", .{ body.len, body[0..@min(body.len, 400)] });
}
