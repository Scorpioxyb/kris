#!/usr/bin/env python3
"""Refresh all derived Kris coaching data after a SyncHealth sync."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STEPS = [
    "build_daily_health_summary.py",
    "build_training_intelligence.py",
    "build_nutrition_intelligence.py",
    "build_coaching_monitor.py",
    "build_decision_support.py",
    "build_coach_brief.py",
    "verify_kris_data.py",
    "verify_synchealth.py",
]


def main() -> int:
    for script in STEPS:
        path = ROOT / "tools" / script
        print(f"\n== {script} ==")
        result = subprocess.run([sys.executable, str(path)], cwd=ROOT, check=False)
        if result.returncode:
            print(f"停止：{script} 返回 {result.returncode}", file=sys.stderr)
            return result.returncode
    print("\nKris 数据刷新与校验完成。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
