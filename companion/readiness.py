from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RULES = ROOT / "shared" / "rules" / "readiness.v1.json"


def clamp(value: float) -> float:
    return round(max(0.0, min(100.0, value)), 1)


@dataclass(frozen=True)
class ReadinessResult:
    score: float | None
    state: str
    label: str
    confidence: str
    safety_gate: str
    components: dict[str, float | None]

    def as_dict(self) -> dict[str, Any]:
        return {
            "score": self.score,
            "state": self.state,
            "label": self.label,
            "confidence": self.confidence,
            "safety_gate": self.safety_gate,
            "components": self.components,
        }


class ReadinessEngine:
    def __init__(self, rules: dict[str, Any]):
        if rules.get("schema_version") != "ReadinessRules.v1":
            raise ValueError("unsupported readiness rule version")
        self.rules = rules

    @classmethod
    def load(cls, path: Path = DEFAULT_RULES) -> "ReadinessEngine":
        return cls(json.loads(path.read_text(encoding="utf-8")))

    def evaluate(self, input_data: dict[str, Any]) -> ReadinessResult:
        neutral = float(self.rules["neutral_score"])
        scales = self.rules["component_scales"]
        components = {
            "sleep": self._component(input_data.get("sleep"), input_data.get("sleep_baseline"), scales["sleep"], neutral),
            "hrv": self._component(input_data.get("hrv"), input_data.get("hrv_baseline"), scales["hrv"], neutral),
            "rhr": self._component(input_data.get("rhr"), input_data.get("rhr_baseline"), scales["rhr"], neutral),
            "load": self._load(input_data.get("load_ratio")),
        }
        score = self._weighted(components)
        if score is None:
            state = "insufficient_data"
            label = "数据不足，暂不自动调整"
        else:
            threshold = next(item for item in self.rules["thresholds"] if score >= float(item["minimum"]))
            state = str(threshold["state"])
            label = str(threshold["label"])
            if input_data.get("today_status") == "partial" or input_data.get("data_quality") != "pass":
                label += "（临时）"
        return ReadinessResult(
            score=score,
            state=state,
            label=label,
            confidence=self._confidence(input_data),
            safety_gate=self._safety(input_data),
            components=components,
        )

    @staticmethod
    def _component(value: Any, baseline: Any, scale: float, neutral: float) -> float | None:
        if value is None:
            return None
        numeric = float(value)
        if not math.isfinite(numeric):
            return None
        if baseline is None:
            return neutral
        return clamp(neutral + (numeric - float(baseline)) * float(scale))

    def _load(self, ratio: Any) -> float | None:
        if ratio is None:
            return None
        ratio = float(ratio)
        config = self.rules["load"]
        if ratio > float(config["high_ratio"]):
            return clamp(float(config["high_start_score"]) - (ratio - float(config["high_ratio"])) * float(config["high_penalty"]))
        if ratio < float(config["low_ratio"]):
            return float(config["low_score"])
        return clamp(float(config["center_score"]) - abs(ratio - 1.0) * float(config["center_penalty"]))

    def _weighted(self, components: dict[str, float | None]) -> float | None:
        available = [
            (float(value), float(self.rules["weights"][name]))
            for name, value in components.items()
            if value is not None
        ]
        if not available:
            return None
        denominator = sum(weight for _, weight in available)
        return clamp(sum(value * weight for value, weight in available) / denominator)

    def _confidence(self, data: dict[str, Any]) -> str:
        config = self.rules["confidence"]
        minimum = int(config["minimum_history_count"])
        counts = data.get("history_counts") or {}
        complete = sum(int(counts.get(name, 0)) >= minimum for name in ("sleep", "hrv", "rhr"))
        baseline_days = int(data.get("baseline_days") or 0)
        fresh = bool(data.get("fresh"))
        if (
            data.get("today_status") == "final"
            and baseline_days >= int(config["high_baseline_days"])
            and complete >= int(config["high_complete_components"])
            and fresh
        ):
            return "high"
        if baseline_days >= int(config["medium_baseline_days"]) and complete >= int(config["medium_complete_components"]) and fresh:
            return "medium"
        return "low"

    def _safety(self, data: dict[str, Any]) -> str:
        config = self.rules["safety"]
        flags = set(data.get("flags") or [])
        if flags.intersection(config["emergency_flags"]):
            return "stop_and_seek_care"
        if float(data.get("pain") or 0) >= float(config["reduce_pain_at_or_above"]):
            return "reduce"
        return "normal"
