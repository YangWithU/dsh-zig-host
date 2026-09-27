# dsh_zig

用 Zig 复刻 DSH 的 Cordis 内核（动态插件 + 热重载），并自带一个最小 agent。

本文件同时是运行时输入：`dsh_zig` 启动时会读取它，作为第一条 system 消息的第一段。
所以这里写的规则会直接影响在这个仓库里干活的助手行为。

## 仓库

- 代码根目录 `/home/yang/dsh_zig_impl/zig_impl`（独立 git 仓库，分支 `main`）
- 参考实现 `/home/yang/dsh_zig_impl/deepseek-harness`（第三方 clone，故意不入库，不要修改）

## 构建与验证

```
zig build        # 编译宿主与插件
zig build test   # 跑测试
zig build run    # 运行宿主
```

任何改动之后都要跑通 `zig build`，只改注释也一样。

## Zig 版本约定

工具链是 0.16.0，API 与网上 0.11–0.15 的教程完全不同。以 `/usr/lib/zig/std/` 的源码为准，
不要照抄教程或旧代码。已经踩过的差异：

- `main(init: std.process.Init)`，I/O 一律走 `init.io`（`std.Io`）
- `std.fs.cwd()` 已移除，改用 `std.Io.Dir.cwd()`，且要传 `io`
- 起子进程用 `std.process.run(gpa, io, .{ ... })`
- HTTP 用 `std.http.Client{ .allocator, .io }` 加 `client.fetch(.{ ... })`，系统根证书自动加载
- `std.heap.ArenaAllocator.alloc` 是四级回退：bump 指针 → 原地扩容 → 复用 free_list → 找子分配器要新 chunk。
  单线程下 free_list 恒为空；bump 失败会把 `end_index` 永久顶高（可超过 buf_len），该 chunk 尾部就此作废。
  实测见 `experiments/arena-alloc/`（带断言，可复跑）

## 三条基调决策

改这三条之前先想清楚，它们都有实测支撑：

1. ABI 是唯一的共享模块 `dsh_abi`（`src/abi.zig`）。宿主与插件必须 import 同一份，
   否则同一份源码会被编译成两套类型，跨边界传递即数据损坏。
2. 宿主必须链接 libc。不链时 Zig 走自带的 ELF 加载器，`dlopen` 之后的调用会段错误。
3. 插件是独立的动态库，这是热重载的前提：替换磁盘上的 `.so` 再重新加载。

## 装载与卸载的规矩

- 撤销注册先于 `dlclose`，顺序固定为「撤销 -> dlclose -> arena 清空」
- 撤销按稳定编号（`Handle.id`）定位，不按名字
- 撤销由宿主负责，插件不负责清理自己
- 每代都真正卸载，同时产物名带内容指纹；不覆盖正在被加载的 `.so`
- 重载顺序：编译新产物 -> 校验新产物 -> 拆旧 -> 装新

## 代码规范

- 早期返回。用卫语句把错误分支顶到前面，不要把主流程裹进多层嵌套
- 注释只解释 why。不写代码行号（会漂移），不写变更历史（那是 commit 的事）
- 不使用 emoji 和装饰性符号
- 文件头注释写清职责、数据流、不变量、不可简化，整块不超过 15 行
- 同一个定义只留一处，别处 import 它；出现两份就合并

## 实验与提交

开发过程中的每一次实验（spike、探针、试错、失败的尝试）都要写进仓库并提交，
落在 `experiments/<主题>/`，文件头写清三件事：问题、结论、怎么复现。

只删除纯输出（构建产物、dump、下载物、core）。实验代码和结论必须留下。

## 当前进度

**MVP（agent 侧）已完成**：工具四件套 + AGENTS.md 注入 + LLM 客户端（可替换
传输层）+ 主循环 + REPL + 会话持久化（jsonl）。`dsh_zig` 能对话、能调工具，
端到端跑通过真 DeepSeek。

**插件内核（host 侧）进行中**，已完成：
- `services.zig` 服务表（provide / revoke / get，编号不复用、名字拷贝、拒重名）
- `loader.zig` dlopen + 先校验 ABI 版本再取符号
- `fiber.zig` 状态机 + 专属 arena + 撤销清单（卸载三步顺序写死在注释里）
- `context.zig` 装配层：per-plugin 包装 + 6 个 HostApi 函数 + mountPlugin/unmountPlugin
- `plugins/hello.zig` 真插件
- 装卸闭环已有集成测试：真 dlopen -> 注册 -> 卸载 -> 零残留，反复 15 次无泄漏

**下一步**：工具插件搬家（`agent/tools.zig` 的四件套搬进 `.so`，届时 ABI 加
read_file / write_file / run_shell，ABI_VERSION 1 -> 2），然后阶段 4 热重载。

**刻意推迟**（都有理由，别提前做）：事件总线（`events.zig`，工具插件用不到它，
且它要支持 waterfall 就必须先改 ABI 的回调签名）；依赖门（inject/epoch）；
隔离作用域；流式输出与 TUI（记在 todo 里）。
