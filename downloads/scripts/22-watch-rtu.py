#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RTU 电表实时观察（只读，不下发任何指令）

用途：现场接负载时，盯着电流/功率是否跟着变。
      排查「音响开着但功率一直是 0」这类接线问题。

用法（在部署目录内）：
  python3 scripts/22-watch-rtu.py --base http://127.0.0.1:8090 \
      --tenant tenant@126.com --tenant-pass 12345678 \
      --customer customer@126.com --customer-pass 12345678

  # 盯 3 分钟，每 2 秒刷新
  python3 scripts/22-watch-rtu.py ... --seconds 180 --interval 2

输出示例：
  18:52:31  电压 227.0 V   电流 0.000 A   功率 0.0 W   PF 1.00   表底 8.360
  18:52:33  电压 226.9 V   电流 0.235 A   功率 51.7 W   PF 0.97   表底 8.360   ← 有负载

判读：
  电压有值、电流恒 0  → 电表的电流回路没有电流通过（接线问题，不是软件问题）
  电流正常、功率为 0  → 功率因数或寄存器异常
  三个都有值且表底在涨 → 一切正常
"""
import argparse
import json
import math
import sys
import time
import urllib.request


def api(base, path, token=None, method=None, body=None):
    req = urllib.request.Request(base + path, method=method or ("POST" if body else "GET"))
    if body is not None:
        req.data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("X-Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=30) as r:
        t = r.read().decode()
        return json.loads(t) if t.strip() else None


def main():
    ap = argparse.ArgumentParser(description="RTU 电表实时观察（只读）")
    ap.add_argument("--base", default="http://127.0.0.1:8090")
    ap.add_argument("--tenant", required=True)
    ap.add_argument("--tenant-pass", required=True)
    ap.add_argument("--customer", required=True)
    ap.add_argument("--customer-pass", help="留空则用租户身份查（需租户可见该设备）")
    ap.add_argument("--device", default="PowerMeter-DDSU777", help="电表设备名")
    ap.add_argument("--seconds", type=int, default=120, help="观察时长，0=一直跑")
    ap.add_argument("--interval", type=float, default=2, help="刷新间隔秒")
    ap.add_argument("--sensor", default="Sensor-HZ8706", help="顺带看的温湿度设备名")
    args = ap.parse_args()

    base = args.base.rstrip("/")
    tok = api(base, "/api/auth/login", method="POST",
              body={"username": args.tenant, "password": args.tenant_pass})["token"]

    # 找设备：优先用客户身份（客户账号能看到自己名下设备）
    user = api(base, "/api/auth/user", tok)
    cid = (user.get("customerId") or {}).get("id")
    if args.customer_pass:
        ctok = api(base, "/api/auth/login", method="POST",
                   body={"username": args.customer, "password": args.customer_pass})["token"]
        cu = api(base, "/api/auth/user", ctok)
        cid = (cu.get("customerId") or {}).get("id") or cid
        tok = ctok
    if not cid:
        raise SystemExit("拿不到客户 id：请传 --customer-pass 用客户账号登录")

    infos = api(base, "/api/customer/%s/deviceInfos?pageSize=200&page=0" % cid, tok)
    by_name = {d["name"]: d["id"]["id"] for d in infos.get("data", [])}
    did = by_name.get(args.device)
    if not did:
        near = [n for n in by_name if args.device.lower() in n.lower()]
        raise SystemExit("找不到设备「%s」。相近的：%s" % (args.device, near or "（无）"))

    print("观察设备：%s（%s）" % (args.device, did[:8]))
    print("只读模式：本脚本不会下发任何 RPC / 控制指令")
    print("-" * 96)

    t0 = time.time()
    last_ep = None
    saw_load = False
    while True:
        if args.seconds and time.time() - t0 > args.seconds:
            break
        try:
            d = api(base, "/api/plugins/telemetry/DEVICE/%s/values/timeseries"
                          "?keys=voltage_a,current_a,power_total,power_factor_total,energy_reading"
                          "&limit=1&orderBy=DESC" % did, tok)
            def g(k):
                v = (d.get(k) or [{}])[0].get("value")
                try:
                    return float(v)
                except (TypeError, ValueError):
                    return None
            u, i, p, pf, ep = g("voltage_a"), g("current_a"), g("power_total"), g("power_factor_total"), g("energy_reading")
            mark = ""
            if i and i > 0.05:
                mark = "  ← 有负载"
                saw_load = True
            if last_ep is not None and ep is not None and ep > last_ep:
                mark += "  表底 +%.3f" % (ep - last_ep)
            last_ep = ep if ep is not None else last_ep
            print("%s  %s V  %s A  %s W  PF %.2f  表底 %s%s" % (
                time.strftime("%H:%M:%S"),
                ("%.1f" % u) if u is not None else "-",
                ("%.3f" % i) if i is not None else "-",
                ("%.1f" % p) if p is not None else "-",
                pf if pf is not None else 0,
                ("%.3f" % ep) if ep is not None else "-",
                mark))
        except Exception as e:
            print("%s  读取失败：%s" % (time.strftime("%H:%M:%S"), e))
        time.sleep(args.interval)

    print("-" * 96)
    if saw_load:
        print("✓ 观察到电流 > 0.05 A：电表的电流回路是通的")
    else:
        print("✗ 全程电流为 0：电表没有测到电流")
        print("  请按顺序确认：")
        print("   ① 负载是否接在**电表的出线侧**（火线必须穿过电表的电流端子）")
        print("   ② 负载是否插在**继电器受控插座**上 —— 继电器全关时那个插座没电")
        print("   ③ 电表的 L/N 是否只并接了电压（只有电压没有电流就是这种接法）")


if __name__ == "__main__":
    main()
