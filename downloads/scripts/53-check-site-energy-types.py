#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
体检「场站声明的能源品种」与「设备实际 type1」是否一致（2026-11-25 客户报障后新增）。

<h2>客户报的是什么</h2>

> 「平台中各个仪表板功能『查询设置』或『条件分析』部件是不是都统一配置的
>  那五个用能品种，导致我的冷热机组模块、立式管道离心泵都没有获取到」

<h2>实测结论：不是部件统一配置，是场站声明决定</h2>

品种列表**不来自部件**，而是：

```
部件 → GET /api/energy/metric-params?siteId=<场站>
     → 后端读该场站资产的 energyType 属性（SERVER/SHARED_SCOPE）
     → 只返回声明过的品种
```

所以「场站声明了哪几个品种」= 「查询设置/分析条件里能看到哪几个」。
设备能不能被选到，取决于它的 `type1` 是否在这些声明里。

<h2>两个部件的差别（这是最容易误判的一点）</h2>

| 部件 | 看板 | 是否传 energyOnly | 后果 |
| --- | --- | --- | --- |
| 查询设置 `query_panel` | 历史能耗/基础报表/实时能耗/峰谷分析/我的账单/手工填报/抄表功能 | **否** | 声明里有的品种都能选（含 env）|
| 分析条件 `analysis_bar` | 分项能耗/区域能耗/综合能耗/能源流向/能耗概览/闲时能耗 | **是** | `isEnergy=false` 的品种被滤掉 |

`energyOnly=true` 是 2026-11-04 客户明确要求的：
「查询设置和分析条件部件中，用能品种下拉框中不应该有『环境系统』」。

<h2>用法</h2>

```bash
python3 scripts/53-check-site-energy-types.py
# 换账号：TB_USER=tenant@126.com TB_PASS=*** python3 scripts/53-check-site-energy-types.py
```

退出码：0 无缺口；1 有「设备用了但场站没声明」的品种（那些设备在部件里看不到）。
"""

import argparse
import collections
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("TB_BASE", "http://127.0.0.1:8090")
USER = os.environ.get("TB_USER", "demo@126.com")
PASS = os.environ.get("TB_PASS", "demo123456")


def api(path, token=None, method=None, body=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["X-Authorization"] = "Bearer " + token
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path, data=data, headers=headers, method=method or ("POST" if data else "GET")
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        raw = r.read().decode()
        return json.loads(raw) if raw.strip() else {}


def paged(path, token):
    out, page = [], 0
    while True:
        sep = "&" if "?" in path else "?"
        d = api(f"{path}{sep}pageSize=1000&page={page}", token)
        out.extend(d.get("data", []))
        if not d.get("hasNext"):
            return out
        page += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--site", help="只看某个场站（按名称/标签匹配）")
    args = ap.parse_args()

    token = api("/api/auth/login", method="POST",
                body={"username": USER, "password": PASS})["token"]

    user = api("/api/auth/user", token)
    cid = (user.get("customerId") or {}).get("id")
    if not cid:
        print("这个账号不是客户账号，无法按场站体检。用 TB_USER=demo@... 重试", file=sys.stderr)
        return 2

    sites = [a for a in api(f"/api/energy/visible-sites?customerId={cid}", token).get("assets") or []
             if a.get("type") == "场站"]
    if args.site:
        sites = [s for s in sites if args.site in ((s.get("label") or "") + (s.get("name") or ""))]
        if not sites:
            print(f"找不到场站「{args.site}」", file=sys.stderr)
            return 2

    devs = paged(f"/api/customer/{cid}/devices", token)

    # 设备 → type1（SERVER_SCOPE 优先，退回 additionalInfo）
    dev_type1 = {}
    for d in devs:
        did = d["id"]["id"]
        ai = d.get("additionalInfo") or {}
        try:
            rows = api(f"/api/plugins/telemetry/DEVICE/{did}/values/attributes/SERVER_SCOPE?keys=type1", token)
            got = {r["key"]: r.get("value") for r in (rows or [])}
        except (urllib.error.HTTPError, ValueError):
            got = {}
        dev_type1[did] = {
            "name": d.get("name"),
            "site": ai.get("siteId"),
            "type1": got.get("type1") or ai.get("type1") or "",
        }

    # 全量品种字典（不带 siteId）：用来解释 code → 中文名与 isEnergy
    all_kinds = {k.get("code"): k for k in
                 (api("/api/energy/metric-params", token).get("kinds") or [])}

    gaps = 0
    for s in sites:
        sid = (s.get("id") or {}).get("id")
        nm = s.get("label") or s.get("name")
        declared = [k.get("code") for k in
                    (api(f"/api/energy/metric-params?siteId={sid}", token).get("kinds") or [])]
        used = collections.Counter(v["type1"] for v in dev_type1.values()
                                   if v["site"] == sid and v["type1"])
        missing = {c: n for c, n in used.items() if c not in declared}

        print(f"\n=== {nm} ===")
        print(f"  已声明品种: {declared or '（空）'}")
        print(f"  设备实际 type1: {dict(used) or '（无）'}")
        if not missing:
            print("  ✓ 一致")
            continue

        gaps += len(missing)
        print(f"  ✗ 有 {sum(missing.values())} 台设备用的品种没被声明 —— 部件里选不到：")
        for code, n in missing.items():
            kind = all_kinds.get(code) or {}
            tag = "用能" if kind.get("isEnergy") else "非用能"
            print(f"    · {code} {kind.get('name') or '?'}（{tag}）{n} 台")
            names = [v["name"] for v in dev_type1.values()
                     if v["site"] == sid and v["type1"] == code]
            for name in names[:4]:
                print(f"        - {name}")
            if len(names) > 4:
                print(f"        … 共 {len(names)} 台")
        print(f"    修法：把 {list(missing)} 补进该场站的 energyType 属性")
        print(f"          见 docs：故障手册「查询设置 / 分析条件看不到设备」")

    print()
    if gaps:
        print(f"✗ {gaps} 个品种缺口。注意：分析条件部件还会再过一道 energyOnly，")
        print("  非用能品种（env/cooling/air）即使补了声明也不会出现在它的下拉里。")
        return 1
    print("✓ 各场站的品种声明与设备实际归类一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
