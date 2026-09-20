#!/usr/bin/env python3
"""Build a low-burden nutrition coverage layer for Kris.

The inventory is evidence of food availability, not proof of consumption or
nutrient sufficiency. The generated statuses therefore keep availability,
execution, and true deficiency separate.
"""

from __future__ import annotations

import csv
import json
import os
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


DATA = Path(
    os.environ.get(
        "KRIS_VAULT_DATA",
        Path.home() / "Documents" / "Obsidian Vault" / "Kris 健身数据",
    )
)
INVENTORY = DATA / "食材库存.csv"
COVERAGE_OUT = DATA / "营养目标与覆盖.csv"
DASHBOARD_OUT = DATA / "01-数据看板/营养看板.md"
SNAPSHOT = DATA / "coach_snapshot.json"
TZ = ZoneInfo("Asia/Shanghai")


TARGET_ROWS = [
    {
        "dimension": "energy",
        "target": "以7–14日体重、腰围、训练表现与恢复联合校准",
        "evidence_groups": (),
        "status_if_present": "requires_execution_data",
        "action": "不按单日手表消耗吃回，不因库存推断热量达标",
    },
    {
        "dimension": "protein_total",
        "target": "130–150g/日",
        "evidence_groups": ("poultry", "dairy", "whole_grain"),
        "status_if_present": "available_quantity_unknown",
        "action": "优先分到3–4次摄入，每次约30–45g；不再集中一顿大量鸡胸肉",
    },
    {
        "dimension": "protein_variety",
        "target": "禽肉、蛋、奶、豆、鱼等轮换",
        "evidence_groups": ("poultry", "dairy", "egg", "soy", "fish"),
        "status_if_present": "partially_available",
        "action": "低成本补鸡蛋和豆腐；每周安排鱼类，不长期只靠鸡胸肉和蛋白粉",
    },
    {
        "dimension": "carbohydrate_quality",
        "target": "训练前后保留主食；全谷物/杂豆50–150g/日",
        "evidence_groups": ("whole_grain",),
        "status_if_present": "available_quantity_unknown",
        "action": "燕麦可覆盖一部分全谷物；正餐仍需米饭、薯类或杂豆等主食",
    },
    {
        "dimension": "fat_total_quality",
        "target": "总脂肪约占全天能量20%–30%，饱和脂肪<10%；以不饱和脂肪为主",
        "evidence_groups": ("quality_fat", "nuts_seeds"),
        "status_if_present": "available_quantity_unknown",
        "action": "已有橄榄油可作为主要烹调油；仍需鱼类或少量坚果/种子补充脂肪来源多样性",
    },
    {
        "dimension": "omega3",
        "target": "每周至少2次鱼类，优先富脂鱼",
        "evidence_groups": ("fish",),
        "status_if_present": "weekly_source_available",
        "action": "低成本可选冷冻青花鱼/鲭鱼、沙丁鱼罐头；鸡胸肉不能替代Omega-3来源",
    },
    {
        "dimension": "fiber",
        "target": "约25–30g/日",
        "evidence_groups": ("vegetable", "fruit", "whole_grain", "soy", "legume"),
        "status_if_present": "partially_available_quantity_unknown",
        "action": "依靠蔬菜、燕麦、水果和豆类共同覆盖；仅有蔬菜名称不足以精算克数",
    },
    {
        "dimension": "vegetables",
        "target": "300–500g/日，深色蔬菜约占一半",
        "evidence_groups": ("vegetable",),
        "status_if_present": "available_variety_unknown",
        "action": "你无需逐个报菜名；日常只记总量是否约两大拳及是否有深色蔬菜",
    },
    {
        "dimension": "fruit",
        "target": "200–350g/日，整果优先并轮换种类",
        "evidence_groups": ("fruit",),
        "status_if_present": "available_low_variety",
        "action": "香蕉可作为一种水果和训练前后碳水，但下次补购一种当季水果",
    },
    {
        "dimension": "calcium_dairy",
        "target": "奶及奶制品折合液态奶300–500ml/日",
        "evidence_groups": ("dairy",),
        "status_if_present": "available_quantity_unknown",
        "action": "牛奶和酸奶可覆盖钙与B12；酸奶优先看蛋白质和添加糖标签",
    },
    {
        "dimension": "vitamin_d",
        "target": "食物、日照与必要时医学评估共同判断",
        "evidence_groups": ("fortified_dairy", "fish", "egg"),
        "status_if_present": "possible_source_available",
        "action": "普通奶是否强化维D未知；不凭库存判断缺乏，也不盲目补充大剂量维D",
    },
    {
        "dimension": "potassium_magnesium",
        "target": "通过蔬果、全谷、豆类和奶类稳定覆盖",
        "evidence_groups": ("vegetable", "fruit", "whole_grain", "soy", "dairy"),
        "status_if_present": "partially_available_quantity_unknown",
        "action": "现有香蕉、蔬菜、燕麦和奶类有帮助；豆类缺口仍需补齐",
    },
    {
        "dimension": "iron_zinc_b12",
        "target": "蛋、鱼、瘦肉、奶和豆类轮换覆盖",
        "evidence_groups": ("egg", "fish", "red_meat", "dairy", "soy"),
        "status_if_present": "partially_available",
        "action": "鸡胸肉不是铁锌优势来源；先用鸡蛋和豆腐提高多样性，红肉无需天天吃",
    },
    {
        "dimension": "folate_vitamin_c",
        "target": "通过深色蔬菜和不同颜色整果稳定覆盖",
        "evidence_groups": ("vegetable", "fruit"),
        "status_if_present": "partially_available_quantity_unknown",
        "action": "已有蔬菜和香蕉，但品种证据不足；下次增加一种富维C的当季水果或彩椒类蔬菜",
    },
    {
        "dimension": "iodine",
        "target": "日常使用合格碘盐，并通过鱼、蛋、奶等食物辅助覆盖",
        "evidence_groups": ("iodized_salt", "fish", "egg", "dairy"),
        "status_if_present": "possible_source_available",
        "action": "牛奶只能算辅助来源；是否使用碘盐未知，不据库存判断缺乏，也不建议自行服用高剂量碘补充剂",
    },
    {
        "dimension": "sodium_added_sugar",
        "target": "盐<5g/日，添加糖<25g/日更理想",
        "evidence_groups": (),
        "status_if_present": "requires_execution_data",
        "action": "重点识别酱料、外卖、加工肉和含糖酸奶/咖啡，不要求每天精算钠",
    },
    {
        "dimension": "hydration_gut",
        "target": "普通日饮水约2.0–2.5L，训练出汗另补；排便和胃肠耐受正常",
        "evidence_groups": (),
        "status_if_present": "requires_subjective_data",
        "action": "只在口渴、尿色深、便秘/腹泻或训练大量出汗时重点追踪",
    },
]


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def latest_active_inventory(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    if not rows:
        return []
    latest = max(row["snapshot_date"] for row in rows if row.get("snapshot_date"))
    return [
        row for row in rows
        if row.get("snapshot_date") == latest and row.get("status", "available") == "available"
    ]


def build_coverage(inventory: list[dict[str, str]], as_of: str) -> list[dict[str, str]]:
    groups = {row.get("food_group", "") for row in inventory}
    output: list[dict[str, str]] = []
    for definition in TARGET_ROWS:
        required = set(definition["evidence_groups"])
        present = sorted(required & groups)
        if not required:
            status = str(definition["status_if_present"])
        elif present:
            status = str(definition["status_if_present"])
        else:
            status = "gap_in_current_inventory"
        evidence = "、".join(
            row["item"] for row in inventory if row.get("food_group") in present
        ) or "当前库存无对应证据"
        output.append(
            {
                "as_of": as_of,
                "dimension": str(definition["dimension"]),
                "target": str(definition["target"]),
                "inventory_evidence": evidence,
                "coverage_status": status,
                "confidence": "medium" if present else "low",
                "next_action": str(definition["action"]),
                "interpretation_rule": "库存只代表可用，不代表已摄入；未记录不等于缺乏",
            }
        )
    return output


def write_csv(path: Path, rows: list[dict[str, str]]) -> None:
    fields = list(rows[0])
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def write_dashboard(inventory: list[dict[str, str]], coverage: list[dict[str, str]], as_of: str) -> None:
    labels = {
        "available_quantity_unknown": "有食材，数量待执行",
        "available_variety_unknown": "有食材，品种未知",
        "available_low_variety": "有食材，种类偏单一",
        "partially_available": "部分覆盖",
        "partially_available_quantity_unknown": "部分覆盖，数量未知",
        "weekly_source_available": "周频来源可用",
        "possible_source_available": "可能覆盖，标签待确认",
        "requires_execution_data": "需看实际摄入",
        "requires_subjective_data": "需按症状追踪",
        "gap_in_current_inventory": "当前库存缺口",
    }
    lines = [
        "---",
        'title: "营养看板"',
        "type: nutrition-coverage-dashboard",
        f"updated: {as_of}",
        "status: active",
        "---",
        "",
        "# 营养看板",
        "",
        "[[总览|← 返回总览]]　[[饮食看板|饮食执行记录]]",
        "",
        "> [!tldr]",
        "> 当前食材可以支持减脂保肌的基础餐，但不能证明全天营养达标。现阶段优先补鸡蛋、豆腐和低成本富脂鱼，并增加一种当季水果；不再只盯蛋白质和碳水。",
        "",
        "## 当前食材库存",
        "",
        "| 食材 | 食物组 | 数量状态 | 可提供的主要营养 |",
        "|---|---|---|---|",
    ]
    for row in inventory:
        lines.append(
            f"| {row['item']} | {row['food_group']} | {row['quantity_status']} | {row['nutrition_role']} |"
        )
    lines.extend([
        "",
        "> 蔬菜品种未知时只判断蔬菜份量覆盖，不虚构具体维生素和矿物质克数；库存不等于当天已吃。",
        "",
        "## 完整营养覆盖",
        "",
        "| 维度 | 个性化目标/口径 | 当前状态 | 库存证据 | 下一步 |",
        "|---|---|---|---|---|",
    ])
    for row in coverage:
        lines.append(
            f"| {row['dimension']} | {row['target']} | {labels.get(row['coverage_status'], row['coverage_status'])} | {row['inventory_evidence']} | {row['next_action']} |"
        )
    lines.extend([
        "",
        "## 最低记录负担",
        "",
        "日常只需告诉我主要食物和大概份量。我自动检查以下覆盖，不要求你逐项计算微量元素：",
        "",
        "- 每天：蛋白分布、蔬菜、水果、奶类/钙源、全谷物、脂肪质量、饮水与胃肠情况。",
        "- 每周：鱼类/Omega-3、蛋类、豆制品、食物种类和外卖高钠频率。",
        "- 触发式精查：体重腰围连续停滞、训练表现下降、明显饥饿、疲劳或胃肠异常时，才做3–7天饮食审计。",
        "",
        "## 当前低成本补购优先级",
        "",
        "1. 鸡蛋：蛋白质、胆碱、B12，并提高来源多样性。",
        "2. 豆腐/豆干：低成本蛋白、钙和镁来源。",
        "3. 冷冻青花鱼/鲭鱼或沙丁鱼罐头：每周2次，用于Omega-3。",
        "4. 一种当季水果：与香蕉轮换，不追求昂贵品种。",
        "5. 花生或少量坚果/种子：补不饱和脂肪；按小份使用，避免热量无意识累积。",
        "",
        "## 现有食材的一日使用框架",
        "",
        "- 早餐：燕麦50–60g＋牛奶250ml＋香蕉1根。",
        "- 正餐：鸡胸肉分两餐使用，每餐生重约150g；每餐蔬菜250g，并配正常主食。",
        "- 加餐：酸奶200–300g，优先低添加糖、高蛋白款。",
        "- 训练后：当天正餐蛋白来不及时再用蛋白粉；肌酸照常，不把补剂当作完整膳食。",
        "",
        "> [!warning]",
        "> 上述是一日组合框架，不表示库存中未列出的米饭、薯类、鸡蛋、豆腐和鱼类可以长期不吃。鸡胸肉也不建议再集中到一顿400g作为常规方案。",
        "",
    ])
    DASHBOARD_OUT.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    if not (DATA.parent / ".obsidian").is_dir():
        raise SystemExit(f"不是有效的Obsidian vault: {DATA.parent}")
    if not INVENTORY.is_file():
        raise SystemExit(f"缺少食材库存: {INVENTORY}")
    rows = read_csv(INVENTORY)
    inventory = latest_active_inventory(rows)
    if not inventory:
        raise SystemExit("食材库存没有可用记录")
    as_of = max(row["snapshot_date"] for row in inventory)
    coverage = build_coverage(inventory, as_of)
    write_csv(COVERAGE_OUT, coverage)
    write_dashboard(inventory, coverage, as_of)

    if SNAPSHOT.is_file():
        snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
        snapshot["nutrition"] = {
            "as_of": as_of,
            "framework_version": "food_group_coverage_v1",
            "inventory_items": [row["item"] for row in inventory],
            "coverage_states": {
                status: sum(row["coverage_status"] == status for row in coverage)
                for status in sorted({row["coverage_status"] for row in coverage})
            },
            "priority_gaps": [
                row["dimension"] for row in coverage
                if row["coverage_status"] == "gap_in_current_inventory"
            ],
            "data_rule": "inventory_is_availability_not_intake; missing_record_is_not_deficiency",
        }
        snapshot["generated_at"] = datetime.now(TZ).isoformat(timespec="seconds")
        SNAPSHOT.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"食材库存: {len(inventory)}项，日期={as_of}")
    print(f"营养覆盖: {len(coverage)}个维度")
    print(f"当前库存缺口: {', '.join(row['dimension'] for row in coverage if row['coverage_status'] == 'gap_in_current_inventory')}")
    print(f"营养看板: {DASHBOARD_OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
