# 阿里云实操经验沉淀（真实实操领域）

> 阿里云实操经验与工程实践。原则：只记录实际做过、可复现的架构与操作。

## 1. 常用服务全景

| 类别 | 服务 | 典型用途 |
| --- | --- | --- |
| 计算 | ECS、弹性伸缩 ESS | 应用/中间件/自建服务 |
| 容器 | ACK（K8s）、ACR（镜像） | 容器化部署 |
| 网络 | VPC、SLB（NLB/ALB）、EIP、CEN | 网络与负载均衡 |
| 存储 | OSS、NAS、云盘 | 对象存储/文件/块存储 |
| CDN | 阿里云 CDN、DCDN | 静态加速、下载分发 |
| 数据库 | RDS、Redis、MongoDB、PolarDB | 托管中间件 |
| 监控 | CloudMonitor、ARMS、日志服务 SLS | 监控与日志 |
| 安全 | RAM、安全组、WAF、DDoS 防护 | 权限与安全 |
| 成本 | 成本分析、节省计划 | 成本管理 |

## 2. 典型架构（可复现）

### 高可用 Web 架构

```text
DNS（云解析/GTM） → SLB（多可用区） → ECS/ACK（≥2 可用区）
  → RDS 主备 + 只读 / Redis 主从
  → OSS 静态资源 + CDN 加速
```

要点：

- VPC 划分：生产/测试/管理子网；安全组按业务最小放通。
- 多可用区部署，单可用区故障不影响整体。
- 数据库用托管（RDS 主备 + 自动备份 + 时间点恢复）。
- 静态资源走 OSS + CDN，减轻源站。

### 下载/文件分发架构

```text
OSS（源站，跨区复制） → CDN（边缘加速 + 预热/刷新） → 客户端
```

- 大文件用 CDN 下载加速 + 分片/断点续传。
- 发布时预热，更新时刷新。
- 回源走内网（OSS 内网地址），节省流量费用。

## 3. 常用操作与命令

```bash
# CLI 配置
aliyun configure set --profile default --mode AK --access-key-id <AK> --access-key-secret <SK> --region cn-hangzhou

# 查询 ECS 实例
aliyun ecs DescribeInstances --RegionId cn-hangzhou --output cols=InstanceId,InstanceName,Status rows=Instances.Instance[]

# 安全组放行
aliyun ecs AuthorizeSecurityGroup --RegionId cn-hangzhou --SecurityGroupId sg-xxx --IpProtocol tcp --PortRange 80/80 --SourceCidrIp 0.0.0.0/0
```

## 4. 运维实操要点

### ECS 运维

- 系统盘/数据盘规划；云盘快照策略（每日 + 大变更前手动快照）。
- 实例规格选型：按业务负载（CPU/内存）选型，避免规格过小频繁告警或过大浪费。
- 弹性伸缩：按负载/定时策略伸缩，伸缩组与 SLB 联动。
- 安全组规则审计：最小化端口、来源限制。

### 网络与安全

- VPC 网段规划避免冲突；跨账号/跨地域用 CEN/对等连接。
- 公网入口收敛：EIP 挂 SLB，不放公网 IP 到实例。
- RAM：子账号最小权限、AccessKey 定期轮换、不使用主账号 AK。
- 云防火墙/安全组双层防护，管理端口仅白名单。

### 监控与告警

- CloudMonitor 配置：实例 CPU/内存/磁盘/网络、SLB 健康检查、RDS 指标。
- 事件订阅：磁盘满、欠费、实例异常。
- 日志：SLS 统一收集应用与访问日志。

### 成本优化

- 闲置资源巡检（低利用率实例、未绑定 EIP、未使用云盘）。
- 按量 vs 包年包月 vs 节省计划：稳定负载包年包月，弹性负载按量 + 伸缩。
- 存储分层：OSS 低频/归档存储；快照清理。
- 流量成本：走内网、CDN 回源内网化。

## 5. 故障场景（实操型）

| 场景 | 排查与处理 |
| --- | --- |
| 实例连不上 | 控制台 VNC 直连 → 网络/安全组/防火墙/系统负载 |
| 磁盘满 | 云盘监控 + 日志清理 + 扩容（在线扩容数据盘） |
| 网站 502 | SLB 后端健康检查、应用进程、RDS 连接 |
| 安全组误配 | 控制台检查规则，先恢复最小放通 |
| 欠费停机 | 开通余额提醒，设置预算告警 |
| 跨地域访问慢 | CDN/就近接入、专线/云企业网、性能测试 |

