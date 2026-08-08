# Kafka 运维要点与排查

## 1. 核心概念

- **Topic / Partition**：Partition 是并行单元，同一 partition 内消息有序。
- **副本（Replication）**：每个 partition 有 Leader + Follower；ISR（同步副本集合）决定可用性。
- **Consumer Group**：组内消费者分担 partition；重平衡（Rebalance）时会短暂暂停消费。
- **Producer 语义**：acks=0（可能丢）、acks=1（Leader 确认）、acks=all（最安全）。

## 2. 部署与配置

- Controller（KRaft 模式为 controller quorum；ZooKeeper 模式为 broker 中的 controller）：建议 3 节点。
- 磁盘：**建议数据盘独立、大容量、顺序 IO**；单 broker 磁盘数 ≥ 分区副本数/吞吐需求。
- 关键参数：
  - `log.retention.hours` / `log.retention.bytes`：保留策略
  - `num.partitions`：默认分区数
  - `replication.factor`：副本因子（生产 ≥ 2）
  - `min.insync.replicas`：配合 acks=all 保证不丢

## 3. 监控指标

- Broker：`UnderReplicatedPartitions`（副本滞后）、`OfflinePartitions`、CPU/磁盘/网络。
- 消费：Consumer Lag（积压）、消费速率。
- Topic：消息进/出速率、分区数、单分区吞吐。

## 4. 常见故障

| 问题 | 排查与处理 |
| --- | --- |
| 消费积压（Lag 上涨） | 消费逻辑慢（DB/下游慢）、消费者数 < 分区数、重平衡频繁；临时扩容消费者或优化消费 |
| 重平衡频繁 | session.timeout 过短、消费者处理慢、心跳超时；调大 `max.poll.interval.ms`/`session.timeout.ms` |
| 消息丢失 | 检查 acks、`min.insync.replicas`、Broker 崩溃时未刷盘；生产者重试配置 |
| 消息重复 | at-least-once 语义下消费端需幂等 |
| 分区不均衡 | 新 broker 后 rebalance/重分区；检查 `kafka-reassign-partitions` |
| 磁盘满 | 调整保留策略、扩容、压缩（compaction）场景检查 tombstone |
| 网络吞吐低 | 压缩（lz4/zstd）、批量（batch.size）、单分区瓶颈 |

## 5. 生产建议

- Topic 分区数规划：按目标吞吐（单分区几十 MB/s）+ 未来扩展预留，分区过多增加元数据开销。
- 消费端幂等设计是底线（重复消费必然存在）。
- 备份/恢复：Kafka 本身不主推备份，重要数据通过 MirrorMaker 跨集群复制或 Connector 落库。
- 大消息（>1MB）谨慎：影响吞吐与内存，考虑对象存储 + 引用。

