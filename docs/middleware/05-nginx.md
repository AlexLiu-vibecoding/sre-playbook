# Nginx 配置、调优与故障排查

## 1. 架构特点

- Master-Worker 进程模型：Worker 数量 = CPU 核数。
- 事件驱动（epoll），高并发下内存占用低。
- 可承载：静态资源、反向代理、负载均衡、缓存、限流、TLS 终结。

## 2. 核心配置

```nginx
worker_processes auto;
worker_rlimit_nofile 65535;

events {
    worker_connections 10240;      # 单 worker 最大连接
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    client_max_body_size 10m;

    # 静态资源缓存
    location /static/ {
        expires 7d;
        add_header Cache-Control "public";
    }

    # 限流
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    location /api/ {
        limit_req zone=api burst=20 nodelay;
        proxy_pass http://backend;
    }
}
```

### 连接数计算

```text
最大并发连接 ≈ worker_processes × worker_connections
（代理场景每个请求占 2 个连接：客户端 + 上游）
```

## 3. 性能调优要点

- `sendfile`、`tcp_nopush`：大文件/静态资源吞吐。
- `gzip` 压缩（权衡 CPU 与带宽，>1KB 才压）。
- 上游 `keepalive`：减少 TIME_WAIT 与握手开销。
- TLS：`ssl_session_cache`、TLS 1.2+、OCSP Stapling。
- 打开 access log 缓冲（`buffer=64k flush=5s`），避免日志写盘拖慢。

## 4. 故障排查

| 现象 | 排查方向 |
| --- | --- |
| 502 | 上游进程挂、端口不通、`proxy_pass` 配置错误、连接数满 |
| 504 | 上游处理超时：慢 SQL、线程阻塞、`proxy_read_timeout` 太小 |
| 499 | 客户端提前断开：上游慢、客户端超时；需查上游耗时 |
| 连接被拒 | `worker_connections` 满、`ulimit`、backlog 满 |
| 流量异常高 | access log 分析来源、WAF/CC 防护、限流生效情况 |

排查命令：

```bash
nginx -t                       # 配置校验
tail -f /var/log/nginx/error.log
tail -f /var/log/nginx/access.log | awk '{print $9}' | sort | uniq -c | sort -rn   # 状态码分布
ss -tan state time-wait | wc -l
```

## 5. 安全加固

- 隐藏版本号（`server_tokens off`）。
- 限制请求体大小、超时；对管理接口加 IP 白名单。
- TLS 配置安全套件，禁用弱协议。
- 日志脱敏（Cookie/Token 不落日志）。

