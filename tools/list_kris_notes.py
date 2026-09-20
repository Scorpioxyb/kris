#!/usr/bin/env python3
"""Bounded, read-only Apple Notes probe for the Kris folder."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


SCRIPT = Path(__file__).with_name("list_kris_notes.applescript")


def main() -> int:
    try:
        result = subprocess.run(
            ["osascript", str(SCRIPT)],
            capture_output=True,
            text=True,
            timeout=8,
            check=False,
        )
    except subprocess.TimeoutExpired:
        print("NOTES_AUTOMATION_TIMEOUT: Notes AppleScript 8 秒内未返回；未写入或移动任何备忘录。")
        return 2

    if result.returncode != 0:
        print(f"NOTES_AUTOMATION_ERROR: {result.stderr.strip() or result.returncode}")
        return result.returncode or 1
    output = result.stdout.strip()
    if output:
        print(output)
    else:
        print("NOTES_FOLDER_EMPTY_OR_UNAVAILABLE: 未读到 Kris 健身 文件夹内容。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
