# Redis 运维与缓存问题排查

## 1. 核心原理

- 单线程执行命令（6.0+ 引入多线程 IO 但命令执行仍基本串行）→ **耗时长命令会阻塞所有请求**。
- 数据结构：String、Hash、List、Set、ZSet、Stream 等，选型决定内存与复杂度。
- 持久化：RDB（快照）与 AOF（追加日志）；`appendfsync` 策略影响安全与性能。
- 集群模式：主从复制、哨兵（Sentinel）高可用、Cluster 分片。

## 2. 缓存三大问题

### 2.1 缓存穿透

**现象**：查询不存在的数据，缓存未命中直接打到数据库。

对策：

- 缓存空值（短 TTL）。
- 布隆过滤器拦截不存在 key。
- 参数校验兜底（非法请求直接拒绝）。

### 2.2 缓存击穿

**现象**：某个热点 key 过期瞬间，大量请求同时打到数据库。

对策：

- 互斥锁（只允许一个请求回源重建缓存）。
- 逻辑过期（缓存永不过期，值内带过期时间，异步刷新）。
- 热点 key 主动续期/预热。

### 2.3 缓存雪崩

**现象**：大量 key 同时过期（或 Redis 整体不可用），请求全部打向数据库。

对策：

- 过期时间加随机抖动（基础 TTL ± 随机值）。
- 多级缓存（本地缓存 + Redis）。
- 高可用：主从 + 哨兵/Cluster；降级开关（缓存不可用时返回兜底数据或限流）。

## 3. 大 Key 与热 Key

### 大 Key

**识别**：

```bash
redis-cli --bigkeys              # 扫描大 key 候选
```

**危害**：阻塞单线程、内存不均、删除时阻塞（`DEL` 大 key 卡顿）。

**处理**：

- Hash/List 分片（拆成多个小 key 或使用 `HSET` 字段拆分）。
- 删除用 `UNLINK`（异步）或分批 `SCAN + DEL`。
- 限制单 key 大小规范（如 < 10MB），写入侧拦截。

### 热 Key

**识别**：`INFO` 的 `keyspace_hits/misses`、客户端侧统计、`MONITOR`（谨慎）。

**处理**：

- 本地缓存（Caffeine/进程内）扛热点。
- key 加随机后缀分散到多实例（读写侧都按规则）。
- 读多写少场景用副本分担读。

## 4. 持久化与数据安全

- 默认建议 AOF + RDB 双开；`appendfsync everysec` 兼顾性能与最多丢 1 秒数据。
- 主从切换后注意「从库数据未完全同步」场景（`min-slaves-to-write` 防止脑裂丢数据）。
- 定期演练：从备份恢复、主从切换。
- 大内存实例的 RDB 持久化会造成 fork 阻塞，注意 `maxmemory` 与碎片整理。

## 5. 常见故障排查

| 现象 | 排查 |
| --- | --- |
| 命令超时/卡顿 | `INFO commandstats`、慢日志 `SLOWLOG GET`；检查大 key、`KEYS`/`SMEMBERS` 等危险命令 |
| 内存暴涨 | `INFO memory`、`MEMORY USAGE <key>`、`redis-cli --bigkeys`；检查未设置 TTL 的 key |
| 连接拒绝 | `maxclients` 打满、`tcp-backlog`、系统 `ulimit -n` |
| 数据丢失 | 持久化策略、主从不一致、`maxmemory-policy` 逐出（eviction） |
| 主从切换后写入失败 | 哨兵/Cluster 配置、脑裂保护参数 |
| 缓存与 DB 不一致 | 更新顺序：先更新 DB 再删缓存（延迟双删兜底），或订阅 Binlog 异步刷新 |

## 6. 生产规范

- 所有 key 必须带业务前缀 + 明确 TTL。
- 禁止生产使用 `KEYS *`、`FLUSHALL`、`MONITOR`。
- 危险命令在配置中禁用/重命名（`rename-command`）。
- 容量规划：内存水位 70% 告警，预留主从/故障切换余量。
- 压测验证：`redis-benchmark` 或自研脚本，确认延迟与吞吐基线。

