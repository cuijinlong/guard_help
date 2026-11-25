#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
验收「功率因数与负荷需量」部件的数据口径（2026-11-25 客户报障后新增）。

<h2>客户报的是什么</h2>

> 「能源概览页面中功率因数与负荷需量为 0 不对」

<h2>这个脚本答什么问题</h2>

部件自己不会算错，但它对**缺数据**只写一句「所选范围没有功率因数数据」，
而指针会停在 0° —— 看起来就是「功率因数真的是 0」。
所以要分三层验，缺哪层就补哪层：

| 层 | 判据 | 断了的表现 |
| --- | --- | --- |
| 档案 | 每个场站都要有 `meterLevel=1` 的关口表 | 部件取不到任何表 → 指针 0 / 需量 `—` |
| 遥测 | 关口表要有 `power_factor_total` / `demand_max` | 曲线中断、需量停在历史快照 |
| 口径 | 部件算出的 PF 要等于独立算的 ΣP/ΣS | 加权错了，数字看着像对的 |

<h2>为什么 PF 要交叉校验</h2>

部件用 `Σ(pf·S)/ΣS`（按天 AVG 加权的近似）。严格定义是 `ΣP/ΣS`。
两者在「同时刻取值」的前提下应当几乎相等；差得大说明时间窗或加权错了。
本脚本两条都算一遍，差值 > 0.01 判失败。

<h2>用法</h2>

```bash
# 默认用客户账号（演示环境）
python3 tools/verify-power-load.py

# 指定账号 / 服务地址
TB_BASE=http://127.0.0.1:8090 TB_USER=demo@126.com TB_PASS=... \
  python3 tools/verify-power-load.py --month 2026-11
```

