# ELK / Elasticsearch 运维、调优与故障排查

## 1. 架构

```text
Logstash/Filebeat（采集） → Kafka（缓冲，可选） → Logstash（解析/清洗）
  → Elasticsearch（存储/检索） → Kibana（可视化）
```

Elasticsearch 角色：

- Master 节点（控制面，建议 3 个，避免脑裂）
- Data 节点（存储与检索，水平扩展）
- Coordinating/Ingest 节点（接收请求、预处理）

## 2. 分片与索引设计

- **分片数量规划**：单分片 30-50GB 为宜；分片太多 → 元数据开销大；太少 → 无法扩展。
- **索引模板**：按天/周建索引（日志场景按天），配合 ILM（生命周期管理）自动滚动与删除。
- **Mapping 前置规划**：字段类型提前定义，避免动态映射导致的类型冲突与膨胀。
- **副本数**：生产至少 1 副本（可用性与读性能），注意副本写入翻倍成本。

## 3. 性能优化

### 3.1 写入优化

- 批量写入（bulk，每批 1-5MB）。
- `refresh_interval` 调大（如 30s-60s），减少刷新开销（牺牲近实时性）。
- 关闭不需要的 `_source` 或仅保留必要字段（谨慎，影响重放）。
- 磁盘选 SSD；`index.translog.durability: async` 权衡数据安全。
- 冷热分层：热节点 SSD，冷节点 HDD。

### 3.2 查询优化

- 只查需要的字段（`_source` 过滤）。
- 避免深分页（`from+size` 超过 10000 用 `search_after`/scroll）。
- 聚合尽量在查询时过滤；大聚合走异步搜索或预聚合。
- 用 Filter 上下文（缓存友好）区分于 Query 计分。
- 查看慢查询：`index.search.slowlog`。

## 4. 集群健康与故障排查

### 4.1 集群状态

```text
green：主分片+副本都正常
yellow：主分片正常，副本缺失（如单节点、节点故障）
red：存在未分配的主分片，数据不可用
```

```bash
GET _cluster/health
GET _cat/indices?v
GET _cat/shards?v          # 看未分配分片
```

### 4.2 yellow 处理

- 单节点集群正常现象；多节点则检查副本数配置与节点是否掉线。

### 4.3 red 处理

- 找到未分配主分片：`GET _cat/shards?v&h=index,shard,prirep,state,unassigned.reason`
- 原因排查：节点掉线、磁盘水位（`cluster.routing.allocation.disk.watermark`）、分片数超限。
- 恢复：先恢复节点 → 再 `POST _cluster/reroute?retry_failed=true`。
- 数据丢失风险时评估从快照恢复。

### 4.4 磁盘水位

```yaml
cluster.routing.allocation.disk.watermark.low: 85%
cluster.routing.allocation.disk.watermark.high: 90%
cluster.routing.allocation.disk.watermark.flood_stage: 95%
```

- flood_stage 后索引会只读，必须清理空间（删过期索引、扩容）后解除只读。

### 4.5 节点 JVM 问题

- `heap` 设置为物理内存一半且不超过 31GB（指针压缩），剩余留给 OS page cache。
- GC 频繁：`_nodes/stats/jvm` 看 gc 次数；调大堆或减少分片/查询负载。

## 5. 日志链路常见问题

| 问题 | 排查 |
| --- | --- |
| 日志不写入 ES | 检查 Filebeat 输出、Kafka topic、Logstash pipeline 报错 |
| 字段类型冲突 | 删除冲突索引或用模板固定 mapping |
| 索引只读 | 磁盘水位 flood_stage / ILM 错误 |
| 查询慢 | 字段未建索引、深分页、聚合过大、分片过多 |
| 数据延迟大 | Kafka 消费慢、Logstash 并发不足、bulk 积压 |

## 6. 备份与恢复

- 用快照仓库（S3/OSS/本地）做定时快照。
- `GET _snapshot/<repo>/<snapshot>` 验证快照完成。
- 定期演练恢复：创建新集群 → 从快照恢复 → 校验数据。

