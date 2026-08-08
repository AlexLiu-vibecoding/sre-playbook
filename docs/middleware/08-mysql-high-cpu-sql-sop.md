# MySQL 高 CPU 消耗 SQL 发现与处理 SOP

## 文档目的

建立一套标准化流程，用于快速定位 MySQL 实例中高 CPU 消耗的 SQL 语句，并提供针对性的优化方案，降低数据库 CPU 占用率，提升系统稳定性。

## 适用范围

1. 运行 MySQL 5.7+ 版本的数据库实例（含云数据库 RDS MySQL）。
2. 数据库 CPU 使用率持续超过 70% 或出现周期性峰值的场景。
3. 运维、开发人员进行 SQL 性能优化的日常操作。

## 前置条件

1. 数据库账号具备 `performance_schema`、`INFORMATION_SCHEMA` 库的查询权限。
2. 确保 `performance_schema` 处于开启状态（MySQL 5.7 默认开启）：

```sql
SHOW VARIABLES LIKE 'performance_schema';
```

3. 云数据库 RDS 需确认 `show_compatibility_56` 参数配置（不影响本流程核心操作）。

## 一、高 CPU 消耗 SQL 的发现流程

### 1.1 快速定位高 CPU SQL（含所属数据库）

统计历史执行的 SQL 中 CPU 消耗 Top 的语句，并关联其所属数据库，核心指标包括总执行时间、执行次数、平均执行时间、锁等待时间：

```sql
SELECT
    CASE
        WHEN schema_name IS NOT NULL THEN schema_name
        WHEN digest_text LIKE 'SELECT%FROM %.' THEN SUBSTRING_INDEX(SUBSTRING_INDEX(digest_text, 'FROM ', -1), '.', 1)
        WHEN digest_text LIKE 'UPDATE %.' THEN SUBSTRING_INDEX(SUBSTRING_INDEX(digest_text, 'UPDATE ', -1), '.', 1)
        WHEN digest_text LIKE 'INSERT INTO %.' THEN SUBSTRING_INDEX(SUBSTRING_INDEX(digest_text, 'INSERT INTO ', -1), '.', 1)
        ELSE 'unknown'
    END AS db_name,
    LEFT(digest_text, 200) AS sql_text_short,
    SUM_TIMER_WAIT / 1000000000 AS total_time_ms,
    COUNT_STAR AS exec_count,
    ROUND(SUM_TIMER_WAIT / COUNT_STAR / 1000000000, 4) AS avg_time_ms,
    ROUND(SUM_LOCK_TIME / 1000000000, 4) AS total_lock_ms
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_TIMER_WAIT > 0
  AND schema_name NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys')
ORDER BY total_time_ms DESC
LIMIT 10;
```

### 1.2 实时监控活跃高 CPU 会话

定位当前正在执行的、消耗 CPU 的 SQL 语句，适用于 CPU 瞬时飙高的场景：

```sql
SELECT
    id AS process_id,
    user,
    host,
    db AS db_name,
    command,
    time AS execution_time_sec,
    state,
    info AS sql_text
FROM INFORMATION_SCHEMA.PROCESSLIST
WHERE
    command != 'Sleep'
    AND info REGEXP 'SELECT|INSERT|UPDATE|DELETE'
ORDER BY execution_time_sec DESC;
```

重置所有语句摘要统计（清空 `events_statements_summary_by_digest` 表数据，可选）：

```sql
TRUNCATE TABLE performance_schema.events_statements_summary_by_digest;
```

### 1.3 确认高 CPU SQL 的表归属

针对定位到的高 CPU SQL，确认其操作的表所属的数据库，避免跨库误操作：

```sql
-- 替换 table_name 为目标表名
SELECT
    TABLE_SCHEMA AS db_name,
    TABLE_NAME,
    ENGINE,
    TABLE_ROWS
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME = 'EVENT';
```

## 二、高 CPU SQL 的根因分析方法

### 2.1 执行计划分析（EXPLAIN）

对高 CPU SQL 执行 `EXPLAIN`，分析其执行路径，判断是否存在全表扫描、文件排序等低效操作。

操作步骤：

1. 提取目标 SQL，替换占位符为真实测试值。
2. 执行 EXPLAIN：

