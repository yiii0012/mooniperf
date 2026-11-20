# mooniperf 线上协议笔记（对着 iperf3 源码逐条核对）

本文记录 mooniperf 实现的 iperf3 线上协议，字段名与状态值均取自
[esnet/iperf](https://github.com/esnet/iperf) 的 `src/iperf_api.h`、
`src/iperf_api.c`、`src/iperf_udp.c`、`src/iperf_tcp.c`、`src/iperf_server_api.c`，
并用 Rust 重实现 [riperf3](https://github.com/therealevanhenry/riperf3) 的
`protocol.rs` 交叉验证过。

## 控制连接（TCP，默认端口 5201）

连接建立后，**客户端首先发送 37 字节 cookie**（`COOKIE_SIZE=37`，
iperf3 的 cookie 是 36 个随机字符 + NUL）。cookie 只用于自洽校验：
之后每条数据连接也要发同样的 37 字节，服务器比对不一致时在该数据连接上
回 `ACCESS_DENIED`（-1）并关闭。

### 状态字节

控制连接上交错两类消息：**单字节状态**（`signed char`）与
**JSON 消息**（`4 字节大端长度前缀 + UTF-8 JSON 文本`，对应 iperf3 的
`JSON_write`/`JSON_read`，`htonl/ntohl`）。

| 状态 | 值 | 方向 | 含义 |
|---|---|---|---|
| TEST_START | 1 | S→C | 流已建立，初始化 |
| TEST_RUNNING | 2 | S→C | 开始传输 |
| TEST_END | 4 | C→S | 客户端发送结束 |
| PARAM_EXCHANGE | 9 | S→C，随后 C→S 参数 JSON | 参数交换 |
| CREATE_STREAMS | 10 | S→C | 打开数据连接 |
| SERVER_TERMINATE | 11 | S→C | 服务器中止 |
| CLIENT_TERMINATE | 12 | C→S | 客户端中止 |
| EXCHANGE_RESULTS | 13 | S→C，随后双向结果 JSON | 结果交换 |
| DISPLAY_RESULTS | 14 | S→C | 可以打印 |
| IPERF_DONE | 16 | C→S | 结束并断开 |
| ACCESS_DENIED | -1 | S→数据连接 | cookie 不匹配 |
| SERVER_ERROR | -2 | S→C + 两个大端 u32（i_errno, errno） | 服务器出错 |

### 正向模式（TCP）消息时序

```
C→S  cookie (37 字节)
S→C  PARAM_EXCHANGE (9)
C→S  参数 JSON（send_parameters 字段名：
     tcp/udp/sctp/omit/time/num/blockcount/MSS/nodelay/parallel/reverse/
     bidirectional/window/len/bandwidth/fqrate/pacing_timer/burst/TOS/
     flowlabel/title/extra_data/congestion/get_server_output/
     udp_counters_64bit/repeating_payload/zerocopy/dont_fragment/
     authtoken/client_version）
S→C  CREATE_STREAMS (10)
C→S  打开数据连接，每条先发 cookie
S→C  TEST_START (1)
S→C  TEST_RUNNING (2)
     ……数据传输（数据连接上没有状态字节，只有块数据）……
C→S  TEST_END (4)
S→C  EXCHANGE_RESULTS (13)
C→S  客户端结果 JSON（send_results 先发）
S→C  服务器结果 JSON（get_results 后收）
S→C  DISPLAY_RESULTS (14)
C→S  IPERF_DONE (16)
```

### EXCHANGE_RESULTS JSON

顶层字段：`cpu_util_total`、`cpu_util_user`、`cpu_util_system`、
`sender_has_retransmits`、（可选 `congestion_used`、`server_output_text`、
`server_output_json`）与 `streams` 数组。流对象字段：
`id`、`bytes`、`retransmits`、`jitter`、`errors`、`omitted_errors`、
`packets`、`omitted_packets`、`start_time`、`end_time`。
客户端先发自己的结果、再读服务器的；服务器相反。

## UDP

### 握手

客户端向服务器端口发送首报文 `u32 0x36373839`（iperf3 以**本机字节序**写入，
x86/ARM 小端下即字节 `39 38 37 36`）；服务器从监听套接字 `recvfrom`
学习客户端地址后应答 `u32 0x39383736`。客户端同时接受
`987654321`（legacy）以及两种字节序的变体，和 iperf3 的宽容握手一致。

### 数据报文头

每报文头 12 字节（iperf3 `iperf_udp_send` 原始 memcpy + `htonl`）：

```
[0..4)   sec     u32 BE   发送时刻秒
[4..8)   usec    u32 BE   发送时刻微秒
[8..12)  pcount  u32 BE   序号（udp_counters_64bit 时为 8 字节 BE，头长 16）
```

接收端：

- 抖动按 RFC 1889 A.8：`transit = 到达时刻 - 发送时刻`，
  `d = |transit - prev_transit|`，`jitter += (d - jitter) / 16`；
  只用差分，两端无需时钟同步。
- 序号跳跃计丢包（`cnt_error += (pcount-1) - packet_count`），
  序号倒退计乱序并回冲一个先前计过的丢包。
- 最终汇总的丢包数按 iperf3 口径为 `发送端总数 - 接收端收到数`。

## 兼容性矩阵（已验证）

| 客户端 | 服务器 | 结果 |
|---|---|---|
| mooniperf | mooniperf | ✅ TCP / UDP / JSON |
| mooniperf | 真实 iperf3 | 预期 ✅（协议按源码实现，待多平台验证） |
| 真实 iperf3 | mooniperf | 预期 ✅（同上） |

注意事项：

- mooniperf 客户端在发送 `TEST_END` 前先关闭数据连接（iperf3 稍后关闭），
  这使接收端的最终统计确定性落地，不影响协议状态机。
- UDP 时间戳分辨率受事件循环毫秒时钟限制（iperf3 为微秒），
  抖动为差分量纲，不影响与 iperf3 的互操作。
