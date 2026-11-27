# MoonIperf

[![CI](https://github.com/yiii0012/mooniperf/actions/workflows/ci.yml/badge.svg)](https://github.com/yiii0012/mooniperf/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![mooncakes.io](https://img.shields.io/badge/mooncakes-yiii0012%2Fmooniperf-8A2BE2)](https://mooncakes.io/docs/#/yiii0012/mooniperf/)

**iperf3 兼容的网络吞吐量测量工具，纯 MoonBit 实现（无 C FFI 绑定）。**

MoonIperf 说 iperf3 的线上协议（控制连接 JSON + 数据连接 + UDP 报文头），因此：

- `mooniperf -c <host>` 可以直接连 **真实的 iperf3 服务器**（`iperf3 -s`）；
- `mooniperf -s` 可以被 **真实的 iperf3 客户端**（`iperf3 -c`）压测。

## 与真实 iperf3 的互操作（已实测）

对照实现：iperf 3.1.3（iperf.fr 官方 Windows x64 构建，Cygwin），
同一台机器回环双向对测，2026-11-21 首测、2026-11-22 复测（13/13 再次通过）。
`✅` = 客户端进程退出码 0，双方完成参数交换、数据测量与结果交换。

| 客户端 | 服务器 | TCP P1 | TCP P2 | TCP P3 | UDP | `-J` | `-O` | `-n` |
|---|---|---|---|---|---|---|---|---|
| iperf3 | mooniperf | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| mooniperf | iperf3 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

互操作不是"恰好能跑"——为了让 iperf3 接受 mooniperf 的报文，有三个协议细节
必须逐条对齐（均从 iperf3 源码与线上抓包反推，详见
[docs/protocol.md](docs/protocol.md)）：

1. **流 id 序列**：iperf3 的 `iperf_add_stream` 给首条流 id=1、第 k 条流
   id=k+1（它的链表游标从 2 起计数），序列是 **1, 3, 4, 5…**；
   `EXCHANGE_RESULTS` 里双方都按这个序列校验 id，普通 1..N 编号会在
   `-P > 1` 时收到 `stream has an invalid id`。
2. **参数 JSON 的"键存在"语义**：真实服务器的 `get_parameters` 对
   `udp`/`reverse`/`get_server_output` 等**只看键是否存在、不看值**——
   发送 `"udp": false` 会把测试切换成 UDP。因此 mooniperf 与 iperf3 一样，
   只在选项激活时才发送对应键。
3. **数据连接 cookie 与握手次序**：每条数据连接先发与控制连接相同的
   37 字节 cookie（不匹配回 `ACCESS_DENIED`），UDP 走 `0x36373839` /
   `0x39383736` 握手且宽容接受两种字节序与 iperf2 遗留值。

已知边界：第三方 iperf3 客户端用 `-u -P>1` 打 mooniperf 服务器时，
多余流的握手会被应答、数据被并入单流统计，但结果只回报一条流（见
[已知限制](#已知限制-v011)）。

## 基准（同机回环，Windows 11，Ryzen 7 8845H，MoonBit native 后端）

发送端报告的吞吐（iperf3 同口径，5 秒，2026-11-21；回环负载下单次波动
约 ±30%，表中为多轮实测的代表值）：

| 组合（发送方 → 接收方） | TCP P1 | TCP P4（每流 / 合计） |
|---|---|---|
| iperf3 → iperf3 | 11–14 Gbits/sec | 5.3 G ×4 ≈ 21 G |
| mooniperf → iperf3 | 14.6 Gbits/sec | 5.1–5.3 G ×4 ≈ 21 G |
| iperf3 → mooniperf | 19.6–21.4 Gbits/sec | 5.2 G ×4 ≈ 21 G |
| mooniperf → mooniperf | 20.2–20.8 Gbits/sec | — |

- 接收侧吞吐 mooniperf 不低于 iperf3 3.1.3 的 Cygwin 构建
  （iperf3 自己的接收端报告约 11.5 Gbits/sec，打到 mooniperf 时发送端
  实测 19.6–21.4 Gbits/sec）。
- 收发路径零拷贝思路：预填充的 `Bytes` 模式块反复 `write`，读端复用
  `FixedArray[Byte]` 缓冲，热路径不产生中间 `String` 分配。
- **UDP 限速精度**（时间驱动步进限速，目标速率 vs 客户端实测）：

  | 目标速率 | mooniperf 实测 | iperf3 实测 | 丢包 | 抖动 |
  |---|---|---|---|---|
  | 1 Mbit/s | 981–988 Kbits/sec | 973–979 Kbits/sec | 0 | 0.000 ms（回环） |
  | 100 Mbit/s | 98.5 Mbits/sec | 102 Mbits/sec | 0 | 0.000 ms（回环） |

  高速率下自动成批发送，避免逐包 sleep 的 1000 包/秒上限；两实现偏差
  均在 ±3% 内。
- 抖动/丢包为纯差分计算（RFC 1889 A.8，与 iperf3 相同），发送/接收两端
  无需时钟同步。

## 边界与健壮性（2026-11-22 实测，22 例全通过）

在 13 例互操作矩阵之外补充的边界探针（每例均要求客户端按预期退出、服务器
存活且继续服务后续测试）：

| 类别 | 用例 | 结果 |
|---|---|---|
| 抗异常输入 | 控制端口灌垃圾字节 ×2、无 cookie 即断开 ×3 | 服务器无崩溃，后续测试正常 |
| 极端块长 | TCP `-l 64`、TCP `-l 1048576`（1 MiB）、UDP `-l 1200`，双向对真实 iperf3 | 全通过 |
| 极端速率 | UDP `-b 500K`（低于默认）、`-b 200M`（成批发送），双向 | 全通过 |
| 传输上限 | `-n 32M`、`-k 5000`（TCP 双向）、UDP `-n 8M` 跨实现 | 全通过 |
| 报告参数 | `-i 0.5` 小数间隔 + `-O 1` 预热，自互通 | 通过 |
| CLI 误用 | 连不上端口、`-b 垃圾值`、`-s -c` 同用、缺模式、`-i 0`、UDP `-l 4` | 均以非零退出码拒绝 |

单元测试另有 39 项覆盖：封帧编解码、cookie、流 id 序列、限速解析（含
K/M/G/T 与越界拒绝）、Int64 溢出防护、RFC 1889 抖动/乱序、JSON 结果
编解码与格式化。

## 快速开始

环境要求：[MoonBit 工具链](https://www.moonbitlang.com/download/)，
`moonc` 版本不低于 **1.0.0-rc1**（`moonc -v` 可查看）。

```bash
# 从 mooncakes 安装（作为库/CLI 依赖）
moon add yiii0012/mooniperf

# 或从源码构建运行
moon run cmd/main -- -s -p 5201          # 终端 1：启动服务器
moon run cmd/main -- -c 127.0.0.1 -p 5201 -t 2          # TCP 测试
moon run cmd/main -- -c 127.0.0.1 -p 5201 -u -b 2M -t 2 # UDP 2 Mbit/s
moon run cmd/main -- -c 127.0.0.1 -p 5201 -t 2 -J       # JSON 输出

# 与真实 iperf3 互操作
iperf3 -s -p 5201
moon run cmd/main -- -c <iperf3-host> -p 5201 -t 10
```

最小使用样例（TCP 2 秒自测）的预期输出形态：

```text
Connecting to host 127.0.0.1, port 5201
[  1] local 127.0.0.1:xxxxx connected to 127.0.0.1 port 5201
[ ID] Interval           Transfer     Bitrate
[  1]   0.00-1.00   sec  2.30 GBytes  19.8 Gbits/sec
[  1]   1.00-2.00   sec  2.36 GBytes  20.3 Gbits/sec
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
[  1]   0.00-2.00   sec  4.66 GBytes  20.0 Gbits/sec                  sender
[  1]   0.00-2.00   sec  4.66 GBytes  20.0 Gbits/sec                  receiver

iperf Done.
```

也可以 `moon build` 后直接运行
`_build/native/debug/build/cmd/main/main.exe`（或 release 目录下的产物）。

## 选项

```
-s, --server           服务器模式
-c, --client <host>    客户端模式，连接 <host>
-p, --port <n>         端口（默认 5201）
-t, --time <n>         测试时长/秒（默认 10）
-i, --interval <n>     报告间隔/秒（默认 1）
-P, --parallel <n>     并行数据连接数（TCP，默认 1；UDP 单流）
-u, --udp              使用 UDP
-b, --bitrate <n>[KMGT] 目标速率 bits/s（UDP 默认 1M，`-b 0` 不限速；TCP 同样生效）
-l, --len <n>          块大小（TCP 默认 131072，UDP 8192）
-n, --bytes <n>        发送 n 字节后停止
-k, --blockcount <n>   发送 n 块后停止
-O, --omit <n>         剔除前 n 秒（预热）
-w, --window <n>       窗口大小（接受但未生效，需 setsockopt FFI）
--get-server-output    回收服务器摘要（文本模式打印，-J 内嵌报告）
-J, --json             JSON 输出（iperf3 报告结构）
-v, --version          版本
-h, --help             帮助
```

## 实现说明（协议与性能）

- **控制协议**（TCP 5201）：37 字节 cookie；单字节状态
  （`TEST_START=1`、`TEST_RUNNING=2`、`PARAM_EXCHANGE=9`、
  `CREATE_STREAMS=10`、`TEST_END=4`、`EXCHANGE_RESULTS=13`、
  `DISPLAY_RESULTS=14`、`IPERF_DONE=16`，负值 `ACCESS_DENIED=-1`、
  `SERVER_ERROR=-2`）与 `[4 字节大端长度][UTF-8 JSON]` 消息交错。
  逐条细节与 iperf3 源码对照见 [docs/protocol.md](docs/protocol.md)。
- **UDP 数据**：首报文 `u32 0x36373839`（本机字节序），服务器应答
  `u32 0x39383736`；数据报文头 12 字节大端（秒、微秒、序号），接收端按
  RFC 1889 计算抖动、按序号间隔统计丢包，最终汇总的丢包数按 iperf3 口径
  为发送端总数 − 接收端收到数。
- **UDP 限速**：时间驱动的步进限速（对齐目标速率的 datagram 目标数），
  见 `stats/interval.mbt` 的 `target_datagrams`（含 Int64 溢出防护）；
  TCP 传入 `-b` 时走同一调度器按块限速，`-b 0` 为不限速（iperf3 语义）。
- **`--get-server-output`**：客户端在参数里请求后，服务器把最终摘要以
  `server_output_text` 随结果 JSON 回传，文本模式打印、`-J` 内嵌报告；
  与真实 iperf3 双向验证。
- 时钟来自事件循环（毫秒精度），UDP 报文头的时间戳分辨率受此限制。

## 已知限制（v0.1.3）

- `-R`（反向模式）：协议状态机已实现且自互通通过，但 Windows 事件循环下
  已连接 UDP / 长写场景存在边界问题，暂时在 CLI 层禁用（路线图第一项，
  见 [docs/roadmap.md](docs/roadmap.md)）。
- **UDP 单流**：`-u` 与 `-P>1` 组合时客户端会忽略 `-P`（打印提示）。
  第三方 iperf3 客户端的 `-u -P>1`：多余流的握手会被应答、数据并入单流
  统计，但结果只回报一条流。多流 UDP 列入路线图。
- `-w`（窗口大小）、重传/RTT 采样需要 setsockopt/getsockopt FFI，暂未接入。
- UDP 报文头时间戳为毫秒分辨率（iperf3 为微秒）。
- 服务器一次只服务一个测试（顺序处理客户端）。

## 开发

```bash
moon check   # 类型检查（0 警告）
moon test    # 39 个单元测试（协议编解码、RFC 1889 抖动、边界与格式化）
moon build   # 构建 CLI
```

包结构：

```
ctl/     iperf3 线上协议：状态字节、JSON 封帧、参数/结果编解码、cookie、UDP 头
stats/   吞吐区间统计、RFC 1889 抖动与丢包、UDP 步进限速
report/  iperf3 风格的人类可读输出
wire/    控制通道 socket I/O 封装
server/  测试服务器（接收/反向发送）
client/  测试客户端（发送/反向接收、报告、-J JSON）
cmd/main CLI 入口
```

## 依赖

- [moonbitlang/async](https://github.com/moonbitlang/async) 0.22.10
  （Apache-2.0）——事件循环与 TCP/UDP socket。mooniperf 的全部逻辑为纯
  MoonBit，无 C FFI 绑定。

## 许可

Apache-2.0（见 [LICENSE](LICENSE)）。变更记录见 [CHANGELOG.md](CHANGELOG.md)。

**合规说明**：mooniperf 是对 iperf3 线上协议的**独立重实现**——未复制
iperf3 的任何源码；协议细节依据其公开文档、源码（iperf3 为 ESnet 的
BSD-3-Clause 项目，与本项目无代码隶属关系）及线上行为整理，出处逐条记录在
[docs/protocol.md](docs/protocol.md)。唯一依赖 moonbitlang/async 为
Apache-2.0（见上文"依赖"）。
