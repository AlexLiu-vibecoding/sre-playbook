# AWS 实操经验沉淀（真实实操领域）

> AWS 实操经验与工程实践。原则：只记录实际做过、可复现的架构与操作。

## 1. 常用服务全景

| 类别 | 服务 | 典型用途 |
| --- | --- | --- |
| 计算 | EC2、Auto Scaling | 应用/自建服务 |
| 容器 | EKS、ECR | 容器化部署 |
| 网络 | VPC、ALB/NLB、Route 53、Global Accelerator | 网络与负载均衡 |
| 存储 | S3、EBS、EFS | 对象/块/文件存储 |
| 分发 | CloudFront、S3 Transfer Acceleration | CDN 与加速 |
| 数据库 | RDS（MySQL/PG）、Aurora、ElastiCache | 托管中间件 |
| 监控 | CloudWatch、X-Ray、CloudTrail | 监控/链路/审计 |
| 安全 | IAM、Security Groups、KMS、WAF | 权限与安全 |
| 成本 | Cost Explorer、Budgets | 成本管理 |

## 2. 典型架构（可复现）

### 高可用 Web 架构

```text
Route 53（DNS/故障转移） → CloudFront/ALB（多 AZ）
  → EC2 Auto Scaling（≥2 AZ） → RDS 多 AZ + 只读 / ElastiCache
  → S3 静态资源 + CloudFront
```

要点：

- 多 AZ 部署：应用与数据库跨可用区，单 AZ 故障自动恢复。
- IAM 最小权限：实例用 Instance Profile，不把 AK 放实例里。
- 安全组状态化：入站最小放通，出站按需。
- RDS 自动备份 + 多 AZ；ElastiCache 主从。

### 下载/文件分发架构

```text
S3（源站，跨区/跨账户复制） → CloudFront（边缘缓存 + 预热/失效）
```

- CloudFront 缓存策略：不可变文件长缓存 + 版本化 URL；更新用 `Invalidation`。
- S3 大文件直传/分片上传（multipart）；下载走 CloudFront 分担带宽。

## 3. 常用操作（CLI）

```bash
# 配置凭据
aws configure --profile ops

# 查看实例
aws ec2 describe-instances --region ap-southeast-1 --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name}'

# S3 同步
aws s3 sync ./dist s3://bucket/path --delete

# 安全组放行
aws ec2 authorize-security-group-ingress --group-id sg-xxx --protocol tcp --port 443 --cidr 0.0.0.0/0
```

## 4. 运维实操要点

### EC2 与弹性

- 实例选型与成本：按需/预留实例/Spot（无状态任务用 Spot）。
- 启动模板 + Auto Scaling：健康检查自动替换异常实例。
- EBS 快照策略与生命周期管理。
- 系统状态检查（Status Check）与实例状态检查的区分。

### 网络与安全

- VPC：Public/Private 子网规划，NAT Gateway 访问外网。
- 安全组与 NACL 双层；堡垒机集中入口。
- Route 53：健康检查 + 故障转移策略。
- IAM：角色（Role）而非长期密钥；Access Analyzer 定期审计。

### 监控

- CloudWatch：指标、告警、Dashboard、Logs。
- CloudTrail：API 审计（谁在什么时候做了什么）。
- X-Ray：链路追踪。

### 成本

- Cost Explorer 分析服务/账号维度成本。
- Budgets 预算告警（防止账单爆炸）。
- 生命周期策略：S3 数据自动转低频/归档/删除。

## 5. 故障场景（实操型）

| 场景 | 排查与处理 |
| --- | --- |
| 实例状态检查失败 | 查看系统日志（console output）、重启、换实例 |
| 网站超时 | 安全组/NACL、ALB 目标健康、目标组注册 |
| 磁盘满 | EBS 扩容（部分支持在线）+ 文件系统扩容 |
| S3 访问拒绝 | Bucket Policy、IAM、ACL、Public Access Block |
| CloudFront 缓存旧内容 | Invalidation、缓存策略、版本化 |
| 账单异常 | Budgets 告警、Cost Explorer、关停闲置资源 |

