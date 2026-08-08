#!/usr/bin/env python3
"""main.py CLI 接口测试（覆盖与原 main.py 对齐的命令形式）。"""

from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from alb_switch import dump_yaml, load_config

BASE_CONFIG = {
    "app": {"name": "demo"},
    "alb": {
        "target_groups": [
            {"name": "green", "weight": 100},
            {"name": "blue", "weight": 0},
        ],
        "whitelist": {"enabled": True, "header": "did", "target_group": "green"},
    },
}


class MainCliTest(unittest.TestCase):
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

    def run_main(self, argv):
        from main import main

        with contextlib.redirect_stderr(io.StringIO()):
            return main(argv)

    def test_status(self):
        path = self.write_config(BASE_CONFIG)
        self.assertEqual(
            self.run_main(["--config", str(path), "alb", "status"]),
            0,
        )

    def test_set_weight_underscore_and_hyphen(self):
        for cmd in ("set_weight", "set-weight"):
            path = self.write_config(BASE_CONFIG)
            rc = self.run_main(["--config", str(path), "alb", cmd, "0", "100"])
            self.assertEqual(rc, 0)
            data = load_config(str(path))
            self.assertEqual(
                [g["weight"] for g in data["alb"]["target_groups"]],
                [0, 100],
            )

    def test_set_weight_dry_run_does_not_write(self):
        path = self.write_config(BASE_CONFIG)
        rc = self.run_main(
            ["--config", str(path), "alb", "set_weight", "--dry-run", "30", "70"]
        )
        self.assertEqual(rc, 0)
        data = load_config(str(path))
        self.assertEqual(
            [g["weight"] for g in data["alb"]["target_groups"]],
            [100, 0],
        )

    def test_enable_disable_whitelist(self):
        path = self.write_config(BASE_CONFIG)
        self.assertEqual(
            self.run_main(["--config", str(path), "alb", "enable-whitelist", "blue"]),
            0,
        )
        data = load_config(str(path))
        self.assertTrue(data["alb"]["whitelist"]["enabled"])
        self.assertEqual(data["alb"]["whitelist"]["target_group"], "blue")

        self.assertEqual(
            self.run_main(["--config", str(path), "alb", "disable-whitelist"]),
            0,
        )
        data = load_config(str(path))
        self.assertFalse(data["alb"]["whitelist"]["enabled"])
        self.assertEqual(data["alb"]["whitelist"]["target_group"], "blue")

    def test_error_returns_nonzero(self):
        path = self.write_config(BASE_CONFIG)
        rc = self.run_main(["--config", str(path), "alb", "enable-whitelist", "nope"])
        self.assertEqual(rc, 2)
        # 出错不写文件
        data = load_config(str(path))
        self.assertEqual(data["alb"]["whitelist"]["target_group"], "green")

    def test_top_level_status_and_check(self):
        path = self.write_config(BASE_CONFIG)
        self.assertEqual(self.run_main(["--config", str(path), "status"]), 0)
        self.assertEqual(self.run_main(["--config", str(path), "check"]), 0)


if __name__ == "__main__":
    unittest.main()
