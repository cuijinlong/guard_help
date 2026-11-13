#!/usr/bin/env python3
"""把看板模板 JSON 里的「写死实体占位符」改成 assetType 动态解析。

背景
    看板模板（`data/json/tenant/dashboards/*.json`）里，实体引用写的是
    `00000000-0000-0000-0000-00000000xxxx` 这种哨兵 id，开户时由
    `EnergyBootstrapInstaller#buildDashboardPlaceholders` 替换成客户实际资产。

    这套机制的前提是「每个客户一份看板副本」—— 现在改成「租户级一份共享」，
    占位符就没有替换的时机了，而且租户级看板里留着占位符时查询恒空。

    改用 TB 原生的 `assetType` 过滤器：运行时按**当前用户的权限**解析，
    客户 A 只拿到客户 A 的场站。已实测：
        · 客户身份 assetType=场站  → 只返回自己那 3 个
        · 客户身份读别人场站遥测    → 返回 {}
        · 客户身份读别人资产        → 403

映射表（与 43-merge-energy-dashboards.py 的 ALIAS_RULES 必须一致）
    05a1 场站占位          → assetType ["场站"]
    05a2 组织占位          → assetType ["组织"]
    17e0 用电分项占位       → assetType ["energy_item_library"]
    d101~d104 维度根       → assetType 四个 library
    e1ec 电能品种          → assetType ["default"] + assetNameFilter "电能"
    d102 分析范围（用能区域）→ assetType ["energy_area_library"]
    11b7 能源参数字典       → **保持占位**（客户无权读租户级字典，换成真实 id 会 403）

用法
    python3 45-align-dashboard-templates.py --audit     # 只列出会改什么
    python3 45-align-dashboard-templates.py --apply     # 改写模板文件
"""

import argparse
import glob
import json
import os
import sys

TEMPLATES_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "..", "..", "guard-server", "src", "main", "data", "json", "tenant", "dashboards",
)

P = "00000000-0000-0000-0000-00000000"

# 占位符 id 尾号 → 替换用的 filter
BY_ID = {
    P + "05a1": {"type": "assetType", "assetTypes": ["场站"]},
    P + "05a2": {"type": "assetType", "assetTypes": ["组织"]},
    P + "17e0": {"type": "assetType", "assetTypes": ["energy_item_library"]},
    P + "e1ec": {"type": "assetType", "assetTypes": ["default"], "assetNameFilter": "电能"},
}

# 「按分组维度」的 entityList：四个 library 一起查
DIM_ROOTS = [P + "d101", P + "d102", P + "d103", P + "d104"]
DIM_FILTER = {
    "type": "assetType",
    "assetTypes": ["energy_item_library", "energy_area_library",
                   "energy_usage_library", "energy_space_library"],
}

# 故意不动：客户读租户级资产会 403（详见 EnergyBootstrapInstaller 的长注释）
KEEP = {P + "11b7"}


def resolve(filter_obj):
    """返回替换后的 filter；返回 None 表示不改。"""
    if not isinstance(filter_obj, dict):
        return None
    t = filter_obj.get("type")

    if t == "singleEntity":
        eid = (filter_obj.get("singleEntity") or {}).get("id")
        if eid in KEEP or eid is None:
            return None
        return BY_ID.get(eid)

    if t == "entityList":
        ids = filter_obj.get("entityList") or []
        if ids and all(i in DIM_ROOTS for i in ids if isinstance(i, str)):
            return DIM_FILTER

    return None


def process_file(path):
    d = json.load(open(path, encoding="utf-8"))
    cfg = d.get("configuration") or {}
    aliases = cfg.get("entityAliases") or {}
    changes = []
    for k, v in aliases.items():
        new = resolve(v.get("filter"))
        if new is None:
            continue
        changes.append((v.get("alias"), v.get("filter"), new))
    return d, changes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audit", action="store_true")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()
    if not (args.audit or args.apply):
        ap.print_help()
        return

    paths = sorted(glob.glob(os.path.join(TEMPLATES_DIR, "*.json")))
    if not paths:
        sys.exit(f"模板目录为空或不存在：{TEMPLATES_DIR}")

    total_files = total_changes = 0
    for path in paths:
        d, changes = process_file(path)
        if not changes:
            continue
        total_files += 1
        total_changes += len(changes)
        print(f"· {os.path.basename(path):28s} {d.get('title')}  改 {len(changes)} 处")
        for name, old, new in changes:
            if args.audit:
                print(f"      {name:22s} {json.dumps(old, ensure_ascii=False)[:70]}")
                print(f"      {'':22s} → {json.dumps(new, ensure_ascii=False)[:70]}")
        if args.apply:
            for k, v in (d["configuration"].get("entityAliases") or {}).items():
                new = resolve(v.get("filter"))
                if new is not None:
                    v["filter"] = new
            with open(path, "w", encoding="utf-8") as f:
                json.dump(d, f, ensure_ascii=False, indent=2)
                f.write("\n")

    verb = "已改写" if args.apply else "将改写"
    print(f"\n{verb} {total_files} 个模板 / {total_changes} 处别名")
    if args.audit:
        print("（--apply 执行改写）")


if __name__ == "__main__":
    main()
