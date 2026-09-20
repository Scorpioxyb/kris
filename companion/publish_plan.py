from __future__ import annotations

import argparse
import json
from pathlib import Path

from companion.config import CompanionConfig
from companion.contracts import ContractError, validate_training_plan
from companion.security import ensure_secret
from companion.store import CompanionStore


def main() -> int:
    parser = argparse.ArgumentParser(description="Publish one validated TrainingPlan.v1 to Kris")
    parser.add_argument("plan", type=Path)
    args = parser.parse_args()
    try:
        plan = validate_training_plan(json.loads(args.plan.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, ContractError) as exc:
        parser.error(str(exc))
    config = CompanionConfig()
    store = CompanionStore(config.database_path, ensure_secret(config))
    inserted, version = store.publish_plan(plan)
    print(json.dumps({"published": inserted, "version": version, "plan_id": plan["plan_id"], "revision": plan["revision"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
