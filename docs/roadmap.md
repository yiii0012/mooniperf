# mooniperf 路线图

v0.1 已交付的能力见 [README](../README.md)。以下按优先级列出后续计划，
以及 v0.1 明确禁用/降级项的技术原因，供评审与贡献者参考。

## v0.2 计划

1. **`-R` 反向模式（TCP + UDP）**
   协议状态机已按 iperf3 实现（服务器测得 `PARAM_EXCHANGE.reverse` 后由
   `spawn_tcp_sender`/`spawn_udp_sender` 主动发送，客户端 `spawn_*_receiver`
   接收，见 `server/server.mbt`、`client/client.mbt`），mooniperf↔mooniperf
   自测通过。但与真实 iperf3 的 `-R` 互操作在 Windows 事件循环
   （moonbitlang/async 0.22.x）下存在两个未解边界问题，v0.1 在 CLI 层
   显式禁用 `-R`，避免给出错误结果：
   - 已连接 UDP 套接字（connect + send/recv）的数据报不投递——探针证实，
     目前 UDP 收发一律走无连接 `UdpServer` + sendto/recvfrom；
   - 多 socket 并发挂起读时，控制连接的读事件不能唤醒事件循环，
     导致反向模式控制流死锁。
   两者都需要 event_loop 层的修复/升级后重新验证。

2. **`-w` 窗口、重传/RTT 统计**：需要 setsockopt/getsockopt FFI
   （`SO_RCVBUF`/`SO_SNDBUF`、`TCP_INFO`），moonbitlang/async 尚未暴露。

3. **微秒级 UDP 时间戳**：事件循环时钟为毫秒精度，报文头时间戳分辨率受限；
   需要单调高精度时钟接口。

4. **`--bidir` 双向模式**、**`--get-server-output`**、**CPU 利用率统计**
   （`getrusage` FFI）。

5. **服务器并发多测试**：v0.1 一次只服务一个客户端（顺序处理，iperf3 默认
   也是单测试模型，但 iperf3 有 `--json` 输出的异步 option）；后续引入
   连接级任务隔离。

## 更远

- `-Z` zerocopy、`--repeating-payload`、`--fq-rate` 匀速器对齐
- AUTH（`--username`/`--rsa-public-key`）
- 拥塞控制字符串上报（`congestion_used`）
- 大规模 `-P`（>128）的调度策略与内存上限

## 已知偏差（与 iperf3 的差异清单）

| 项 | iperf3 | mooniperf v0.1 | 影响 |
|---|---|---|---|
| UDP 时间戳分辨率 | 微秒 | 毫秒（事件循环时钟） | 抖动为差分量纲，不影响互操作 |
| 重传统计 | TCP_INFO | 恒为 -1（未测量） | 显示 0 列，协议兼容 |
| CPU 利用率 | getrusage | 恒为 0 | JSON 字段保留 |
| 流 id 显示 | 按实现 | 1 基序号（与 iperf3 `iperf_add_stream` 一致） | 无 |
