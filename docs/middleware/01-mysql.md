# MySQL 运维、性能优化与故障排查

## 1. 架构与运行原理

- **InnoDB 存储引擎**：事务、行锁、MVCC、聚簇索引、Buffer Pool、Redo/Undo Log、Binlog。
- **一条查询的路径**：连接器 → 分析器 → 优化器 → 执行器 → 存储引擎。
- **主从复制**：主库 Binlog → 从库 IO 线程拉取写入 Relay Log → SQL 线程回放。
- **写入路径**：先写 Redo Log（WAL）与 Binlog，异步刷盘；`sync_binlog` 与 `innodb_flush_log_at_trx_commit` 决定数据安全与性能取舍。

## 2. 日常运维清单

- 备份：全量（逻辑/物理）+ Binlog 增量；定期演练恢复。
- 监控：QPS、慢查询、连接数、主从延迟、Buffer Pool 命中率、磁盘 IO。
- 账号与权限最小化；审计高风险操作。
- 版本升级与参数变更走变更流程，先灰度实例验证。

## 3. 性能优化

### 3.1 慢查询排查

```sql
-- 开启慢查询日志
SET GLOBAL slow_query_log = ON;
SET GLOBAL long_query_time = 1;

-- 查看执行计划
EXPLAIN SELECT ...;
```

`EXPLAIN` 关键字段：

- `type`：system > const > eq_ref > ref > range > index > **ALL（全表扫描，重点优化）**
- `rows`：预估扫描行数，越大越慢
- `Extra`：`Using filesort`、`Using temporary`、`Using index`（覆盖索引）

### 3.2 索引优化

- 最左前缀原则：联合索引按查询条件顺序建。
- 覆盖索引：让查询只走索引，避免回表。
- 区分度低的列（性别、状态）不适合单列索引。
- 隐式类型转换、函数包裹列会使索引失效（`WHERE DATE(create_time)=...` 改为范围查询）。
- 避免 `SELECT *`；大字段（TEXT/BLOB）不要进索引。

### 3.3 参数调优（核心）

```ini
innodb_buffer_pool_size = 物理内存的 60%-75%
innodb_flush_log_at_trx_commit = 2   # 兼顾性能；金融场景用 1
sync_binlog = 1                        # 与上面对应；双 1 最安全
max_connections = 1000                 # 结合线程池与监控
innodb_log_file_size = 1G-4G           # 避免频繁 checkpoint
```

### 3.4 典型场景

| 场景 | 手段 |
| --- | --- |
| 大表分页慢 | 游标分页（WHERE id > 上次最大 id）代替 OFFSET |
| 热点行竞争 | 拆行/队列化/限流，减少单行更新 |
| 批量写入慢 | 分批提交、关闭自动提交、批量 Insert |
| 只读报表慢 | 读写分离走从库、汇总表、物化 |

## 4. 故障排查

### 4.1 主从延迟

排查顺序：网络带宽（大事务 Binlog 传输）→ 从库 SQL 线程执行慢（无主键/大事务/DDL）→ 从库负载（备份/分析任务抢占）→ 并行复制配置。

处理：

- 大事务拆小；DDL 用工具（pt-osc）在线执行。
- 从库加 `innodb_buffer_pool_size`、开并行复制（`slave_parallel_workers`）。
- 延迟持续增长先隔离从库流量。

### 4.2 连接数打满 / Too many connections

```sql
SHOW PROCESSLIST;   -- 看 Sleep 与异常连接
```

- 应用连接池未释放/未设置最大连接 → 修代码 + 连接池参数。
- 慢查询占住连接 → 先 Kill 慢查询止血，再优化 SQL。
- 突发流量 → 限流 + 扩容只读实例。

### 4.3 死锁

```sql
SHOW ENGINE INNODB STATUS;   -- LATEST DETECTED DEADLOCK
```

- 统一加锁顺序（事务内按相同顺序访问行/表）。
- 缩短事务时间；索引优化减少锁范围。
- 重试机制（业务层捕获 1213 错误重试）。

### 4.4 磁盘满 / 数据膨胀

- 慢日志、Binlog、临时文件占用排查（`du -sh /var/lib/mysql/*`）。
- 大表清理用分区表 + 分区裁剪，或分批 Delete（避免大事务）。
- Binlog 保留策略：按天数 + 备份完整性设置。

### 4.5 误操作恢复

- 有备份 + Binlog：恢复到误操作前时间点（`mysqlbinlog --stop-datetime`）。
- 前提：定期演练，恢复手册要可执行。

## 5. 监控指标（建议告警）

| 指标 | 阈值示例 |
| --- | --- |
| 连接数 | 达到 max_connections 的 80% |
| 慢查询数 | 超过基线 2 倍 |
| 主从延迟 | > 30s |
| Buffer Pool 命中率 | < 99% |
| 复制线程异常 | 立即 |
| 磁盘水位 | > 80% |

