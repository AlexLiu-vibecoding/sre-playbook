# ClickHouse 与 PostgreSQL 要点

## 1. ClickHouse

### 定位

列式存储 + 向量化执行的 OLAP 数据库，适合海量数据聚合分析（日志、指标、行为分析）。

### 关键概念

- MergeTree 家族表引擎（日志分析常用 `ReplicatedMergeTree`）。
- 分区（PARTITION BY）与排序键（ORDER BY）决定查询裁剪效率。
- 稀疏索引：按排序键建索引，范围查询高效。
- 物化视图：预聚合，提升报表查询。

### 优化

- 查询尽量过滤分区 + 只取需要的列。
- 避免高基数 GROUP BY 全表扫描，配合物化视图/预聚合。
- 写入批量插入（每批几万行以上），避免小批量高频写入。
- 分布式表 + 本地表配合；Replicated 表保证多副本。

### 排查

```sql
-- 慢查询
SELECT query, duration_ms FROM system.query_log WHERE is_initial_query=1 ORDER BY duration_ms DESC LIMIT 20;
-- 分区情况
SELECT partition, rows, bytes_on_disk FROM system.parts WHERE table='xxx' AND active;
```

- CPU 高：并发大查询 → 限流（`max_concurrent_queries`）或拆分查询。
- 内存超限：调大 `max_memory_usage` 或优化聚合。
- 磁盘：TTL（`TTL toDate(...) + INTERVAL 30 DAY DELETE`）管理冷数据。

## 2. PostgreSQL

### 核心原理

- 进程模型（每个连接一个进程）+ 共享缓冲；MVCC 多版本并发控制。
- WAL（Write-Ahead Log）保证崩溃安全；复制基于 WAL 流。
- 优化器：基于代价估算，`EXPLAIN ANALYZE` 看执行计划。

### 常用运维

```sql
-- 查看慢查询与锁
SELECT pid, state, wait_event_type, wait_event, query FROM pg_stat_activity WHERE state <> 'idle';
SELECT * FROM pg_locks WHERE NOT granted;   -- 锁等待
```

- 备份：`pg_dump`（逻辑）/ `pg_basebackup` + WAL 归档（物理）。
- 参数：`shared_buffers`（物理内存 25%）、`work_mem`（排序/哈希）、`effective_cache_size`。
- 索引：B-tree、GIN（全文/数组）、BRIN（大表顺序数据）。
- 常见问题：连接数（`max_connections`）、长事务阻塞 vacuum、膨胀（autovacuum 未跟上）、`idle in transaction` 连接占满。

### 排查要点

| 现象 | 处理 |
| --- | --- |
| 查询突然变慢 | `EXPLAIN ANALYZE`；检查统计信息是否过期（`ANALYZE`） |
| 锁等待 | `pg_stat_activity` 找阻塞源，`pg_blocking_pids()` |
| 表膨胀 | autovacuum 参数、手动 `VACUUM FULL`（注意锁表） |
| 主从延迟 | 大事务、WAL 归档慢、从库长查询 |
| 连接占满 | 连接池（PgBouncer）、`idle_in_transaction_session_timeout` |

