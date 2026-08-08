#!/usr/bin/env python3
"""AWS ALB 切流核心逻辑。

与原 azcontroller main.py 的 alb 命令组对齐：
- set_weight <green_weight> <blue_weight>：修改选中 ALB 两个目标组的权重
- enable-whitelist <target_zone>：启用白名单，命中 did header 的请求转发到指定目标组
- disable-whitelist：禁用白名单
- status：查看当前权重与白名单状态

支持两种配置形态：
- 单实例：alb 段
- 多实例：albs 段（map，键为 alb_name）

工具本身不直接调用 AWS API；配置修改后可交给发布/同步环节下发到 AWS。
"""

from __future__ import annotations

import copy
import logging
import os
import shutil
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Tuple

import yaml

logger = logging.getLogger("alb_switch")


class ConfigError(Exception):
    """配置或参数错误。"""


def load_config(path: str) -> Dict[str, Any]:
    """读取并校验配置文件，返回规范化后的数据（含 whitelist 默认值）。"""
    cfg_path = Path(path)
    if not cfg_path.is_file():
        raise ConfigError(f"配置文件不存在: {cfg_path}")
    try:
        with cfg_path.open("r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        raise ConfigError(f"配置文件 YAML 解析失败: {exc}") from exc

    if not isinstance(data, dict):
        raise ConfigError("配置文件顶层必须是 map")

    validate_config(data)
    normalize_config(data)
    return data


def validate_config(data: Dict[str, Any]) -> None:
    """校验 alb / albs 段结构，发现错误直接抛 ConfigError。"""
    if "albs" in data:
        albs = data["albs"]
        if not isinstance(albs, dict) or not albs:
            raise ConfigError("albs 必须是包含至少一个 ALB 的 map")
        for name, alb in albs.items():
            validate_alb(alb, f"albs.{name}")
        return

    validate_alb(data.get("alb"), "alb")


def validate_alb(alb: Any, prefix: str) -> None:
    if not isinstance(alb, dict):
        raise ConfigError(f"{prefix} 必须是 map")

    groups = alb.get("target_groups")
    if not isinstance(groups, list) or not groups:
        raise ConfigError(f"{prefix}.target_groups 必须是包含至少一个目标组的列表")

    names: set = set()
    for idx, group in enumerate(groups):
        if not isinstance(group, dict):
            raise ConfigError(f"{prefix}.target_groups[{idx}] 必须是 map")
        name = group.get("name")
        if not isinstance(name, str) or not name.strip():
            raise ConfigError(f"{prefix}.target_groups[{idx}] 缺少 name")
        if name in names:
            raise ConfigError(f"目标组 name 重复: {name}")
        names.add(name)

        weight = group.get("weight", 0)
        if isinstance(weight, bool) or not isinstance(weight, int) or not (0 <= weight <= 100):
            raise ConfigError(f"目标组 {name} 的 weight 必须是 0-100 的整数")

    whitelist = alb.get("whitelist")
    if whitelist is None:
        return  # 允许缺失，normalize_config 会补默认值
    if not isinstance(whitelist, dict):
        raise ConfigError(f"{prefix}.whitelist 必须是 map")
    if whitelist.get("enabled") is not None and not isinstance(whitelist["enabled"], bool):
        raise ConfigError(f"{prefix}.whitelist.enabled 必须是布尔值")
    header = whitelist.get("header")
    if header is not None and (not isinstance(header, str) or not header.strip()):
        raise ConfigError(f"{prefix}.whitelist.header 必须是非空字符串")
    target_group = whitelist.get("target_group")
    if target_group is not None and (not isinstance(target_group, str) or not target_group.strip()):
        raise ConfigError(f"{prefix}.whitelist.target_group 必须是非空字符串")
    if target_group is not None and target_group not in names:
        raise ConfigError(
            f"{prefix}.whitelist.target_group 引用了不存在的目标组: {target_group}"
        )


def normalize_config(data: Dict[str, Any]) -> None:
    """为缺失的 whitelist 字段补默认值，保证后续命令可安全执行。"""
    if "albs" in data:
        for alb in data["albs"].values():
            normalize_alb(alb)
    else:
        normalize_alb(data["alb"])


def normalize_alb(alb: Dict[str, Any]) -> None:
    first_group = alb["target_groups"][0]["name"]
    whitelist = alb.setdefault(
        "whitelist",
        {"enabled": False, "header": "did", "target_group": first_group},
    )
    whitelist.setdefault("enabled", False)
    whitelist.setdefault("header", "did")
    whitelist.setdefault("target_group", first_group)


def get_alb(data: Dict[str, Any], alb_name: str | None = None) -> Tuple[Dict[str, Any], str]:
    """按 alb_name 选中 alb 段，返回 (alb 配置, 名称)。

    多实例配置（albs map）按名称选择，缺省选 default 或第一个；
    单实例配置（alb 段）名称取 alb.name，缺省为 default。
    """
    albs = data.get("albs")
    if isinstance(albs, dict) and albs:
        if alb_name is None:
            selected = "default" if "default" in albs else next(iter(albs))
        elif alb_name not in albs:
            raise ConfigError(
                f"albs 中不存在 alb_name: {alb_name}，可选: {', '.join(sorted(albs))}"
            )
        else:
            selected = alb_name
        return albs[selected], selected

    alb = data.get("alb")
    if not isinstance(alb, dict):
        raise ConfigError("配置缺少 alb 段或 albs 段")
    name = alb.get("name", "default")
    if alb_name is not None and alb_name != name:
        raise ConfigError(f"alb_name 不匹配: {alb_name} != {name}（单 ALB 配置的 name）")
    return alb, name


def target_groups(data: Dict[str, Any], alb_name: str | None = None) -> List[Dict[str, Any]]:
    return get_alb(data, alb_name)[0]["target_groups"]


def target_group_names(data: Dict[str, Any], alb_name: str | None = None) -> List[str]:
    return [group["name"] for group in target_groups(data, alb_name)]


def set_weights(
    data: Dict[str, Any],
    green_weight: int,
    blue_weight: int,
    alb_name: str | None = None,
) -> Dict[str, Any]:
    """设置选中 ALB 的 green/blue 目标组权重（示例：0 100 = 全量切到 blue）。"""
    groups = target_groups(data, alb_name)
    if len(groups) != 2:
        raise ConfigError(
            f"set_weight 按 green/blue 双目标组设计，当前目标组个数为 {len(groups)}"
        )

    for label, weight in (("green", green_weight), ("blue", blue_weight)):
        if isinstance(weight, bool) or not isinstance(weight, int) or not (0 <= weight <= 100):
            raise ConfigError(f"{label} 权重必须是 0-100 的整数")
    if green_weight + blue_weight != 100:
        raise ConfigError(f"权重之和必须为 100，当前为 {green_weight + blue_weight}")

    result = copy.deepcopy(data)
    selected, _ = get_alb(result, alb_name)
    for group, weight in zip(selected["target_groups"], (green_weight, blue_weight)):
        group["weight"] = weight
    return result


def enable_whitelist(
    data: Dict[str, Any],
    target_zone: str,
    alb_name: str | None = None,
) -> Dict[str, Any]:
    """启用白名单，并把命中 did header 的请求转发到指定目标组（机房）。"""
    names = target_group_names(data, alb_name)
    if target_zone not in names:
        raise ConfigError(f"未知目标组: {target_zone}，可选: {', '.join(names)}")

    result = copy.deepcopy(data)
    selected, _ = get_alb(result, alb_name)
    whitelist = selected["whitelist"]
    whitelist["enabled"] = True
    whitelist["target_group"] = target_zone
    return result


def disable_whitelist(data: Dict[str, Any], alb_name: str | None = None) -> Dict[str, Any]:
    """禁用白名单，所有请求走目标组权重分配（保留目标组便于回切）。"""
    result = copy.deepcopy(data)
    selected, _ = get_alb(result, alb_name)
    selected["whitelist"]["enabled"] = False
    return result


def render_status(data: Dict[str, Any], alb_name: str | None = None) -> str:
    """输出当前权重与白名单状态。"""
    alb, name = get_alb(data, alb_name)
    lines = [f"ALB 切流状态: {name}"]
    lines.append("  目标组:")
    for group in alb["target_groups"]:
        alias = group.get("alias")
        suffix = f" ({alias})" if alias else ""
        lines.append(f"    - {group['name']:<12} weight={group['weight']}{suffix}")

    whitelist = alb["whitelist"]
    state = "已启用" if whitelist["enabled"] else "已禁用"
    lines.append(f"  白名单: {state}")
    lines.append(f"    header: {whitelist['header']}")
    lines.append(f"    target_group: {whitelist['target_group']}")
    return "\n".join(lines)


def dump_yaml(data: Dict[str, Any]) -> str:
    """把字典转成 YAML 文本（保留键顺序、支持中文）。"""
    return yaml.safe_dump(
        data,
        allow_unicode=True,
        sort_keys=False,
        default_flow_style=False,
    )


def save_config(path: str, data: Dict[str, Any], backup: bool = True) -> Path:
    """原子写入配置；默认先备份原文件（.bak-时间戳.微秒）。"""
    cfg_path = Path(path)
    cfg_path.parent.mkdir(parents=True, exist_ok=True)

    backup_path = None
    if backup and cfg_path.exists():
        stamp = f"{time.strftime('%Y%m%d-%H%M%S')}.{time.time_ns() % 1_000_000:06d}"
        backup_path = cfg_path.with_name(f"{cfg_path.name}.bak-{stamp}")
        shutil.copy2(cfg_path, backup_path)
        logger.info("已备份原配置到 %s", backup_path)

    fd, tmp_name = tempfile.mkstemp(
        prefix=f"{cfg_path.name}.",
        suffix=".tmp",
        dir=str(cfg_path.parent),
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(dump_yaml(data))
        os.replace(tmp_name, cfg_path)
    except Exception:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)
        raise

    logger.info("已更新配置: %s", cfg_path)
    return backup_path
