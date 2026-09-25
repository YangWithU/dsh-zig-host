// 插件 v0.1：没有 plugin_multiply
pub export fn plugin_version() callconv(.c) i32 {
    return 1;
}

pub export fn plugin_add(a: i32, b: i32) callconv(.c) i32 {
    return a + b;
}
