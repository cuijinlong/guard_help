#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
给关口表补 `demand_max`（当天最大需量）—— 只补缺的，不覆盖已有的。

<h2>为什么需要</h2>

「用电容量负荷需量监控」读的是 `demand_max`，但演示模拟器在 2026-11-16 之前
**根本没写这个键**（只有安装时的一次性快照里有）。于是：

```
power_total        一直有                              （模拟器每分钟写）
power_factor_total 一直有
demand_max         最后一点 2026-11-16 12:00           ← 断供
```

页面表现：需量曲线前面两天有点、后面整段空白；KPI 显示的是 8 天前的峰值。

<h2>为什么可以用 power_total 反推</h2>

`demand_max` 的定义就是「当天为周期的最大功率」，
安装快照的生成逻辑也是 `dayPeak = max(dayPeak, pTotal)`（见
`EnergyBootstrapInstaller`）。所以由同一时刻的 `power_total` 算出当天累积峰值，
与表计自己上报的是**同一个量**，不是编出来的数。

<h2>安全边界</h2>

- 只写 `demand_max` 一个键，不碰表底（`energy_reading`）、不碰功率；
- 已经有 `demand_max` 的时间点**跳过**，不覆盖真实表计上报；
- 默认 dry-run，加 `--apply` 才写。

用法：

```bash
python3 tools/backfill-demand-max.py                      # 全部关口表，dry-run
python3 tools/backfill-demand-max.py --apply
python3 tools/backfill-demand-max.py --device 正泰 --days 30 --apply
```
"""

import argparse
import datetime
import json
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8090"
TENANT = "tenant@126.com"
TENANT_PASS = "12345678"
BATCH = 200


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", help="设备名关键字，默认处理全部关口表")
    ap.add_argument("--days", type=int, default=60)
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    token = api("/api/auth/login", method="POST",
                body={"username": TENANT, "password": TENANT_PASS})["token"]

    items = api("/api/energy/meters", token).get("items") or []
    gates = [m for m in items if str(m.get("meterLevel")) == "1"]
    if args.device:
        gates = [m for m in gates if args.device in (m.get("name") or "")]
    if not gates:
        print("没有匹配的关口表", file=sys.stderr)
        return 1

    now = datetime.datetime.now()
    frm = int((now - datetime.timedelta(days=args.days)).timestamp() * 1000)
    to = int(now.timestamp() * 1000)

    total_written = 0
    for m in gates:
        dev, name = m["deviceId"], m.get("name")
        p = api(
            f"/api/plugins/telemetry/DEVICE/{dev}/values/timeseries?keys=power_total,demand_max"
            f"&startTs={frm}&endTs={to}&limit=20000&orderBy=ASC",
            token,
        )
        powers = {int(x["ts"]): float(x["value"]) for x in (p.get("power_total") or [])}
        have = {int(x["ts"]) for x in (p.get("demand_max") or [])}
        if not powers:
            print(f"· {name}：没有 power_total，跳过")
            continue
        if not have:
            print(f"· {name}：完全没有 demand_max，将按当天峰值补齐")
        missing = sorted(ts for ts in powers if ts not in have)
        if not missing:
            print(f"✓ {name}：demand_max 已齐（{len(have)} 点）")
            continue

        # 按天算累积峰值（跨天归零），与表计/安装快照同口径
        rows, day, peak = [], None, 0.0
        for ts in sorted(powers):
            d = datetime.datetime.fromtimestamp(ts / 1000).date()
            if d != day:
                day, peak = d, 0.0
            peak = max(peak, powers[ts])
            if ts in have:
                continue
            rows.append({"ts": ts, "values": {"demand_max": round(peak, 2)}})

        print(f"→ {name}：补 {len(rows)} 点（{args.days} 天内）")
        if not args.apply:
            for r in rows[:3]:
                when = datetime.datetime.fromtimestamp(r["ts"] / 1000)
                print(f"    [{when:%Y-%m-%d %H:%M}] demand_max={r['values']['demand_max']}")
            continue
        for i in range(0, len(rows), BATCH):
            api(f"/api/plugins/telemetry/DEVICE/{dev}/timeseries/ANY", token,
                method="POST", body=rows[i:i + BATCH])
        total_written += len(rows)
        print(f"  ✓ 已写 {len(rows)} 点")

    print()
    if args.apply:
        print(f"完成：补写 {total_written} 点")
    else:
        print("[dry-run] 未写入。加 --apply 执行")
    return 0


if __name__ == "__main__":
    sys.exit(main())