```sql
EXPLAIN
SELECT `id`, `gmt_created` AS `gmtCreatedTime`
FROM EVENT
WHERE
    `state` = 'FAILED'
    AND `event_source` = 'ApiServerEventBroadcasterProd'
    AND `receiver_identity` = 'OpswareEventReceiver'
ORDER BY `id` ASC LIMIT 10;
```

3. 重点关注 EXPLAIN 结果中的核心字段：

| 字段 | 目标值 | 异常说明 |
| --- | --- | --- |
| type | ref、range、index | 出现 ALL 表示全表扫描，CPU 消耗极高 |
| key | 非 NULL，为目标索引名 | NULL 表示未走索引，需优化索引 |
| rows | 数值越小越好 | 数值过大表示扫描行数多，CPU 压力大 |
| Extra | Using index | 出现 Using filesort / Using temporary 表示额外消耗 CPU |

### 2.2 索引有效性分析

检查目标表的索引是否存在、是否合理，判断索引是否被有效使用：

```sql
-- 替换 table_name 为目标表名
SHOW INDEX FROM EVENT;

-- 统计索引基数，判断索引过滤性
SELECT
    INDEX_NAME,
    CARDINALITY AS 索引基数,
    NON_UNIQUE AS 是否非唯一索引
FROM INFORMATION_SCHEMA.STATISTICS
WHERE TABLE_NAME = 'EVENT'
ORDER BY SEQ_IN_INDEX;
```

### 2.3 高频小 SQL 的累积效应分析

关注执行次数极高（亿次级别）、单次执行时间短的 SQL，这类 SQL 的累积 CPU 消耗占比极高。

判断标准：**执行次数 > 1000 万次 且 平均执行时间 < 1ms**，需重点优化执行次数。

## 三、高 CPU SQL 的优化方案

### 3.1 索引优化（核心手段）

#### 3.1.1 索引设计原则

1. 等值条件字段优先放在索引前列，范围条件字段（如 `>`、`<`、`BETWEEN`）放在索引后列。
2. 索引包含查询的过滤字段、排序字段，实现覆盖索引，避免回表。
3. 避免创建冗余索引，定期清理无效索引。

#### 3.1.2 索引创建示例（以 EVENT 表为例）

针对 EVENT 表的高频查询条件，创建复合索引：

```sql
-- 切换到目标数据库
USE opsapiserver;

-- 索引1：适配 state+event_source+receiver_identity+due_date 条件的查询
CREATE INDEX idx_event_state_es_ri_duedate ON EVENT (state, event_source, receiver_identity, due_date, id);

-- 索引2：适配 state+event_source+receiver_identity 条件的无范围查询
CREATE INDEX idx_event_state_es_ri ON EVENT (state, event_source, receiver_identity, id);

-- 索引3：适配 state+event_source+receiver_identity+gmt_created 条件的范围查询
CREATE INDEX idx_event_state_es_ri_gmtcreated ON EVENT (state, event_source, receiver_identity, gmt_created, id);
```

#### 3.1.3 索引有效性验证

1. 确认索引创建成功：

```sql
SHOW INDEX FROM EVENT WHERE Index_name IN (
    'idx_event_state_es_ri_duedate',
    'idx_event_state_es_ri',
    'idx_event_state_es_ri_gmtcreated'
);
```

2. 重新执行 EXPLAIN，验证索引是否命中。
3. 监控索引使用情况（需开启 userstat 参数）：

```sql
SET GLOBAL userstat = 1;
FLUSH TABLES;

-- 业务运行后查询索引读取行数
SELECT
    INDEX_NAME,
    ROWS_READ
FROM INFORMATION_SCHEMA.INDEX_STATISTICS
WHERE TABLE_NAME = 'EVENT';
```

#### 3.1.4 索引回滚方案

若索引创建后出现性能回退，立即删除对应索引：

```sql
USE opsapiserver;

-- 删除单个索引
DROP INDEX idx_event_state_es_ri_duedate ON EVENT;

-- 批量删除索引
DROP INDEX idx_event_state_es_ri ON EVENT;
DROP INDEX idx_event_state_es_ri_gmtcreated ON EVENT;
```

### 3.2 高频小 SQL 的执行次数优化

针对执行次数极高的小 SQL（如 `SET SESSION TRANSACTION ISOLATION LEVEL`），通过以下方式减少执行次数：

