//! host 目录的测试聚合入口。
//!
//! Zig 只运行「从根文件可达」的测试，所以每个文件都要在这里被 @import 一次。
//! 加一个新文件就加一行。

test {
    _ = @import("services.zig");
    _ = @import("loader.zig");
    _ = @import("fiber.zig");
    _ = @import("events.zig");
    _ = @import("context.zig");
    _ = @import("hotreload.zig");
    _ = @import("plugin_loading_test.zig");
}
