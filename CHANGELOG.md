# 更新日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 风格，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.1.4] - 2026-11-28

### 新增

- **CLI 参数解析对齐 iperf3（src/units.c）**：`-b` 的 K/M/G/T 后缀按
  `unit_atof_rate` 用十进制（10^3）倍率并支持小数（`-b 1.5M`）；`-n`/`-k`/
  `-l`/`-w` 按 `unit_atoi` 用二进制（2^10）倍率并支持小数（`-n 32M` 现为
  32×1024² 字节，与 iperf3 一致）。实测 iperf3 3.1.3 + 核对其 master
  units.c 后对齐。
- **`-t`/`-n`/`-k` 三选一**：与 iperf3 相同，任意两个端条件同用即以
  `only one test end condition (-t, -n, -k) may be specified` 拒绝
  （IEENDCONDITIONS，实测 iperf3 3.1.3 行为一致）；`-t` 上限 86400 秒。
- **`-J` 模式错误输出为 JSON**：参数错误与运行期错误以
  `{"error": "..."}`（正确转义）输出，可被机器解析，替代此前的纯文本。
- **服务器参数交换失败时回 `SERVER_ERROR`**：参数 JSON 读取失败不再静默
  断开，而是回 `SERVER_ERROR + (i_errno=114/IERECVPARAMS, errno)`，与
  iperf3 服务器行为一致；客户端收到 `SERVER_ERROR` 时按 iperf3 的
  `iperf_strerror` 文案渲染（71 条 i_errno 文案取自 iperf3 3.1.3
  src/iperf_error.c，见 `ctl/ierrno.mbt`）。
- **CI 新增真实 iperf3 互操作矩阵**：`scripts/interop.sh` 在 CI 中把
  mooniperf 与发行版 iperf3（ubuntu 的 apt 包）双向对测（TCP -P 1/2/3、
  UDP、`-J` 报告 JSON 合法性、`-O`/`-n`/`-k`、`--get-server-output`、
  CLI 误用拒绝），每次推送即回归 3.x 线上兼容性。

### 变更

- **UDP 默认速率对齐 iperf3 的 `UDP_RATE`**：未给 `-b` 时 UDP 目标从
  1000000 修正为 1048576 bits/s（iperf3 src/iperf.h 定义 `1024 * 1024`），
  默认 `-u` 测试现与 iperf3 一样报约 1.05 Mbits/sec。
- CI 的工具链安装重构为复合 action（`.github/actions/setup-moonbit`），
  `build` 矩阵与 `interop` 任务共用。

### 测试

- 单元测试 39 → 43：小数/二进制倍率解析（`parse_rate`/`parse_bytes`）、
  端条件互斥（`end_condition_error`）、`SERVER_ERROR` body 编码往返、
  i_errno 文案抽查；UDP 默认速率断言更新为 1048576。

[0.1.4]: https://github.com/yiii0012/mooniperf/compare/0.1.3...0.1.4

## [0.1.3] - 2026-11-28

### 变更

- **工具链基线提升到 moonc 1.0.0-rc1**：`moon check` / `moon test` /
  `moon build` 全部在 moonc 1.0.0-rc1（2026-11-26）下验证通过；
  CI 在每次运行中打印解析到的编译器版本以便追溯。
- CI（Windows）：moonbitlang/async 的 Windows C stub 需要 MSVC 工具链
  （MinGW 下 `event_bus.c` 直接 `#error`），CI 显式挂载 runner 预装的
  VS 构建环境（`ilammy/msvc-dev-cmd`），与 moonbitlang/async 官方 CI 一致；
  同时关闭 Windows 检出的自动 CRLF。
- 源码统一用 1.0.0-rc1 工具链的 `moon fmt` 重新格式化（纯风格，无语义变化）。

### 测试

- 单元测试 36 → 39：新增 `wire` 包纯函数测试（cookie/字节比较语义、
  `bytes_of` 的越界钳制）与 `Params::bitrate` 的 iperf3 限速默认值语义
  （`-b` 未给 / `-b 0` / 显式速率、预热窗口折算）。

### 修复

- 文档：修正 `ctl_test.mbt` 头注释里残留的旧模块名。

[0.1.3]: https://github.com/yiii0012/mooniperf/compare/0.1.2...0.1.3

## [0.1.2] - 2026-11-22

### 新增

- **TCP `-b` 限速**：与 UDP 共用时间驱动块步进调度器（`stats/target_datagrams`），
  对齐 iperf3 的 TCP pacing；实测 `-b 10M` 报告 9.6 Mbit/s（±4%）。
- **UDP `-b 0` 不限速**：遵循 iperf3 语义；未给 `-b` 时 UDP 仍默认 1 Mbit/s。
- **`--get-server-output`**：客户端请求后，服务器把最终摘要以
  `server_output_text` 随结果 JSON 回传（文本模式打印、`-J` 内嵌报告），
  与真实 iperf3（3.1.3）双向验证。
- `-p` 端口范围校验（1–65535），非法参数非零退出码拒绝。

### 测试

- 单元测试 33 → 36（server_output_text 往返、get_server_output 键存在语义、
  限速哨兵值解析）；新增 10 例功能探针全通过；13 例互操作矩阵与 22 例边界
  探针回归无变化。

[0.1.2]: https://github.com/yiii0012/mooniperf/compare/0.1.1...0.1.2

## [0.1.1] - 2026-11-21

### 修复

- **协议对齐真实 iperf3**：流 id 序列复刻 `iperf_add_stream` 的 1,3,4,5… 规则
  （`-P > 1` 时普通 1..N 编号会被真实对端以 `stream has an invalid id` 拒绝）；
  参数 JSON 遵循 iperf3 的"键存在即激活"语义（发送 `"udp": false` 会把测试
  切成 UDP）；服务器结果回显客户端声明的流 id，对 id 规则变化保持鲁棒。
- 数据连接 cookie 逐字节比对（`strcmp` 语义），不匹配回 `ACCESS_DENIED`。

### 新增

- 与真实 iperf3（3.1.3）的双向互操作矩阵：TCP `-P 1/2/3`、UDP、`-J`、`-O`、
  `-n` 共 13 例全部通过（`docs/protocol.md`）。
- 边界测试：限速解析、流 id 序列、Int64 溢出防护、封帧长度上限、
  `SERVER_ERROR` 越界读取等（单元测试 22 → 33）。
- CI 扩展到 Linux / Windows / macOS 三平台，并在干净 runner 上做回环冒烟测试。

### 已知限制（v0.1.1 仍存在）

- `-R` 反向模式在 CLI 层禁用（Windows 事件循环边界问题，见
  [docs/roadmap.md](docs/roadmap.md)）；UDP `-u` 暂为单流。

## [0.1.0] - 2026-11-20

### 新增

- iperf3 线上协议实现：控制连接（37 字节 cookie、状态字节、长度前缀 JSON）、
  TCP 数据连接、UDP 报文头与握手、RFC 1889 抖动估计、丢包/乱序统计。
- 客户端/服务器完整测试流：参数交换、多流（`-P`）、预热（`-O`）、字节/块数
  限制（`-n`/`-k`）、时间驱动 UDP 步进限速（1 Mbit/s 到数百 Mbit/s 精确）。
- iperf3 风格的人类可读输出与 `-J` JSON 报告。
- mooncakes.io 首发 `yiii0012/mooniperf@0.1.0`。

[0.1.1]: https://github.com/yiii0012/mooniperf/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/yiii0012/mooniperf/releases/tag/0.1.0
