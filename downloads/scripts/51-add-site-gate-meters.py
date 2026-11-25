#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
给缺关口表的场站补一台「1#进线总表」，并补齐额定容量（2026-11-25 客户定案）。

<h2>为什么需要</h2>

「能源概览 → 功率因数与负荷需量」只统计 `meterLevel=1`（进线总表）——
力率考核对象就是进线总表，回路表混进来会把加权值拉偏。
实测当时客户名下 3 个场站里**只有生产园区有 2 台 level=1**：

```
办公园区    0 台   ← 默认场站，部件必然全空（指针指 0、需量 —）
质量示范站  0 台
生产园区    2 台
```

于是客户一登录就报「功率因数与负荷需量为 0」。根因不是部件算错，
是**档案里就没有那台表**。

<h2>它做三件事（都幂等）</h2>

1. 给 `PLAN` 里的场站建「1#进线总表」（档案 + 属性 + 归属客户 + 场站关系）；
2. 把该场站原有电表挂到这台总表下（`Contains`），保证「父表 >= Σ 子表」，
   否则资产汇总会把总表与分项重复计电；
3. 给已有 level=1 的表补 `capacityKw` —— 部件据此算负载率，
   比把容量写在看板设置里更准（容量是设备属性，不是页面属性）。

<h2>用法</h2>

```bash
python3 tools/add-site-gate-meters.py --dry-run
python3 tools/add-site-gate-meters.py
python3 tools/add-site-gate-meters.py --site 办公园区
```

退出码：0 成功；1 有失败（逐条打印原因）。
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8090"
TENANT = "tenant@126.com"
TENANT_PASS = "12345678"

# 场站 → 档案 / 容量 / 表名
#
# 容量取值依据：办公园区 20 kVA、生产园区 630 kVA 来自安装模板
# （`EnergyBootstrapInstaller` 的 MeterNode 树 A / 树 B）；
# 质量示范站是后加的机房，按各演示进线表 400 kVA 的一致口径取 400。
PLAN = [
    {"site": "办公园区",   "profile": "单相电能表", "capacity": 20,  "label": "1#进线总表"},
    {"site": "质量示范站", "profile": "电能表",     "capacity": 400, "label": "1#进线总表"},
]

# 已有 level=1 的表补容量（不建设备，只补属性）
BACKFILL_CAPACITY = [
    {"device": "正泰三相电表 DTSD3366D", "capacity": 630},
    {"device": "雅达三相电表 YDPQ200-A", "capacity": 630},
]


def api(path, token=None, method=None, body=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["X-Authorization"] = "Bearer " + token
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path, data=data, headers=headers, method=method or ("POST" if data else "GET")
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read().decode()
            return json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method or 'GET'} {path} -> {e.code}: {e.read().decode()[:300]}")


def paged(path, token):
    out, page = [], 0
    while True:
        sep = "&" if "?" in path else "?"
        d = api(f"{path}{sep}pageSize=100&page={page}", token)
        out.extend(d.get("data", []))
        if not d.get("hasNext"):
            return out
        page += 1


def elec_children(token, site_id, all_devices, profiles, profile_of_site_gate):
    """该场站下需要挂到总表的电表（排除总表自己）。"""
    out = []
    for d in all_devices:
        ai = d.get("additionalInfo") or {}
        if ai.get("siteId") != site_id:
            continue
        # 虚拟表是「手工填报」的载体，不参与自动上报，挂进层级只会把电量算两遍
        if str(ai.get("deviceVirtual") or "").lower() == "virtual":
            continue
        if profiles.get((d.get("deviceProfileId") or {}).get("id")) not in ("电能表", "单相电能表"):
            continue
        if d["name"] in profile_of_site_gate:
            continue
        out.append(d)
    return out


