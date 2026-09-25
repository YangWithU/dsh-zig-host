// 插件 v0.2：版本号变了，并且新增了一个导出函数
pub export fn plugin_version() callconv(.c) i32 {
    return 2;
}

pub export fn plugin_add(a: i32, b: i32) callconv(.c) i32 {
    return a + b;
}

pub export fn plugin_multiply(a: i32, b: i32) callconv(.c) i32 {
    return a * b;
}
