# Linux 性能排查基础

> 排查顺序：**看负载 → 看 CPU/内存/磁盘/网络 → 看进程 → 看调用**，用数据定位瓶颈，不靠猜。

## 1. 先看整体负载

```bash
uptime          # load average：1/5/15 分钟
top -c          # CPU/内存总览 + 进程排序
```

load average 高但 CPU 不高 → 大概率是 **D 状态进程（不可中断 IO）** 或 CPU 排队；配合 `vmstat` 判断。

## 2. CPU

```bash
top -c                # 看 %CPU 与进程状态
vmstat 1 5            # us/sy/id/wa 比例；r 队列、b 阻塞
mpstat -P ALL 1       # 每核使用率，判断是否单核热点
pidstat -p <pid> 1    # 单进程 CPU
```

- `sy` 高：系统调用/上下文切换过多 → `pidstat -w` 看 cswch。
- `wa` 高：IO 瓶颈，转磁盘排查。
- 单核 100% 其余空闲：锁竞争/单线程热点 → 用 `perf top` 看热点函数。

## 3. 内存

```bash
free -h               # total/used/available；available 才是可用内存
vmstat 1              # si/so：swap 换入换出
pidstat -r 1          # 进程 RSS
```

- 关注 **available** 而非 used（page cache 会被回收）。
- 频繁 swap（si/so 持续不为 0）：内存不足，优先排查大进程，避免直接加内存掩盖问题。
- 内存泄漏：`/proc/<pid>/status` 看 VmRSS 趋势，或 watch 多轮采样。

## 4. 磁盘与 IO

```bash
df -h                 # 空间
iostat -x 1           # 看 %util、await、svctm、r/s w/s
iotop                 # 按进程看 IO
```

- `%util` 接近 100%：磁盘繁忙（先确认是否为多盘聚合导致误判，用单盘数据）。
- `await` 高：队列长或设备慢；区分「请求本身慢」与「排队慢」。
- 磁盘满不一定只在根分区：日志分区、临时目录、容器 overlay 都可能先满。
- inode 满：`df -i`。

## 5. 网络

```bash
ss -s                         # 连接统计
ss -tan state time-wait       # TIME_WAIT
ifstat / sar -n DEV 1         # 网卡吞吐
ethtool -S eth0               # 丢包/错误计数（rx_dropped、tx_dropped）
```

网卡软中断高：`mpstat -P ALL` 看 si，必要时启用 RPS/RSS 多队列。

## 6. 定位进程级问题

```bash
pidstat -u -r -d -w 1        # 单进程 CPU/内存/IO/上下文切换
strace -p <pid> -f -tt       # 系统调用（谨慎：影响性能）
perf top                     # 热点函数
```

## 7. 快速排查流程（Runbook）

```text
1. uptime：负载趋势
2. top -c：CPU/内存总览，找异常进程
3. vmstat 1 5：区分 CPU / IO / swap 瓶颈
4. iostat -x 1 / free -h：确认磁盘或内存
5. ss -s：确认网络连接
6. 锁定进程 → 日志 / 调用链 / 系统调用
7. 止损（重启/限流/扩容）→ 根因 → 复盘
```