def meter_parents(token, device_id, devices_by_id, profiles):
    """
    上游的**电表**父节点。

    ★ 不能把「有父节点」一律当作「已被别的总表管着」：
      演示数据里每台表都挂在网关下（`ED1-Gateway Contains 设备`），
      那是**通信**关系，与电量层级无关。
      第一版就是这么判的，结果办公园区的两台表被误判成「已有父表」而跳过。
    """
    rels = api(
        f"/api/relations?toId={device_id}&toType=DEVICE&relationType=Contains&relationTypeGroup=COMMON",
        token,
    )
    out = []
    for r in rels or []:
        src = r.get("from") or {}
        if src.get("entityType") != "DEVICE":
            continue
        parent = devices_by_id.get(src.get("id"))
        if not parent:
            continue
        if profiles.get((parent.get("deviceProfileId") or {}).get("id")) in ("电能表", "单相电能表"):
            out.append(parent)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--site", help="只处理某个场站")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    token = api("/api/auth/login", method="POST",
                body={"username": TENANT, "password": TENANT_PASS})["token"]

    profiles = {p["id"]["id"]: p["name"] for p in paged("/api/deviceProfiles", token)}
    profile_ids = {v: k for k, v in profiles.items()}
    assets = paged("/api/tenant/assets", token)
    asset_profiles = {p["id"]["id"]: p["name"] for p in paged("/api/assetProfiles", token)}
    sites = [a for a in assets if asset_profiles.get(a["assetProfileId"]["id"]) == "场站"]
    devices = paged("/api/tenant/devices", token)
    by_name = {d["name"]: d for d in devices}

    plan = [p for p in PLAN if not args.site or p["site"] == args.site]
    if not plan:
        print(f"PLAN 里没有场站「{args.site}」", file=sys.stderr)
        return 1

    made, linked, capped = 0, 0, 0
    for item in plan:
        hits = [s for s in sites if (s.get("label") or s["name"]) == item["site"]]
        if len(hits) != 1:
            print(f"✗ 场站「{item['site']}」匹配到 {len(hits)} 个", file=sys.stderr)
            continue
        site = hits[0]
        site_id = site["id"]["id"]
        customer_id = (site.get("customerId") or {}).get("id")
        dev_name = f"{item['site']}-{item['label']}·平台演示中心"

        print(f"\n=== {item['site']} ({site_id}) ===")
        if dev_name in by_name:
            print(f"· 已存在，跳过建设备：{dev_name}")
            dev = by_name[dev_name]
        else:
            profile_id = profile_ids.get(item["profile"])
            if not profile_id:
                print(f"✗ 找不到档案「{item['profile']}」", file=sys.stderr)
                continue
            if args.dry_run:
                print(f"[dry-run] 将建 {dev_name}  档案={item['profile']}  容量={item['capacity']} kVA")
                dev = None
            else:
                body = {
                    "name": dev_name,
                    "label": item["label"],
                    "deviceProfileId": {"entityType": "DEVICE_PROFILE", "id": profile_id},
                    "additionalInfo": {
                        "siteId": site_id,
                        "energyTypeCode": "elec",
                        "deviceVirtual": "real",
                    },
                }
                dev = api("/api/device", token, method="POST", body=body)
                made += 1
                print(f"✓ 已建 {dev_name}  id={dev['id']['id']}")

        target = dev or by_name.get(dev_name)
        did = target["id"]["id"] if target else None

        if did and not args.dry_run:
            attrs = {
                "meterLevel": 1,
                "capacityKw": item["capacity"],
                "type1": "elec",
                "deviceType1": "elec_meter",
                "energy": "elec",
                "role": "meter",
                "type2": "normal",
                "participate": True,
                "deviceVirtual": "real",
            }
            api(f"/api/plugins/telemetry/DEVICE/{did}/attributes/SERVER_SCOPE", token,
                method="POST", body=attrs)
            print(f"  属性已写：meterLevel=1 capacityKw={item['capacity']}")
            if customer_id:
                try:
                    api(f"/api/customer/{customer_id}/device/{did}", token, method="POST")
                except RuntimeError as e:
                    print(f"  · 归属客户已是该客户或失败：{e}", file=sys.stderr)
            for rt in ("Contains", "SiteContains"):
                try:
                    api("/api/relation", token, method="POST", body={
                        "from": {"entityType": "ASSET", "id": site_id},
                        "to": {"entityType": "DEVICE", "id": did},
                        "type": rt, "typeGroup": "COMMON",
                    })
                except RuntimeError as e:
                    # 已存在会报 400；幂等运行不该因此失败
                    if "already exists" not in str(e).lower() and "400" not in str(e):
                        print(f"  ✗ 关系 {rt}: {e}", file=sys.stderr)

        # 把该站原有电表挂到总表下（父表 >= Σ 子表，避免汇总重复计电）
        kids = elec_children(token, site_id, devices, profiles, {dev_name})
        for kid in kids:
            kid_name = kid["name"]
            if args.dry_run:
                print(f"[dry-run] 将把 {kid_name} 挂到 {dev_name} 下")
                continue
            dev_by_id = {d["id"]["id"]: d for d in devices}
            parents = meter_parents(token, kid["id"]["id"], dev_by_id, profiles)
            if any(p["id"]["id"] == did for p in parents):
                continue
            if parents:
                # 已有**电表**父节点时不抢：那是正常的「分项总表 → 回路」层级
                names = "、".join(p["name"] for p in parents)
                print(f"  · 跳过 {kid_name}：已挂在其它电表下（{names}）")
                continue
            if not did:
                continue
            try:
                api("/api/relation", token, method="POST", body={
                    "from": {"entityType": "DEVICE", "id": did},
                    "to": {"entityType": "DEVICE", "id": kid["id"]["id"]},
                    "type": "Contains", "typeGroup": "COMMON",
                })
                linked += 1
                print(f"  ✓ 挂载 {kid_name}")
            except RuntimeError as e:
                print(f"  ✗ 挂载 {kid_name}: {e}", file=sys.stderr)

    # 已有关口表补容量
    if not args.site:
        print("\n=== 补齐已有关口表的额定容量 ===")
        for item in BACKFILL_CAPACITY:
            hit = next(
                (d for d in devices
                 if item["device"] in (d.get("label") or "") or item["device"] in (d.get("name") or "")),
                None,
            )
            if not hit:
                print(f"· 找不到设备：{item['device']}（跳过）")
                continue
            if args.dry_run:
                print(f"[dry-run] 将给 {hit['name']} 写 capacityKw={item['capacity']}")
                continue
            api(f"/api/plugins/telemetry/DEVICE/{hit['id']['id']}/attributes/SERVER_SCOPE", token,
                method="POST", body={"capacityKw": item["capacity"]})
            capped += 1
            print(f"✓ {hit['name']} capacityKw={item['capacity']}")

    print()
    if args.dry_run:
        print("[dry-run] 未做任何修改")
        return 0
    print(f"完成：新建 {made} 台，挂载 {linked} 台子表，补容量 {capped} 台")
    print("→ 下一步：重跑模拟器让新表出数（它按 meterLevel 选 nominal，自动接管）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
