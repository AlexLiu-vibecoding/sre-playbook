#!/usr/bin/env python3
"""AWS ALB 切流工具入口。

与原 azcontroller main.py 对齐的用法示例:
  python3 main.py --config /data/config.yml alb status
  python3 main.py --config /data/config.yml alb disable-whitelist
  python3 main.py --config /data/config.yml alb enable-whitelist green
  python3 main.py --config /data/config.yml alb set_weight 0 100
  python3 main.py --config /data/config.yml alb set-weight 0 100 --alb-name gateway

逻辑说明:
  - set_weight: 按 green/blue 两个目标组设置权重（总和须为 100）
  - enable-whitelist: 启用白名单，命中 did header 的请求转发到指定目标组
  - disable-whitelist: 禁用白名单，请求全部按权重分配
  - status: 查看当前权重与白名单状态（--alb-name 选择 ALB 实例）
  - 顶层 status/check: 打印原始配置 / 校验配置
"""

from __future__ import annotations

import argparse
import logging
import sys

from alb_switch import (
    ConfigError,
    disable_whitelist,
    dump_yaml,
    enable_whitelist,
    get_alb,
    load_config,
    render_status,
    save_config,
    set_weights,
)


def add_alb_name(parser: argparse.ArgumentParser) -> None:
    # 兼容 fire 风格的 --alb_name 与常规 --alb-name
    parser.add_argument(
        "--alb-name",
        "--alb_name",
        dest="alb_name",
        help="ALB 实例名（多 ALB 配置时使用）",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="main.py",
        description="AWS ALB 切流工具（修改本地配置，不直接调用 AWS API）",
    )
    parser.add_argument("--config", required=True, help="配置文件路径（YAML，含 alb 段）")
    parser.add_argument("-v", "--verbose", action="store_true", help="输出调试日志")

    sub = parser.add_subparsers(dest="command", required=True, metavar="{alb,status,check}")

    status = sub.add_parser("status", help="打印原始配置文件")
    status.add_argument("--alb-name", "--alb_name", dest="alb_name", help=argparse.SUPPRESS)

    sub.add_parser("check", help="校验 alb 配置是否正确")

    alb = sub.add_parser("alb", help="AWS ALB 切流/白名单管理")
    alb_sub = alb.add_subparsers(
        dest="alb_command",
        required=True,
        metavar="{status,disable-whitelist,enable-whitelist,set_weight}",
    )

    alb_status = alb_sub.add_parser("status", help="查看当前权重和白名单状态")
    add_alb_name(alb_status)

    disable = alb_sub.add_parser("disable-whitelist", help="禁用白名单")
    add_alb_name(disable)
    disable.add_argument("--dry-run", action="store_true", help="仅打印变更，不写文件")

    enable = alb_sub.add_parser("enable-whitelist", help="启用白名单并指定命中目标组")
    enable.add_argument("target_zone", help="目标组名称（机房标识，如 green/blue）")
    add_alb_name(enable)
    enable.add_argument("--dry-run", action="store_true", help="仅打印变更，不写文件")

    set_weight = alb_sub.add_parser(
        "set_weight",
        aliases=["set-weight"],
        help="设置 green/blue 目标组权重（总和须为 100）",
    )
    set_weight.add_argument("green_weight", type=int, help="green（A 机房）权重，如 0")
    set_weight.add_argument("blue_weight", type=int, help="blue（B 机房）权重，如 100")
    add_alb_name(set_weight)
    set_weight.add_argument("--dry-run", action="store_true", help="仅打印变更，不写文件")
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    try:
        data = load_config(args.config)
    except ConfigError as exc:
        logging.error("%s", exc)
        return 2

    if args.command == "status":
        print(dump_yaml(data).rstrip())
        return 0
    if args.command == "check":
        print("配置校验通过: alb/albs 段正常")
        return 0

    if args.alb_command == "status":
        print(render_status(data, args.alb_name))
        return 0

    try:
        if args.alb_command == "disable-whitelist":
            new_data = disable_whitelist(data, args.alb_name)
        elif args.alb_command == "enable-whitelist":
            new_data = enable_whitelist(data, args.target_zone, args.alb_name)
        elif args.alb_command in ("set_weight", "set-weight"):
            new_data = set_weights(data, args.green_weight, args.blue_weight, args.alb_name)
        else:
            raise ConfigError(f"未知命令: {args.alb_command}")
    except ConfigError as exc:
        logging.error("%s", exc)
        return 2

    if getattr(args, "dry_run", False):
        selected, name = get_alb(new_data, args.alb_name)
        print(f"DRY-RUN: 不写文件，{name} 变更后的 alb 段如下:")
        print(dump_yaml(selected).rstrip())
        return 0

    save_config(args.config, new_data)
    print()
    print(render_status(new_data, args.alb_name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
