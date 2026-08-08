# MongoDB 运维与故障排查

## 1. 架构与原理

- **文档模型**：BSON，天然适合 JSON 结构数据。
- **副本集（Replica Set）**：Primary + Secondary + Arbiter（可选），多数派选举。
- **分片集群（Sharding）**：mongos（路由）+ Config Server + Shard（每个 Shard 是副本集）。
- **存储引擎**：WiredTiger（默认），文档级并发控制 + 压缩。

## 2. 索引与查询优化

```javascript
db.collection.createIndex({ userId: 1, createTime: -1 }, { name: "idx_user_time" })
db.collection.find({ userId: 123 }).explain("executionStats")
```

- `explain` 关注：`totalDocsExamined`（扫描文档数）、`totalKeysExamined`、`winningPlan`（是否 COLLSCAN）。
- 单键/复合索引同样遵循前缀原则。
- 分页用游标（`_id` / 排序字段）而不是大 offset。
- TTL 索引清理过期数据；注意 TTL 扫描有延迟。

## 3. 日常运维

- 备份：`mongodump`（逻辑）或文件系统快照/云盘快照；副本集可用 `oplog` 做时间点恢复。
- 监控：连接数、oplog 窗口（`db.printReplicationInfo()`）、延迟、慢查询。
- 慢查询：`db.setProfilingLevel(1, 100)`（100ms 以上记录）。
- 分片场景：chunk 均衡、`jumbo` chunk 处理、分片键选择（高基数、均匀分布）。

## 4. 故障排查

| 现象 | 排查与处理 |
| --- | --- |
| Primary 切换 | 检查选举原因：节点延迟、网络分区、心跳丢失；确认多数派节点正常 |
| 从库延迟大 | 检查 oplog 窗口、大写入、从库负载；`rs.status()` 看 syncSource 与 lag |
| 连接数打满 | `maxIncomingConnections`、连接池未释放、慢操作占连接 |
| 慢查询导致雪崩 | 杀掉慢操作（`db.currentOp()` + `db.killOp()`）、加索引、限流 |
| 磁盘满 | 清理集合/归档；启用压缩；TTL；扩容 |
| 锁竞争 | WiredTiger 文档级锁，仍有全局写锁场景（索引重建、集合 rename）需避高峰 |
| 内存压力 | WiredTiger cache 默认占内存 50%；调 `storage.wiredTiger.engineConfig.cacheSizeGB` 并给 OS 留余量 |

## 5. 安全基线

- 开启认证（x509 或 SCRAM）；最小权限角色。
- 网络隔离：仅内网/专有网段暴露。
- 加密：传输 TLS、静态加密（云盘加密）。
- 定期巡检：版本 EOL、权限审计、备份验证。

