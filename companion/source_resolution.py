from __future__ import annotations

from collections import defaultdict
from typing import Any, Iterable


def resolve_daily_metrics(
    iphone_rows: Iterable[dict[str, Any]],
    synchealth_rows: Iterable[dict[str, Any]],
    coverage: Iterable[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Resolve one source per date/metric without ever summing the two sources.

    iPhone HealthKit wins only for a date/metric explicitly marked complete.
    Any other coverage status falls back to SyncHealth. Duplicate sample UUIDs
    are removed before per-source aggregation.
    """
    complete = {(row["date"], row["metric"]) for row in coverage if row.get("status") == "complete"}
    grouped: dict[tuple[str, str, str], list[dict[str, Any]]] = defaultdict(list)
    seen: set[tuple[str, str]] = set()
    for source, rows in (("iphone_healthkit", iphone_rows), ("synchealth", synchealth_rows)):
        for row in rows:
            uuid = str(row.get("sample_uuid") or "")
            dedupe_key = (source, uuid)
            if uuid and dedupe_key in seen:
                continue
            if uuid:
                seen.add(dedupe_key)
            grouped[(str(row["date"]), str(row["metric"]), source)].append(row)

    keys = {(date, metric) for date, metric, _ in grouped}
    result: list[dict[str, Any]] = []
    for date, metric in sorted(keys):
        source = "iphone_healthkit" if (date, metric) in complete else "synchealth"
        rows = grouped.get((date, metric, source), [])
        if not rows and source == "synchealth":
            continue
        result.append({"date": date, "metric": metric, "source": source, "samples": rows})
    return result
