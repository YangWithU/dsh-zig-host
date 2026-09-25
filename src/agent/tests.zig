//! agent 目录的测试入口：把各文件的 test 聚合到一个编译单元。
//!
//! Zig 只编译可达文件，所以必须有一个根把测试拉进来 ——
//! 放在这里而不是散在 main.zig，是为了让测试与 main 的入口解耦。

test {
    _ = @import("tools.zig");
    _ = @import("context_files.zig");
    _ = @import("llm.zig");
    _ = @import("loop.zig");
    _ = @import("session_log.zig");
}