1. **连接池层面配置**：在数据库连接池（Druid、HikariCP）的初始化参数中设置事务隔离级别，避免每次请求执行。
   - Druid 配置：`connection-init-sqls=SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED`
   - HikariCP 配置：`connectionInitSql=SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED`
2. **业务代码优化**：移除不必要的重复执行语句，合并相同逻辑的 SQL。

### 3.3 DML 语句优化

1. 批量操作：将单条 INSERT/UPDATE 改为批量操作，减少 SQL 执行次数：

```sql
-- 批量插入示例
INSERT INTO message_record (biz_id, msg_from, business_type)
VALUES (1, 'from1', 'type1'), (2, 'from2', 'type2'), ..., (50, 'from50', 'type50');

-- 批量更新示例
UPDATE alarm_rule
SET group_id = CASE id WHEN 1 THEN 'g1' WHEN 2 THEN 'g2' END,
    NAME = CASE id WHEN 1 THEN 'n1' WHEN 2 THEN 'n2' END
WHERE id IN (1,2);
```

2. 减少锁等待：确保更新语句的 WHERE 条件使用主键或唯一索引，避免行锁竞争加剧 CPU 消耗。

### 3.4 其他辅助优化手段

1. **缓存热点数据**：将高频查询结果缓存到 Redis，减少数据库查询次数。
2. **读写分离**：将读操作路由到从库，分散主库 CPU 压力。
3. **表分区**：对大表按时间字段（如 `gmt_created`）进行分区，提升查询效率。

## 四、优化效果验证

### 4.1 指标监控

1. **CPU 使用率**：通过云数据库控制台或 `top` 命令，观察 CPU 使用率是否降至 70% 以下。
2. **SQL 执行时间**：重新执行高 CPU SQL，对比优化前后的平均执行时间，目标降低 50% 以上。
3. **扫描行数**：通过 EXPLAIN 对比优化前后的 `rows` 字段值，目标降低 80% 以上。

### 4.2 验证 SQL

优化完成后，重新执行以下 SQL，确认高 CPU SQL 的总执行时间和执行次数显著下降：

```sql
SELECT
    CASE
        WHEN schema_name IS NOT NULL THEN schema_name
        ELSE 'unknown'
    END AS db_name,
    LEFT(digest_text, 200) AS sql_text_short,
    total_time_ms,
    exec_count,
    avg_time_ms
FROM (
    SELECT
        schema_name,
        digest_text,
        SUM_TIMER_WAIT / 1000000000 AS total_time_ms,
        COUNT_STAR AS exec_count,
        ROUND(SUM_TIMER_WAIT / COUNT_STAR / 1000000000, 4) AS avg_time_ms
    FROM performance_schema.events_statements_summary_by_digest
    WHERE SUM_TIMER_WAIT > 0
    ORDER BY total_time_ms DESC
    LIMIT 20
) t;
```

## 五、标准化操作清单

| 步骤 | 操作内容 | 责任人 | 验证方式 |
| --- | --- | --- | --- |
| 1 | 执行高 CPU SQL 发现 SQL，定位 Top SQL | 运维人员 | 查看结果中的 total_time_ms 排序 |
| 2 | 对目标 SQL 执行 EXPLAIN，分析执行计划 | 开发/运维人员 | 检查 type、key、rows 字段 |
| 3 | 根据执行计划设计并创建索引 | 运维人员 | 执行 SHOW INDEX 确认索引存在 |
| 4 | 验证索引命中情况 | 开发/运维人员 | 重新执行 EXPLAIN 确认 key 字段为目标索引 |
| 5 | 优化高频小 SQL 的执行次数 | 开发人员 | 对比优化前后的 exec_count 指标 |
| 6 | 监控 CPU 使用率和 SQL 执行时间 | 运维人员 | 通过控制台观察 CPU 指标，执行验证 SQL |
| 7 | 编写优化总结文档 | 运维人员 | 记录优化前后的指标对比 |

## 六、注意事项

1. **索引操作时机**：创建/删除索引需在业务低峰期执行，避免锁等待影响业务。
2. **权限控制**：数据库账号需遵循最小权限原则，避免使用超级账号进行日常操作。
3. **统计信息更新**：索引创建后执行 `ANALYZE TABLE`，更新表统计信息，确保优化器选择最优索引。
4. **回滚预案**：所有索引操作前需备份表结构，准备好回滚 SQL，出现异常时立即执行回滚。

