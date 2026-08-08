# 负载均衡：四层 / 七层 与生产实践

## 1. 四层 vs 七层

| 维度 | 四层（L4） | 七层（L7） |
| --- | --- | --- |
| 转发依据 | IP + 端口（TCP/UDP） | HTTP 报文（URL、Header、Cookie） |
| 性能 | 高，转发快 | 相对低，需要解析报文 |
| 能力 | 连接转发、简单健康检查 | 路由、改写、限流、鉴权、缓存、灰度 |
| 典型实现 | LVS、HAProxy、云上 NLB/SLB(四层) | Nginx、HAProxy、云上 ALB/SLB(七层) |
| 适用 | 海量连接、长连接、数据库/中间件 | HTTP 服务、微服务网关、CDN 源站 |

**选型原则**：无状态 HTTP 业务优先七层（灵活）；高吞吐长连接优先四层（性能）。

## 2. Nginx 负载均衡实践

### upstream 配置

```nginx
upstream backend {
    least_conn;                     # 最少连接；默认轮询 round_robin
    server 10.0.0.1:8080 weight=3 max_fails=2 fail_timeout=10s;
    server 10.0.0.2:8080 weight=1 backup;   # backup 备用节点
    keepalive 32;                   # 与上游保持长连接
}

server {
    listen 80;
    location /api/ {
        proxy_pass http://backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 3s;
        proxy_read_timeout 30s;
    }
}
```

### 关键参数

- `max_fails / fail_timeout`：连续失败多少次摘除、多久探测一次。
- `proxy_next_upstream`：允许请求失败后重试下一个节点（注意幂等性，POST 慎用）。
- `keepalive`：减少上游 TCP 新建连接，显著降低 TIME_WAIT。
- `proxy_connect_timeout / read_timeout`：快速失败，避免请求悬挂。

## 3. 健康检查设计

- **不要只做 TCP 端口检查**：端口通不代表服务健康，尽量做 HTTP 探活（返回码 + 关键逻辑）。
- 探活路径独立轻量：如 `/healthz`，不要依赖数据库做健康检查（否则故障扩散）。
- 摘除/恢复要**平滑**：恢复前先放少量流量（预热），避免雪崩。

## 4. 会话保持（Session Stickiness）

| 方式 | 说明 | 适用 |
| --- | --- | --- |
| Cookie 会话保持 | LB 下发 cookie，按 cookie 路由 | 有状态 HTTP |
| IP Hash | 按来源 IP 哈希 | 简单但运营商出口 IP 变化大 |
| 后端共享存储 | 会话放 Redis | **推荐**，负载均衡无需有状态 |

> 最佳实践：让后端**无状态化**（Session 放 Redis/DB），负载均衡天然可横向扩容。

## 5. 灰度与发布

- **权重灰度**：新节点 `weight=0` → 观察 → 逐步调大权重。
- **金丝雀**：按 Header/Cookie/比例路由到新版本。
- **摘流发布**：发布前把节点从 LB 摘除（drain），发布完健康检查通过后自动恢复。

## 6. 常见故障排查

| 现象 | 排查方向 |
| --- | --- |
| 后端 502 | 后端进程挂、连接数打满、健康检查误判、防火墙 |
| 部分请求失败 | `max_fails` 摘除、`proxy_next_upstream` 未生效、某节点异常 |
| 流量倾斜 | 权重配置错误、least_conn 未生效、健康检查误恢复 |
| 会话丢失 | 会话保持失效、后端扩容后 hash 变化 |
| 连接数打满 | `worker_connections`、TIME_WAIT、上游 keepalive 未配 |

## 7. 云上负载均衡（阿里云 / AWS 映射）

| 能力 | 阿里云 | AWS |
| --- | --- | --- |
| 四层 | SLB（NLB 类型） | NLB |
| 七层 | SLB（ALB 类型）/ 网关 | ALB |
| 特性 | 健康检查、会话保持、WAF 联动 | Target Group、Auto Scaling 联动、跨区 |

- 跨可用区部署：LB 本身多可用区冗余，后端节点分布到 ≥2 个可用区。
- 健康检查阈值、间隔与业务探活匹配，避免「LB 认为健康但流量进来就 5xx」。

