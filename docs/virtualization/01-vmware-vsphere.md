# VMware vSphere 运维手册

## 1. vSphere 架构

```text
vCenter Server（管理平面：vCenter Server Appliance）
  ├─ ESXi Host（虚拟化层，Hypervisor）
  ├─ 集群 Cluster（HA/DRS 能力）
  ├─ 数据存储 Datastore（VMFS/NFS/vSAN）
  └─ 网络 vSwitch/分布式交换机（vDS）
```

关键组件：

- **ESXi**：裸机 Hypervisor，直接管理硬件与虚拟机。
- **vCenter**：集中管理、vMotion、HA、DRS、模板、权限。
- **vSphere HA**：主机故障后在其他主机重启虚拟机。
- **vSphere DRS**：基于资源负载动态迁移（vMotion）均衡。
- **vSAN**：分布式存储，把主机本地盘聚合为共享存储。

## 2. 日常运维清单

### 每日

- ESXi 主机健康（告警、日志、存储状态）。
- 虚拟机 CPU/内存/磁盘水位。
- vCenter 服务状态。

### 每周

- 存储空间与性能（IOPS、延迟）。
- 备份任务执行情况。
- 补丁检查（ESXi 补丁、vCenter 更新）。

### 每月

- 资源容量评估（CPU/内存/存储增长趋势）。
- 快照清理（遗留快照是磁盘空间杀手）。
- 权限审计。

## 3. 虚拟机生命周期

- **创建**：模板/克隆 → 配置资源 → 网络 → 加域 → 交付。
- **变更**：配置变更走变更流程；在线加 CPU/内存（部分系统支持热添加）；磁盘扩容需先扩磁盘再扩分区。
- **迁移**：vMotion（在线迁移）、Storage vMotion（跨存储迁移）。
- **删除**：先确认数据已备份/移交，再删除，避免误删。

## 4. 故障排查

| 故障 | 排查方向 |
| --- | --- |
| 虚拟机无法启动 | 存储可达性、虚拟机文件完整性、资源不足、HA 配置 |
| 主机进入维护模式卡住 | 检查是否有未迁移虚拟机、vMotion 失败原因 |
| 虚拟机慢 | 资源争抢（CPU ready 高）、存储延迟、快照过大 |
| 存储告警 | 容量、IOPS、延迟、vSAN 健康 |
| HA 不生效 | 隔离响应配置、主机网络（管理网络）、心跳存储 |
| vCenter 不可用 | 先确认 ESXi 主机是否受影响（虚拟机继续运行）；恢复 vCenter |

常用排查命令/工具：

- `esxtop`：实时资源（CPU ready、内存、磁盘延迟）。
- vSphere Client：告警与任务日志。
- `vmkping`：主机网络连通性。
- `esxcli storage core device list`：存储设备状态。

## 5. 备份与容灾

- 虚拟机备份：Veeam/云备份/快照（快照不是备份，需独立备份链路）。
- 备份验证：定期恢复演练。
- 容灾：Site Recovery Manager（SRM）+ 复制；异地机房。
- **演练**：每年至少一次主机故障演练、一次恢复演练。

## 6. 最佳实践

- 快照生命周期管理：短期使用，及时删除。
- 资源上限（Reservation/Limit）按业务设置，防止单个虚拟机占满集群。
- 管理网络与业务网络隔离；ESXi 管理口最小暴露。
- 时间同步（NTP）与 DNS 正确性直接影响 vCenter 集群健康。
- 文档化：拓扑、命名规范、网络规划、存储规划。
