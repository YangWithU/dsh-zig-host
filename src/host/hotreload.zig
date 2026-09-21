//! ═══════════════════════════════════════════════════════════════════════════
//!  阶段 4 · HotReload —— 改源码后不重启就生效         【草图 / 空壳】
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! 这是本项目最核心的诉求：插件源码改了，宿主进程不重启就换上新实现。
//!
//! ★ 为什么在 Zig 里这件事是「可行但有额外一步」
//! ---------------------------------------------------------------------------
//!   Node / Cordis 的完整链路：
//!       文件变化 → 清模块缓存 → import() → 拿到新函数对象 → 替换注册表里的旧指针
//!
//!   Zig 的对应链路：
//!       文件变化 → ★ 重新编译 .so → dlopen → 拿到新函数指针 → 替换
//!                              ↑
//!                    多了这一步（Node 里是运行时解释/编译，Zig 是 AOT）
//!
//!   「替换函数指针」这件事，两边是**同一个抽象层次的操作**，
//!   已实测：同进程内替换 .so 文件后重新 dlopen，拿到的是新代码。
//!
//! ★ 状态迁移语义（对齐 Cordis 的 reload）
//! ---------------------------------------------------------------------------
//!     新代码 + 原位置 + 原配置 + 依序回卷旧注册
//!
//!   具体到 Zig：
//!     1. 撤销旧 fiber 的全部注册（逆序）—— 必须在 dlclose 之前
//!     2. dlclose 旧 .so
//!     3. 编译新 .so（失败则恢复旧实现，不能让插件凭空消失）
//!     4. dlopen 新 .so，挂在**同一个 parent** 下，用**同一份 raw config**
//!     5. 重放依赖检查（依赖可能变了）
//!
//! ⚠️ 空壳。

const std = @import("std");
const abi = @import("dsh_abi");
const fiber_mod = @import("fiber.zig");
const loader = @import("loader.zig");

/// 一次重载的结果。
pub const ReloadReport = struct {
    outcome: Outcome,
    /// 编译错误的原文（编译失败时最有用的东西）
    compiler_output: []const u8 = "",
    elapsed_ms: u64 = 0,

    pub const Outcome = enum {
        ok, // 换上了新实现
        compile_failed, // 新代码编译不过 —— 保留旧实现，宿主继续跑
        load_failed, // 编译过了但加载失败 —— 已恢复旧实现
        skipped, // 变化与插件无关
    };
};

/// 监视器：盯住插件源码目录。
///
/// 实现选型（草图先不定死）：
///   a. inotify(Syscall)  ——Linux 原生，无依赖，但要自己处理 rename/编辑器写临时文件等
///   b. 轮询 mtime        ——最笨最稳，插件数量少时完全够用，且能跨平台
/// 建议先用 (b)：源码文件只有几个，100ms 轮询的开销可以忽略，
/// 而且避免了编辑器「写临时文件再原子改名」导致的漏事件。
pub const Watcher = struct {
    gpa: std.mem.Allocator,
    /// 被监视的插件源码根目录
    roots: []const []const u8,
    /// 上次见到的 (path, mtime, size) 快照
    snapshot: std.StringHashMap(FileStamp),

    pub const FileStamp = struct { mtime: i128, size: u64 };

    pub fn init(gpa: std.mem.Allocator, roots: []const []const u8) Watcher {
        _ = gpa;
        _ = roots;
        @panic("TODO: 阶段 4 —— 建立初始快照");
    }

    /// 扫一轮，返回变化的文件列表（空表示无变化）。
    pub fn poll(self: *Watcher, io: std.Io) []const []const u8 {
        _ = self;
        _ = io;
        @panic("TODO: 阶段 4 —— 比对 mtime/size，返回差异");
    }
};

/// 把「源码路径」映射到「该重编译成哪个 .so、对应哪个 fiber」。
///
/// 为什么需要映射：源码改了要重新编译，但宿主需要知道编译产物对应哪个
/// 正在运行的 fiber。草图用一个简单的清单表达，将来可以扩展成配置驱动。
pub const PluginSpec = struct {
    /// 源码路径（监视这个）
    source_path: []const u8,
    /// 编译产物路径（版本化命名，如 plugin_0007.so）
    output_path: []const u8,
    /// 当前运行的是哪一份
    current: ?*fiber_mod.Fiber = null,
};

/// 调用 `zig build-lib` 编译插件。
///
/// ★ 这里正好用得上 bash 能力：宿主 fork/exec zig 编译器，捕获 stderr。
///   编译失败**必须**保留旧实现并继续服务（不能因为改坏一行代码就整个宿主退出）。
///
/// 用法草图：
///     zig build-lib -dynamic -fPIC --name <name> <source> -lc
/// （-lc 是实测结论：不链 libc 时动态加载会段错误）
pub fn compile(spec: *const PluginSpec, arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    _ = spec;
    _ = arena;
    _ = io;
    @panic("TODO: 阶段 4 —— fork/exec zig build-lib，捕获输出，返回编译日志");
}

/// 一次完整的「改代码 → 生效」循环。
///
/// 步骤与失败处理：
///   1. poll() 拿到变化文件
///   2. 映射到受影响的 PluginSpec（无 → skipped）
///   3. compile() —— 失败 → 返回 compile_failed，**旧实现照常运行**
///   4. 旧 fiber 逆序撤销全部注册
///   5. dlclose 旧 .so
///   6. dlopen 新 .so + plugin_init（成功则替换，失败则回滚到旧实现）
///   7. 重放依赖检查 → 可能立刻 active，也可能停在 pending
///
/// ★ 第 4 步和第 5 步的顺序是**安全底线**：
///   实测表明，如果还有监听器指向旧 .so 的代码，dlclose 之后再触发事件
///   就是段错误。所以「撤销必须先于卸载」不是风格问题。
pub fn reloadOnce(w: *Watcher, spec: *PluginSpec, io: std.Io) ReloadReport {
    _ = w;
    _ = spec;
    _ = io;
    @panic("TODO: 阶段 4 —— poll → compile → 撤销注册 → dlclose → dlopen → init");
}
