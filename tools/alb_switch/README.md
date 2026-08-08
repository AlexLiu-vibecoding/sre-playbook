# AWS ALB 切流工具（alb_switch）

与原 `azcontroller` main.py 的 `alb` 命令组接口对齐的切流工具：修改本地配置中 ALB
目标组权重（`alb.target_groups`），以及 `did` header 白名单（命中后转发到指定目标组）。
工具只改配置、不直接调 AWS API，配置下发由发布/同步环节负责。

## 基本命令

```bash
# 禁用白名单（所有请求按权重分配）
python3 main.py --config /data/config.yml alb disable-whitelist

# 启用白名单，并切到指定机房的目标组（如 A 机房 green）
python3 main.py --config /data/config.yml alb enable-whitelist green

# 切流：green=0、blue=100（示例为全量切到 B 机房 blue）
python3 main.py --config /data/config.yml alb set_weight 0 100

# 查看当前权重和白名单情况
python3 main.py --config /data/config.yml alb status
```

兼容原脚本的 `set-weight` 连字符写法，以及 fire 风格的 `--alb_name` 参数：

```bash
python3 main.py --config /data/config.yml alb set-weight 0 100 --alb_name gateway
```

顶层还提供 `status`（打印原始配置）和 `check`（校验配置）：

```bash
python3 main.py --config /data/config.yml status
python3 main.py --config /data/config.yml check
```

## 配置说明

单 ALB 配置（`alb` 段）：

```yaml
alb:
  name: default          # 可选，缺省为 default
  target_groups:         # 顺序固定为 green / blue
    - name: green        # A 机房
      arn: <target group arn>
      alias: A机房       # 可选，仅用于 status 展示
      weight: 100
    - name: blue         # B 机房
      arn: <target group arn>
      alias: B机房
      weight: 0
  whitelist:
    enabled: true        # 白名单开关
    header: did          # 匹配的请求 header
    target_group: green  # 命中后转发的目标组
```

多 ALB 配置（`albs` map，键即 `--alb-name`，缺省选 `default` 或第一个）：

```yaml
albs:
  gateway:
    target_groups:
      - { name: green, weight: 100 }
      - { name: blue, weight: 0 }
    whitelist: { enabled: true, header: did, target_group: green }
  api:
    target_groups:
      - { name: green, weight: 50 }
      - { name: blue, weight: 50 }
    whitelist: { enabled: false, header: did, target_group: green }
```

完整示例见 [config.example.yml](config.example.yml)。

## 逻辑说明

- **切流**：`set_weight green blue` 固定按 green/blue 两个目标组写权重，参数必须为
  0-100 的整数且总和为 100（支持 30/70 灰度比例，全量切流用 `0 100`）。
- **白名单**：`enable-whitelist <zone>` 把 `whitelist.target_group` 改为指定目标组并开启
  白名单；`disable-whitelist` 只关开关、不改目标组，方便随时回切。`whitelist` 段缺失时
  默认 `enabled: false, header: did`。
- **status**：输出所选 ALB 的各目标组权重、白名单开关、匹配 header 与转发目标组。

## 安全与运维

- 所有写操作默认先备份原文件为 `config.yml.bak-<时间戳>`，再原子写入。
- 支持 `--dry-run` 预演：`alb set_weight --dry-run 0 100` 只打印变更不写文件。
- 校验严格：目标组不存在、权重越界或总和不为 100 时直接报错，不改文件。
- 与原脚本一致的 `--config` 必填；`--verbose` 输出调试日志。

> 注意：写入时会用 PyYAML 重新序列化整个文件，原文件注释不会保留。

## 与原 main.py 的差异

- 只实现 `alb` 命令组（ALB 切流/白名单）与顶层 `status`/`check`；`midd` 中间件
  切换命令组不在本次范围内。
- 原脚本用 python-fire 做 CLI，本工具用 argparse 实现相同的命令面（含
  `set-weight` 别名与 `--alb_name`），不引入 fire 依赖。
- `set_weight` 保持原语义：green/blue 两个权重 + 可选 `alb_name`。

## 运行与测试

```bash
pip install -r requirements.txt
python3 main.py --config config.example.yml alb status

# 单元测试
python3 -m unittest discover -s . -p "test_*.py" -v
```
