#!/usr/bin/env python3
"""Refresh Kris coaching outputs after a quiet SyncHealth upload batch."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Optional
from zoneinfo import ZoneInfo


ROOT = Path(__file__).resolve().parents[1]
SYNC_HOME = Path(os.environ.get("SYNCHEALTH_HOME", Path.home() / ".synchealth"))
HEALTH_DB = Path(os.environ.get("SYNCHEALTH_DB", SYNC_HOME / "health.db"))
RAW = Path(os.environ.get("SYNCHEALTH_RAW", SYNC_HOME / "raw"))
STATE = SYNC_HOME / "kris-auto-refresh-state.json"
LOCK = SYNC_HOME / "kris-auto-refresh.lock"
DATA = Path(
    os.environ.get(
        "KRIS_VAULT_DATA",
        Path.home() / "Documents" / "Obsidian Vault" / "Kris 健身数据",
    )
)
BRIEF = DATA / "coach_brief.json"
REFRESH = ROOT / "tools/refresh_kris.py"
TZ = ZoneInfo("Asia/Shanghai")


def now_iso() -> str:
    return datetime.now(TZ).isoformat(timespec="seconds")


def load_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(value, ensure_ascii=False, indent=2) + "\n"
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def file_details(path: Path) -> Optional[dict[str, Any]]:
    try:
        info = path.stat()
    except FileNotFoundError:
        return None
    return {"size": info.st_size, "mtime_ns": info.st_mtime_ns}


def input_snapshot(database: Path, raw_dir: Path) -> dict[str, Any]:
    database_details = file_details(database)
    if database_details is None:
        raise FileNotFoundError(f"缺少 SyncHealth 数据库: {database}")

    raw_files = list(raw_dir.glob("*.json")) if raw_dir.is_dir() else []
    latest = max(raw_files, key=lambda item: (item.stat().st_mtime_ns, item.name), default=None)
    latest_details = file_details(latest) if latest else None
    return {
        "database": database_details,
        "raw": {
            "count": len(raw_files),
            "latest_name": latest.name if latest else None,
            "latest_size": latest_details["size"] if latest_details else None,
            "latest_mtime_ns": latest_details["mtime_ns"] if latest_details else None,
        },
    }


def snapshot_fingerprint(snapshot: dict[str, Any]) -> str:
    encoded = json.dumps(snapshot, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def newest_input_mtime_ns(snapshot: dict[str, Any]) -> int:
    database_mtime = int((snapshot.get("database") or {}).get("mtime_ns") or 0)
    raw_mtime = int((snapshot.get("raw") or {}).get("latest_mtime_ns") or 0)
    return max(database_mtime, raw_mtime)


def batch_is_quiet(snapshot: dict[str, Any], quiet_seconds: float, current_time: float) -> bool:
    latest = newest_input_mtime_ns(snapshot)
    return latest > 0 and current_time - latest / 1_000_000_000 >= quiet_seconds


def should_refresh(state: dict[str, Any], fingerprint: str, force: bool = False) -> bool:
    return force or state.get("last_successful_fingerprint") != fingerprint


def high_alerts(brief: dict[str, Any]) -> list[dict[str, Any]]:
    alerts = brief.get("alerts") or []
    return [item for item in alerts if isinstance(item, dict) and item.get("severity") == "high"]


def notification_for_brief(
    previous: dict[str, Any], brief: dict[str, Any]
) -> Optional[tuple[str, str]]:
    # Installation establishes the current baseline without resurfacing old issues.
    if not previous.get("last_successful_fingerprint"):
        return None

    current_readiness = str((brief.get("readiness") or {}).get("state") or "")
    previous_readiness = str(previous.get("readiness_state") or "")
    previous_alert_ids = set(previous.get("high_alert_ids") or [])
    current_high = high_alerts(brief)
    new_high = [item for item in current_high if item.get("id") not in previous_alert_ids]

    parts: list[str] = []
    if current_readiness and previous_readiness and current_readiness != previous_readiness:
        label = (brief.get("readiness") or {}).get("label") or current_readiness
        parts.append(f"准备度状态变为：{label}")
    if new_high:
        parts.append("；".join(str(item.get("title") or item.get("id")) for item in new_high))
    if not parts:
        return None
    title = "Kris 教练需要你处理" if new_high else "Kris 教练状态已更新"
    return title, "。".join(parts)[:240]


def notification_state(brief: dict[str, Any]) -> dict[str, Any]:
    readiness = brief.get("readiness") or {}
    return {
        "readiness_state": readiness.get("state"),
        "high_alert_ids": [item.get("id") for item in high_alerts(brief) if item.get("id")],
    }


def display_notification(title: str, body: str) -> bool:
    script = (
        "on run argv\n"
        "display notification (item 1 of argv) with title (item 2 of argv)\n"
        "end run"
    )
    result = subprocess.run(
        ["/usr/bin/osascript", "-e", script, body, title],
        capture_output=True,
        text=True,
        check=False,
        timeout=15,
    )
    if result.returncode:
        print(f"通知发送失败: {result.stderr.strip()}", file=sys.stderr)
        return False
    return True


def error_signature(returncode: int, output: str) -> str:
    value = f"{returncode}\n{output[-4000:]}".encode("utf-8", errors="replace")
    return hashlib.sha256(value).hexdigest()


def record_failure(
    args: argparse.Namespace,
    state: dict[str, Any],
    returncode: int,
    details: str,
    message: str,
) -> int:
    signature = error_signature(returncode, details)
    failed_at = now_iso()
    updated = dict(state)
    updated.update({
        "schema_version": "kris_auto_refresh.v1",
        "last_attempt_at": failed_at,
        "last_error_at": failed_at,
        "last_error_signature": signature,
        "last_error_code": returncode,
    })
    atomic_write_json(args.state, updated)
    if not args.no_notify and state.get("last_error_signature") != signature:
        display_notification("Kris 数据刷新失败", message)
    return returncode


def try_acquire_lock(path: Path) -> Optional[int]:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(descriptor)
        return None
    return descriptor


def refresh_once(args: argparse.Namespace) -> int:
    state = load_json(args.state)
    try:
        snapshot = input_snapshot(args.database, args.raw_dir)
    except OSError as error:
        print(str(error), file=sys.stderr)
        return record_failure(
            args,
            state,
            2,
            str(error),
            "没有找到 SyncHealth 健康数据库；自动刷新会继续重试。",
        )
    fingerprint = snapshot_fingerprint(snapshot)
    if not should_refresh(state, fingerprint, args.force):
        return 0
    if not args.force and not batch_is_quiet(snapshot, args.quiet_seconds, time.time()):
        return 0

    attempt_at = now_iso()
    try:
        result = subprocess.run(
            [sys.executable, str(args.refresh_script)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
            timeout=args.timeout,
        )
    except subprocess.TimeoutExpired as error:
        details = f"timeout={args.timeout}; stdout={error.stdout}; stderr={error.stderr}"
        print("Kris 自动刷新超时；下次轮询会重试。", file=sys.stderr)
        return record_failure(
            args,
            state,
            124,
            details,
            "教练派生数据刷新超时；原始健康数据未受影响，后台会自动重试。",
        )
    combined_output = "\n".join(value for value in (result.stdout, result.stderr) if value)
    if combined_output:
        print(combined_output.rstrip())
    if result.returncode:
        return record_failure(
            args,
            state,
            result.returncode,
            combined_output,
            "手机数据已收到，但教练派生数据刷新失败；原始健康数据未受影响。",
        )

    brief = load_json(args.brief)
    if not brief or not isinstance(brief.get("readiness"), dict):
        return record_failure(
            args,
            state,
            3,
            f"invalid brief: {args.brief}",
            "刷新流程没有生成有效的今日教练简报。",
        )

    notification = notification_for_brief(state, brief)
    updated = dict(state)
    updated.update({
        "schema_version": "kris_auto_refresh.v1",
        "last_attempt_at": attempt_at,
        "last_success_at": now_iso(),
        "last_successful_fingerprint": fingerprint,
        "last_input_snapshot": snapshot,
        "brief_generated_at": brief.get("generated_at"),
        "brief_as_of": brief.get("as_of"),
        "last_error_at": None,
        "last_error_signature": None,
        "last_error_code": None,
        **notification_state(brief),
    })
    atomic_write_json(args.state, updated)
    if notification and not args.no_notify:
        display_notification(*notification)
    print(f"自动刷新完成: {brief.get('as_of')} | {brief.get('generated_at')}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, default=HEALTH_DB)
    parser.add_argument("--raw-dir", type=Path, default=RAW)
    parser.add_argument("--state", type=Path, default=STATE)
    parser.add_argument("--lock", type=Path, default=LOCK)
    parser.add_argument("--brief", type=Path, default=BRIEF)
    parser.add_argument("--refresh-script", type=Path, default=REFRESH)
    parser.add_argument("--quiet-seconds", type=float, default=20.0)
    parser.add_argument("--timeout", type=float, default=900.0)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--no-notify", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    descriptor = try_acquire_lock(args.lock)
    if descriptor is None:
        return 0
    try:
        return refresh_once(args)
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


if __name__ == "__main__":
    raise SystemExit(main())
