// 实验用插件：只为让 dlopen 有一个足够大的 .so 可加载（Debug、未 strip）。
// 怎么复现:
//   zig build-lib -dynamic -lc --name plug plug.zig -femit-bin=plug.so
//   python3 measure.py
pub export fn plugin_version() callconv(.c) i32 {
    return 1;
}
