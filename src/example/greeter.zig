//! 示例服务接口：宿主与插件共享的类型定义。
//!
//! 它演示「跨 ABI 的服务接口长什么样」，三条规矩：
//!   · extern struct —— 布局在两个编译单元里必须完全一致
//!   · 全是函数指针，第一个参数是提供者的 impl 指针（调用方传回来）
//!   · callconv(.c)
//!
//! 为什么不放进 dsh_abi：dsh_abi 只放**每个插件都要用**的通用契约
//! （Handle / Status / HostApi / Callback）。具体某个服务的接口布局各自成
//! 模块，由宿主与用它的插件共同 import —— 这样加一个新服务不需要动 ABI。
//!
//! 它由 build.zig 注册成模块 `dsh_greeter`。

const std = @import("std");

/// 服务名。宿主按这个名字查表，所以两边必须用同一个常量而不是各写一遍字符串。
pub const NAME = "greeter";

/// 接口表：一个函数指针。真实服务在这里列出它全部的方法。
pub const GreeterIface = extern struct {
    /// 打个招呼。返回值的用途见 hello.zig 的 GREET_MAGIC。
    greet: *const fn (impl: *anyopaque) callconv(.c) u32,
};
