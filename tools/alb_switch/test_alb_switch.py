#!/usr/bin/env python3
"""alb_switch 核心逻辑单元测试。"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from alb_switch import (
    ConfigError,
    disable_whitelist,
    dump_yaml,
    enable_whitelist,
    load_config,
    render_status,
    save_config,
    set_weights,
)


BASE_CONFIG = {
    "app": {"name": "demo"},
    "alb": {
        "name": "default",
        "target_groups": [
            {"name": "green", "arn": "arn:aws:tg/green", "weight": 100},
            {"name": "blue", "arn": "arn:aws:tg/blue", "weight": 0},
        ],
        "whitelist": {"enabled": True, "header": "did", "target_group": "green"},
    },
}

MULTI_CONFIG = {
    "albs": {
        "gateway": {
            "target_groups": [
                {"name": "green", "weight": 100},
                {"name": "blue", "weight": 0},
            ],
            "whitelist": {"enabled": True, "header": "did", "target_group": "green"},
        },
        "api": {
            "target_groups": [
                {"name": "green", "weight": 50},
                {"name": "blue", "weight": 50},
            ],
            "whitelist": {"enabled": False, "header": "did", "target_group": "green"},
        },
    }
}


class AlbSwitchTest(unittest.TestCase):
    def write_config(self, data: dict) -> Path:
        tmp = tempfile.NamedTemporaryFile(
            mode="w",
            suffix=".yml",
            encoding="utf-8",
            delete=False,
        )
        tmp.write(dump_yaml(data))
        tmp.close()
        self.addCleanup(lambda: Path(tmp.name).unlink(missing_ok=True))
        return Path(tmp.name)

    def test_load_and_status(self):
        path = self.write_config(BASE_CONFIG)
        data = load_config(str(path))
        status = render_status(data)
        self.assertIn("green", status)
        self.assertIn("blue", status)
        self.assertIn("已启用", status)
        self.assertIn("did", status)

    def test_set_weights_full_switch(self):
        new = set_weights(BASE_CONFIG, 0, 100)
        weights = [g["weight"] for g in new["alb"]["target_groups"]]
        self.assertEqual(weights, [0, 100])
        # 原数据不被修改（返回深拷贝）
        self.assertEqual(BASE_CONFIG["alb"]["target_groups"][0]["weight"], 100)

    def test_set_weights_partial(self):
        new = set_weights(BASE_CONFIG, 30, 70)
        weights = [g["weight"] for g in new["alb"]["target_groups"]]
        self.assertEqual(weights, [30, 70])

    def test_set_weights_rejects_bad_input(self):
        with self.assertRaises(ConfigError):
            set_weights(BASE_CONFIG, 0, 99)  # 总和不为 100
        with self.assertRaises(ConfigError):
            set_weights(BASE_CONFIG, -1, 101)  # 越界
        with self.assertRaises(ConfigError):
            set_weights(BASE_CONFIG, "0", "100")  # 非整数
        with self.assertRaises(ConfigError):
            set_weights(BASE_CONFIG, 1, 2, "unknown-alb")  # 未知 alb_name

    def test_enable_whitelist_switches_target(self):
        new = enable_whitelist(BASE_CONFIG, "blue")
        whitelist = new["alb"]["whitelist"]
        self.assertTrue(whitelist["enabled"])
        self.assertEqual(whitelist["target_group"], "blue")

    def test_enable_whitelist_unknown_zone(self):
        with self.assertRaises(ConfigError):
            enable_whitelist(BASE_CONFIG, "unknown")

    def test_disable_whitelist_keeps_target(self):
        new = disable_whitelist(BASE_CONFIG)
        whitelist = new["alb"]["whitelist"]
        self.assertFalse(whitelist["enabled"])
        self.assertEqual(whitelist["target_group"], "green")

    def test_save_roundtrip_and_backup(self):
        path = self.write_config(BASE_CONFIG)
        new = set_weights(BASE_CONFIG, 0, 100)
        save_config(str(path), new)

        reloaded = load_config(str(path))
        weights = [g["weight"] for g in reloaded["alb"]["target_groups"]]
        self.assertEqual(weights, [0, 100])

        backups = list(path.parent.glob(f"{path.name}.bak-*"))
        self.assertEqual(len(backups), 1)
        backup_data = load_config(str(backups[0]))
        self.assertEqual(
            [g["weight"] for g in backup_data["alb"]["target_groups"]],
            [100, 0],
        )
        for bak in backups:
            bak.unlink(missing_ok=True)

    def test_missing_whitelist_gets_defaults(self):
        config = {
            "alb": {
                "target_groups": [
                    {"name": "green", "weight": 100},
                    {"name": "blue", "weight": 0},
                ]
            }
        }
        path = self.write_config(config)
        data = load_config(str(path))
        whitelist = data["alb"]["whitelist"]
        self.assertFalse(whitelist["enabled"])
        self.assertEqual(whitelist["header"], "did")
        self.assertEqual(whitelist["target_group"], "green")

    def test_multi_alb_selection(self):
        path = self.write_config(MULTI_CONFIG)
        data = load_config(str(path))

        # 默认选中 default；不存在时选第一个
        self.assertEqual(render_status(data).splitlines()[0], "ALB 切流状态: gateway")
        self.assertIn(
            "ALB 切流状态: api",
            render_status(data, "api"),
        )

        new = set_weights(data, 0, 100, "api")
        self.assertEqual(
            [g["weight"] for g in new["albs"]["api"]["target_groups"]],
            [0, 100],
        )
        # 未指定的 gateway 不受影响
        self.assertEqual(
            [g["weight"] for g in new["albs"]["gateway"]["target_groups"]],
            [100, 0],
        )

        with self.assertRaises(ConfigError):
            set_weights(data, 0, 100, "nope")

    def test_invalid_configs_rejected(self):
        with self.assertRaises(ConfigError):
            load_config("not-exist.yml")

        bad_weight = {
            "alb": {"target_groups": [{"name": "green", "weight": 101}]}
        }
        path = self.write_config(bad_weight)
        with self.assertRaises(ConfigError):
            load_config(str(path))

        bad_ref = {
            "alb": {
                "target_groups": [{"name": "green", "weight": 100}],
                "whitelist": {"enabled": True, "header": "did", "target_group": "nope"},
            }
        }
        path = self.write_config(bad_ref)
        with self.assertRaises(ConfigError):
            load_config(str(path))

        bad_albs = {"albs": {"gateway": "not-a-map"}}
        path = self.write_config(bad_albs)
        with self.assertRaises(ConfigError):
            load_config(str(path))


if __name__ == "__main__":
    unittest.main()
