# MoonIperf

**iperf3 兼容的网络吞吐量测量工具，纯 MoonBit 实现（无 C FFI 绑定）。**

MoonIperf 说 iperf3 的线上协议（控制连接 JSON + 数据连接 + UDP 报文头），因此：

- `mooniperf -c <host>` 可以直接连 **真实的 iperf3 服务器**（`iperf3 -s`）；
- `mooniperf -s` 可以被 **真实的 iperf3 客户端**（`iperf3 -c`）压测。

协议兼容性通过互操作验收： mooniperf 客户端 ↔ 真实 iperf3 服务器、真实 iperf3 客户端 ↔ mooniperf 服务器，双向均可交换参数与结果。

## 特性（v0.1）

| 能力 | 状态 |
|---|---|
| TCP 吞吐测量（客户端发送 / 服务器接收） | ✅ |
| UDP 吞吐测量 + RFC 1889 抖动 + 丢包统计 | ✅ |
| iperf3 控制协议（状态字节 + 长度前缀 JSON） | ✅ |
| iperf3 UDP 握手（`0x36373839`/`0x39383736`） | ✅ |
| 时间驱动的 UDP 速率控制（`-b`） | ✅ |
| 间隔报告 + iperf3 风格汇总 | ✅ |
| `-J` JSON 输出（iperf3 报告结构） | ✅ |
| `-P` 并行数据连接（TCP） | ✅ |
| `-O` 预热窗口剔除（omitted 统计） | ✅ |
| `-R` 反向模式 | 🚧 路线图（见下） |
| TCP 重传统计、窗口/RTT 采样 | 🚧 需 setsockopt/getsockopt FFI |

在 Windows（x86_64，MoonBit native 后端）上验证。回环自测吞吐 20+ Gbits/sec。

## 快速开始

```bash
# 终端 1：启动服务器
moon run cmd/main -- -s -p 5201

# 终端 2：TCP 测试（2 秒）
moon run cmd/main -- -c 127.0.0.1 -p 5201 -t 2

# UDP 测试（2 Mbit/s 目标速率）
moon run cmd/main -- -c 127.0.0.1 -p 5201 -u -b 2M -t 2

# JSON 输出
moon run cmd/main -- -c 127.0.0.1 -p 5201 -t 2 -J

# 与真实 iperf3 互操作
iperf3 -s -p 5201
moon run cmd/main -- -c <iperf3-host> -p 5201 -t 10
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
-P, --parallel <n>     并行数据连接数（TCP，默认 1）
-u, --udp              使用 UDP
-b, --bitrate <n>[KMGT] 目标速率 bits/s（UDP 默认 1M）
-l, --len <n>          块大小（TCP 默认 131072，UDP 8192）
-n, --bytes <n>        发送 n 字节后停止
-k, --blockcount <n>   发送 n 块后停止
-O, --omit <n>         剔除前 n 秒（预热）
-J, --json             JSON 输出
-v, --version          版本
-h, --help             帮助
```

## 与 iperf3 的协议对应（docs/protocol.md 有逐条细节）

- **控制连接**（TCP 5201）：连接后首先发送 37 字节 cookie；随后是单字节状态
  （`TEST_START=1`、`TEST_RUNNING=2`、`PARAM_EXCHANGE=9`、`CREATE_STREAMS=10`、
  `TEST_END=4`、`EXCHANGE_RESULTS=13`、`DISPLAY_RESULTS=14`、`IPERF_DONE=16`，
  负值 `ACCESS_DENIED=-1`、`SERVER_ERROR=-2`）与
  `[4 字节大端长度][UTF-8 JSON]` 消息（参数、结果）交错。
- **数据连接**（TCP）：每条连接先发 cookie 供服务器校验（不匹配回 `ACCESS_DENIED`），
  之后是纯块数据。
- **UDP 数据**：首报文 `u32 0x36373839`（本机字节序），服务器应答 `u32 0x39383736`；
  数据报文头 12 字节大端（秒、微秒、序号），接收端按 RFC 1889 计算抖动、
  按序号间隔统计丢包。

## 实现说明（性能相关）

- 收发路径零拷贝思路：预填充的 `Bytes` 模式块反复 `write`，读端复用
  `FixedArray[Byte]` 缓冲，热路径不产生中间 `String` 分配。
- UDP 采用**时间驱动**的步进限速（对齐目标速率的 datagram 目标数），在高速率下
  自动成批发送，避免逐包 sleep 的 1000 包/秒上限。
- 抖动/丢包为纯差分计算（与 iperf3 相同），发送/接收两端无需时钟同步。
- 时钟来自事件循环（毫秒精度），UDP 报文头的时间戳分辨率受此限制。

## 已知限制（v0.1）

- `-R`（反向模式）：协议状态机已对齐，Windows 事件循环下已连接 UDP/长写场景
  存在边界问题，暂时禁用（路线图第一项）。
- `-w`（窗口大小）、重传/RTT 采样需要 setsockopt/getsockopt FFI，暂未接入。
- UDP 报文头时间戳为毫秒分辨率（iperf3 为微秒）。
- 服务器一次只服务一个测试（顺序处理客户端）。

## 开发

```bash
moon check   # 类型检查
moon test    # 22 个单元测试（协议编解码、RFC 1889 抖动、格式化）
moon build   # 构建 CLI
```

包结构：

```
ctl/     iperf3 线上协议：状态字节、JSON 封帧、参数/结果编解码、cookie、UDP 头
stats/   吞吐区间统计、RFC 1889 抖动与丢包
report/  iperf3 风格的人类可读输出
wire/    控制通道 socket I/O 封装
server/  测试服务器（接收/反向发送）
client/  测试客户端（发送/反向接收、报告、-J JSON）
cmd/main CLI 入口
```

## 许可

Apache-2.0
