# 网络基础：TCP / HTTP / DNS 与故障排查

> 目标：掌握从「用户输入 URL」到「内容渲染」全链路的网络知识，并具备用命令定位网络故障的能力。

## 1. 一次请求的完整链路

```text
浏览器
  → DNS 解析（本地缓存 → 系统 hosts → 递归 DNS → 权威 DNS）
  → TCP 三次握手（SYN → SYN+ACK → ACK）
  → TLS 握手（HTTPS：ClientHello → ServerHello → 证书校验 → 密钥交换）
  → HTTP 请求（请求行 / 头部 / 体）
  → 四层负载均衡（可选）→ 七层负载均衡 / Nginx（可选）
  → 应用服务 → 中间件（缓存/数据库/消息队列）
  → 响应回传 → 浏览器渲染
```

排查时按链路逐段验证，**永远先确认「卡在哪一段」**，而不是直接查应用。

## 2. TCP 要点与故障

### 三次握手 / 四次挥手

- 握手：SYN → SYN+ACK → ACK。抓包看到只有 SYN 没有 SYN+ACK：对端不监听、被防火墙丢弃、或半连接队列满。
- 挥手：FIN → ACK → FIN → ACK。大量 TIME_WAIT 属正常现象（主动关闭方），过多时优化连接复用而不是盲目调短 TIME_WAIT。

### 常见 TCP 问题

| 现象 | 可能原因 | 排查 |
| --- | --- | --- |
| 连接超时 | 防火墙丢包、对端不监听、路由不通 | ping/telnet/nc、抓包 |
| 连接被拒（refused） | 端口未监听、监听在错误网卡 | `ss -lntp` |
| 大量 SYN_RECV | 半连接队列满、SYN 攻击 | `ss -s`、`netstat -s` |
| 大量 TIME_WAIT | 短连接频繁 | 开启 keep-alive、连接池 |
| 大量 CLOSE_WAIT | 应用未正确关闭连接（代码问题） | `ss -tan state close-wait` + 应用日志 |
| RST 频繁 | 对端无此连接/端口、防火墙、程序主动断开 | 抓包看 RST 来源 |

### 常用命令

```bash
ping -c 5 <host>                      # 基础连通性
telnet <host> <port>                  # 端口连通性
nc -vz <host> <port>                  # 端口探测
ss -tan state established             # 查看连接状态
ss -s                                 # 连接统计
tcpdump -i eth0 -n port 80            # 抓包
```

## 3. HTTP 要点与状态码

| 状态码 | 含义 | 排查方向 |
| --- | --- | --- |
| 200 | 成功 | - |
| 301/302 | 重定向 | Location 是否正确、缓存了旧跳转 |
| 304 | Not Modified | 缓存生效，符合预期 |
| 400 | 请求错误 | 参数、Header、URL 编码 |
| 401/403 | 认证/授权失败 | 密钥、权限、WAF/防火墙规则 |
| 404 | 不存在 | 路由、静态文件路径、CDN 回源路径 |
| 429 | 限流 | 限流阈值、配额 |
| 500 | 服务端异常 | 应用日志、异常堆栈 |
| 502 | Bad Gateway | 上游不可达、Nginx 与后端连接失败 |
| 503 | 服务不可用 | 过载、熔断、维护中 |
| 504 | 网关超时 | 上游处理超时、慢 SQL、线程阻塞 |

### HTTP 排查命令

```bash
curl -v https://example.com/path       # 完整交互，含 DNS/TLS/响应头
curl -I https://example.com/path       # 只看响应头（缓存、跳转）
curl -w 'dns:%{time_namelookup} tcp:%{time_connect} tls:%{time_appconnect} ttfb:%{time_starttransfer} total:%{time_total}\n' -o /dev/null -s https://example.com/path
```

`curl -w` 的分段时间能快速定位：DNS 慢、TCP 慢、TLS 慢、还是服务端响应慢。

## 4. DNS 要点与故障

### 解析流程

`本地缓存 → hosts → 递归解析器 → 根/顶级域 → 权威 DNS`。CDN 场景中权威 DNS 返回的是**调度结果**（就近的节点 IP 或 CNAME）。

### 常见故障

| 现象 | 可能原因 | 排查 |
| --- | --- | --- |
| 解析失败 | 域名过期、NS 配置错误、递归被劫持 | `dig +trace` |
| 解析慢 | 递归解析器距离远、超时未配置 | `dig` 看耗时、换 DNS |
| 解析到错误 IP | 缓存未刷新、TTL 过长、调度异常 | 对比多家公共 DNS 结果 |
| 局部地区解析异常 | 运营商 DNS 缓存、Local DNS 故障 | 从不同地区/网络测试 |

### 常用命令

```bash
dig example.com                        # 默认解析
dig @8.8.8.8 example.com               # 指定 DNS 服务器
dig example.com +trace                 # 完整递归链路
nslookup example.com                   # Windows/Linux 通用
cat /etc/resolv.conf                   # 本机 DNS 配置
```

## 5. 网络故障排查方法论

1. **从客户端开始，逐段排除**：DNS → 网络连通 → TCP/TLS → HTTP → 应用。
2. **用数据说话**：`curl -w` 分段计时、tcpdump 抓包、对比多个地域/网络。
3. **区分「整体故障」和「局部故障」**：所有用户挂 = 服务端/域名问题；部分地域挂 = DNS 调度/运营商问题。
4. **先恢复、后根因**：故障时优先摘流量、切备用、回滚，再深入分析。
5. **沉淀为 runbook**：每次网络故障按上述链路记录，形成可复用的排查 SOP。