退出码：0 全部通过；1 有判据不满足（逐条打印实测值）。
"""

import argparse
import collections
import datetime
import json
import os
import sys
import urllib.parse
import urllib.request

BASE = os.environ.get("TB_BASE", "http://127.0.0.1:8090")
USER = os.environ.get("TB_USER", "demo@126.com")
PASS = os.environ.get("TB_PASS", "demo123456")

PF_KEY = "power_factor_total"
S_KEY = "apparent_power_total"
P_KEY = "power_total"
D_KEY = "demand_max"

failures = []


def check(ok, label, detail=""):
    print(f"{'✓' if ok else '✗'} {label}" + (f" — {detail}" if detail else ""))
    if not ok:
        failures.append(label)


def login():
    body = json.dumps({"username": USER, "password": PASS}).encode()
    req = urllib.request.Request(
        BASE + "/api/auth/login", data=body, headers={"Content-Type": "application/json"}
    )
    return json.load(urllib.request.urlopen(req, timeout=60))["token"]


def get(token, path):
    req = urllib.request.Request(BASE + path, headers={"X-Authorization": "Bearer " + token})
    return json.load(urllib.request.urlopen(req, timeout=120))


def series(token, dev, keys, frm, to, agg="AVG", interval=86_400_000):
    """与部件完全同一条 URL —— 口径可比才有意义。"""
    q = urllib.parse.urlencode(
        {
            "keys": ",".join(keys),
            "startTs": frm,
            "endTs": to,
            "interval": interval,
            "intervalType": "MILLISECONDS",
            "agg": agg,
            "limit": 2000,
            "orderBy": "ASC",
        }
    )
    return get(token, f"/api/plugins/telemetry/DEVICE/{dev}/values/timeseries?{q}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--month", help="YYYY-MM，默认本月")
    args = ap.parse_args()

    now = datetime.datetime.now()
    if args.month:
        y, m = (int(x) for x in args.month.split("-"))
        start = datetime.datetime(y, m, 1)
        end = (start.replace(day=28) + datetime.timedelta(days=8)).replace(day=1)
        end = min(end, now) if start <= now else end
    else:
        start = datetime.datetime(now.year, now.month, 1)
        end = now
    frm, to = int(start.timestamp() * 1000), int(end.timestamp() * 1000)
    print(f"· 服务 {BASE} · 账号 {USER}")
    print(f"· 统计窗口 {start:%Y-%m-%d} → {end:%Y-%m-%d %H:%M}\n")

    token = login()
    meters = get(token, "/api/energy/meters").get("items") or []
    assets = get(token, "/api/energy/visible-sites").get("assets") or []
    sites = [a for a in assets if a.get("type") == "场站"]

    elec = [m for m in meters if m.get("energy") == "elec"]
    gates = [m for m in elec if str(m.get("meterLevel")) == "1"]

    print("【1】档案层：关口表（meterLevel=1）")
    check(len(elec) > 0, "有电表档案", f"{len(elec)} 台电表")
    check(len(gates) > 0, "至少有一台关口表", f"{len(gates)} 台")

    by_site = collections.defaultdict(list)
    for m in gates:
        by_site[m.get("siteId")].append(m)

    for st in sites:
        sid = (st.get("id") or {}).get("id")
        name = st.get("label") or st.get("name")
        n = len(by_site.get(sid, []))
        check(
            n > 0,
            f"场站「{name}」有口径表",
            f"{n} 台关口表" if n else "0 台 —— 该场站的功率因数与需量必然为空",
        )
        if n == 0:
            loose = [m["name"] for m in elec if m.get("siteId") == sid]
            if loose:
                print(f"    该站下的电表（{len(loose)} 台，全部是 level≠1）：{'、'.join(loose[:6])}")

    print("\n【2】遥测层：关口表的 PF / 需量可用性")
    for m in gates:
        pf = series(token, m["deviceId"], [PF_KEY], frm, to).get(PF_KEY) or []
        dm = series(token, m["deviceId"], [D_KEY], frm, to).get(D_KEY) or []
        check(len(pf) > 0, f"{m['name']} 有功率因数", f"{len(pf)} 个点")
        check(len(dm) > 0, f"{m['name']} 有最大需量", f"{len(dm)} 个点")
        # 需量停在历史快照时，曲线开头有点、后面整段空白 —— 只判「有点」会漏掉。
        if dm:
            last = datetime.datetime.fromtimestamp(int(dm[-1]["ts"]) / 1000)
            idle_days = (end - last).days
            check(
                idle_days <= 2,
                f"{m['name']} 需量数据是新的",
                f"最后一点 {last:%Y-%m-%d %H:%M}（距今 {idle_days} 天）",
            )

    print("\n【3】口径层：PF 加权 vs 独立 ΣP/ΣS")
    for st in sites:
        sid = (st.get("id") or {}).get("id")
        name = st.get("label") or st.get("name")
        gs = by_site.get(sid, [])
        if not gs:
            print(f"· 场站「{name}」：无关口表，跳过口径校验")
            continue

        pf_sum = pf_weight = plain = cnt = 0.0
        p_sum = s_sum = 0.0
        d_series = {}
        for m in gs:
            r = series(token, m["deviceId"], [PF_KEY, S_KEY], frm, to)
            pfa, sa = r.get(PF_KEY) or [], r.get(S_KEY) or []
            s_by_ts = {x["ts"]: float(x["value"]) for x in sa}
            for p in pfa:
                v = float(p["value"])
                plain, cnt = plain + v, cnt + 1
                sv = s_by_ts.get(p["ts"])
                if sv and sv > 0:
                    pf_sum += v * sv
                    pf_weight += sv
            # ★ 必须按 ts 配对再求和。
            #
            #   直接「ΣP / ΣS」在采样点不齐时会失真：
            #   实测某台表当天 P 有 2 个点、S 只有 1 个（改版前那一轮没写 S），
            #   比值算出来 0.9955，而真实 PF 是 0.9445 —— 看起来像部件算错了。
            r2 = series(token, m["deviceId"], [P_KEY, S_KEY], frm, to)
            p_by_ts = {x["ts"]: float(x["value"]) for x in (r2.get(P_KEY) or [])}
            s_by_ts = {x["ts"]: float(x["value"]) for x in (r2.get(S_KEY) or [])}
            for ts in set(p_by_ts) & set(s_by_ts):
                p_sum += p_by_ts[ts]
                s_sum += s_by_ts[ts]
            d_series[m["name"]] = series(
                token, m["deviceId"], [D_KEY], frm, to, "MAX", 3_600_000
            ).get(D_KEY) or []

        pf_widget = (pf_sum / pf_weight) if pf_weight > 0 else (plain / cnt if cnt else None)
        pf_strict = (p_sum / s_sum) if s_sum > 0 else None
        detail = "无数据"
        if pf_widget is not None and pf_strict is not None:
            detail = f"部件 {pf_widget:.4f} / 独立 {pf_strict:.4f} / 差 {abs(pf_widget - pf_strict):.4f}"
            check(abs(pf_widget - pf_strict) <= 0.01, f"场站「{name}」PF 口径一致", detail)
        else:
            check(False, f"场站「{name}」PF 可算", detail)

        # 需量 vs 功率峰值：两个量应同量级（需量是"当天最大功率"，不该远低于功率峰值）
        demand_by_ts = collections.defaultdict(float)
        for arr in d_series.values():
            for x in arr:
                demand_by_ts[x["ts"]] += float(x["value"])
        max_demand = max(demand_by_ts.values()) if demand_by_ts else None
        power_rows = []
        for m in gs:
            rr = series(token, m["deviceId"], [P_KEY], frm, to, "MAX", 3_600_000).get(P_KEY) or []
            power_rows.append({x["ts"]: float(x["value"]) for x in rr})
        common = set.intersection(*[set(r) for r in power_rows]) if power_rows else set()
        max_power = max((sum(r[t] for r in power_rows) for t in common), default=None)

        if max_demand is None:
            check(False, f"场站「{name}」有需量数据", "demand_max 一个点都没有")
        else:
            ratio = (max_demand / max_power) if max_power else None
            msg = f"需量峰 {max_demand:.1f} kW / 功率峰 {max_power:.1f} kW"
            if ratio is not None:
                msg += f" / 比 {ratio:.2f}"
            # 需量口径是「当天最大」，正常应落在功率峰值的 0.5~1.2 之间
            check(
                ratio is None or 0.5 <= ratio <= 1.2,
                f"场站「{name}」需量与功率同量级",
                msg,
            )

    print("\n【4】额定容量：设备铭牌优先")
    print("· 取值优先级：设备 capacityKw（多表求和） > 看板 ratedCapacity > 实测峰值视在功率")
    for m in gates:
        rows = get(token, f"/api/plugins/telemetry/DEVICE/{m['deviceId']}/values/attributes?keys=capacityKw")
        rows = rows if isinstance(rows, list) else [rows]
        cap = next((r.get("value") for r in rows if r and r.get("key") == "capacityKw"), None)
        check(
            cap is not None and float(cap) > 0,
            f"{m['name']} 有铭牌容量",
            f"capacityKw={cap}" if cap else "未配置 —— 负载率会退回实测峰值，永远算不出百分比",
        )

    print()
    if failures:
        print(f"✗ {len(failures)} 条判据未通过：")
        for item in failures:
            print(f"  - {item}")
        return 1
    print("✓ 全部判据通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
