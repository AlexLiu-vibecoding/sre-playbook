# S3 存储类选型、适用产品与保留周期

> S3 是云上数据分层存储的核心。本文按「访问频率 × 检索时效 × 保留周期」选存储类，并给出生命周期（Lifecycle）设计示例。

## 一、S3 存储类总览

| 存储类 | 适用场景 | 检索时效 | 最低计费时长 | 成本特征 |
| --- | --- | --- | --- | --- |
| S3 Standard | 高频访问的热数据（日志实时分析、CDN 源、活跃业务数据） | 毫秒级 | 无 | 存储单价最高，无取回费 |
| S3 Intelligent-Tiering | 访问模式不稳定的数据（自动在热/冷层间移动） | 毫秒级 | 30 天 | 存储费 + 监控/自动化费，无取回费 |
| S3 Standard-IA | 低频但需要毫秒访问（备份、合规留存、低频日志） | 毫秒级 | 30 天 | 存储单价低于 Standard，有取回费 |
| S3 One Zone-IA | 可重建的低频数据（中间产物、临时副本） | 毫秒级 | 30 天 | 比 Standard-IA 便宜，仅单可用区 |
| S3 Glacier Instant Retrieval | 极低频但需毫秒级访问（长期档案的即时读取） | 毫秒级 | 90 天 | 存储很便宜，取回费较高 |
| S3 Glacier Flexible Retrieval | 归档数据，可接受分钟级取回（合规档案、历史日志） | 分钟级（1-12 小时） | 90 天 | 存储更便宜，取回分 Expedited/Standard/Bulk |
| S3 Glacier Deep Archive | 极长期归档（多年保留、极少访问） | 小时级（12-48 小时） | 180 天 | 最便宜，取回最慢最贵 |
| S3 Express One Zone | 高性能单区（训练数据、高频读写） | 毫秒级（低延迟） | 无 | 单价高，为性能买单 |

> 价格示意（非精确报价）：Standard ≈ $0.023/GB·月，Standard-IA ≈ $0.0125/GB·月，Glacier Flexible ≈ $0.0036/GB·月，Deep Archive ≈ $0.00099/GB·月。实际以官方定价页与区域为准。

## 二、选型决策维度

```text
数据是否经常访问？
├─ 是（每天多次）→ S3 Standard
├─ 访问模式不稳定 → S3 Intelligent-Tiering
├─ 低频（每月几次）：
│   ├─ 需要毫秒访问 → Standard-IA
│   └─ 可重建/单区即可 → One Zone-IA
├─ 极低频（每年几次）：
│   ├─ 需要秒级返回 → Glacier Instant Retrieval
│   ├─ 可等分钟级 → Glacier Flexible Retrieval
│   └─ 可等数小时、长期保留 → Glacier Deep Archive
└─ 高性能低延迟场景 → Express One Zone
```

关键权衡：

- **存储费 vs 取回费**：越冷越省存储费，但取回费（数据量 + 请求数）越高；低频小数据取回，成本可能反超热存储。
- **最低计费时长**：短生命周期对象放进 Glacier 类会按最低时长（30/90/180 天）收费，短期数据不要直接归档。
- **持久性**：Standard 与 Glacier 类均为 11 个 9（99.999999999%）；One Zone 仅单可用区，数据丢失风险高，只放可重建数据。

## 三、生命周期（Lifecycle）与保留周期设计

### 3.1 两条规则

1. **转移（Transition）**：按天把对象迁移到更冷存储类。
2. **过期（Expiration）**：按天删除对象。

### 3.2 常见保留策略示例

| 数据阶段 | 保留周期 | 存储类 | 说明 |
| --- | --- | --- | --- |
| 热数据 | 0-30 天 | S3 Standard | 活跃访问、实时分析 |
| 温数据 | 30-90 天 | Standard-IA / Intelligent-Tiering | 低频查询 |
| 冷数据 | 90-365 天 | Glacier Flexible Retrieval | 历史日志、合规留存 |
| 归档 | 365 天以上 | Glacier Deep Archive | 多年保留、极少访问 |

备份/快照场景（与数据库备份策略配套）：

| 备份类型 | 保留周期 | 存储类 |
| --- | --- | --- |
| 增量备份 | 近 3 个月 | Standard-IA |
| 全量备份 | 近 1 年 | Glacier Flexible Retrieval |
| 年度归档快照 | 多年 | Glacier Deep Archive |

### 3.3 生命周期规则示例

```json
{
  "Rules": [
    {
      "ID": "logs-lifecycle",
      "Prefix": "logs/",
      "Status": "Enabled",
      "Transitions": [
        { "Days": 30, "StorageClass": "STANDARD_IA" },
        { "Days": 90, "StorageClass": "GLACIER" },
        { "Days": 365, "StorageClass": "DEEP_ARCHIVE" }
      ],
      "Expiration": { "Days": 730 }
    }
  ]
}
```

## 四、与阿里云 OSS 对应

| AWS S3 | 阿里云 OSS |
| --- | --- |
| Standard | 标准存储 |
| Intelligent-Tiering | 智能分层访问（按访问频率自动调层） |
| Standard-IA | 低频访问存储 |
| One Zone-IA | 本地冗余（同城冗余）低频 |
| Glacier Flexible | 归档存储 |
| Glacier Deep Archive | 冷归档存储 |
| Lifecycle | 生命周期规则（同样支持按天转层与删除） |

选型逻辑完全一致：高频用标准、低频用低频/归档、长期用冷归档；生命周期规则按天数自动分层。

## 五、注意事项

1. **先算账再分层**：低频但单次取回量大的数据，比较「一直放 Standard」与「转归档 + 取回费」哪个便宜。
2. **版本控制**：开启版本控制时，旧版本同样占用存储并受生命周期影响；给旧版本配独立生命周期，防止「删了当前版本，历史版本还占钱」。
3. **最小对象大小**：部分冷存储类按 128KB 计费，小对象（小于 128KB）放冷类不划算。
4. **取回模式**：Glacier Flexible 支持 Expedited（加急）/ Standard / Bulk（批量），按时效选模式，避免为不紧急的数据付加急费。
5. **生命周期与成本监控**：分层后定期核对成本看板，确认转移规则生效、无异常积压。

## 六、检查清单

- [ ] 按访问频率为每类数据选定存储类
- [ ] 生命周期规则（转移 + 过期）已配置
- [ ] 版本控制的旧版本有独立生命周期
- [ ] 小对象与最低计费时长已评估
- [ ] 取回时效与成本已确认
- [ ] 与数据库/应用备份保留策略对齐（如近 3 月增量 + 年度全量）
- [ ] 成本看板覆盖各存储类用量与费用

