#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
现场演示模拟器 —— 给"不能真机演示"的表计持续喂新鲜数据

<h3>它解决什么问题</h3>
现场演示时手上只有一台 RTU（一台真实单相电表 + 一个温湿度 + 一路继电器），
但客户想看的是**整套系统**：三相电的电能质量、水表、燃气表、蒸汽表、
分项/区域/峰谷/账单……这些没法真机演。

演示数据是一次性快照，几小时后就全部「数据陈旧」，抄表判 stale、账单空。
本脚本让这些表**持续上报**，页面上的曲线一直在走，抄表实时能抄。

<h3>分工（重要）</h3>
| 品种 | 谁来出数 |
| --- | --- |
| 单相电（RTU 那台） | **真实 RTU**，本脚本不碰 |
| 单相电（其余演示表） | 本脚本 |
| 三相电 | 本脚本（真机没三相表） |
| 水 / 燃气 / 蒸汽 | 本脚本 |
| 温湿度（非 RTU 那台） | 本脚本 |

脚本按 `--skip` 或自动识别跳过 RTU 设备（见 `--rtu-devices`），
保证同一台表不会被两个源同时写 —— 那样表底会跳变，抄表判 abnormal。

<h3>数据模型（与平台约定一致，改错会让看板空白）</h3>
```
电表     energy（本周期增量） energy_reading（累积表底，单调递增） power_total
         voltage_a [current_a] [power_a]     三相另有 _b / _c
水/气/汽  energy（本周期增量） energy_reading（累积表底） power
温湿度    temperature humidity
```

**表底必须单调递增**，且父表增量 >= 子表之和 —— 验收脚本
（`08-verify-release.sh` 的「演示用电层级守恒」）会查这一条。
本脚本按层级树分配功率，父表 = 子表之和 × (1 + 线损率)，天然满足。

<h3>用法</h3>
```bash
# 跑一轮（给验收/自检用），打印每台表的读数
python3 scripts/23-demo-simulator.py \
  --base http://127.0.0.1:8090 --tenant tenant@126.com --tenant-pass 12345678 \
  --customer 平台演示中心 --once

# 持续跑（每 60 秒一批，Ctrl-C 停）
python3 scripts/23-demo-simulator.py ... --interval 60

# 先看清楚会动哪些表，不写库
python3 scripts/23-demo-simulator.py ... --dry-run

# 同时刷新资产汇总（看板「选场站」读的是资产上的 energy_total）
python3 scripts/23-demo-simulator.py ... --interval 60 --rebuild-totals
```

退出码：0 全部成功；1 有失败。
"""

import argparse
import json
import math
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# 与 21-rtu-onboard.py 保持一致：这几台由真实 RTU 出数，模拟器不能碰
RTU_DEFAULT = {"ED1-Gateway", "PowerMeter-DDSU777", "Sensor-HZ8706", "Relay-8CH"}

ELECTRIC_PROFILES = {"单相电能表", "电能表"}
UTILITY_PROFILES = {"水表": "water", "燃气表": "gas", "蒸汽表": "steam"}
SENSOR_PROFILES = {"温湿度变送器"}


# ---------------------------------------------------------------- HTTP
def api(base, path, token=None, method=None, body=None):
    req = urllib.request.Request(base + path, method=method or ("POST" if body else "GET"))
    if body is not None:
        req.data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("X-Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            t = r.read().decode()
            return json.loads(t) if t.strip() else None
    except urllib.error.HTTPError as e:
        raise RuntimeError("HTTP %s %s → %s" % (e.code, path, e.read().decode("utf-8", "replace")[:200]))
    except urllib.error.URLError as e:
        raise RuntimeError("连不上平台：%s" % e.reason)


def paged(base, path, token):
    out, page = [], 0
    while True:
        sep = "&" if "?" in path else "?"
        d = api(base, "%s%spageSize=500&page=%d" % (path, sep, page), token)
        out.extend(d.get("data") or [])
        if not d.get("hasNext"):
            return out
        page += 1


# ---------------------------------------------------------------- 负载曲线
def load_factor(hour, kind):
    """一天之内的负载系数。让曲线有形，不是一条直线。

    数值取「工业/商业典型日」：凌晨低谷、上午爬坡、午休回落、傍晚再起。
    只影响功率大小，不影响表底单调性。
    """
    if kind == "electric":
        curve = [0.35, 0.32, 0.30, 0.30, 0.33, 0.40, 0.55, 0.72, 0.88, 0.95,
                 0.92, 0.85, 0.78, 0.86, 0.94, 0.96, 0.90, 0.80, 0.70, 0.62,
                 0.55, 0.48, 0.42, 0.38]
    elif kind == "steam":
        # 蒸汽跟着生产班走，午休明显掉
        curve = [0.20, 0.18, 0.18, 0.18, 0.20, 0.30, 0.55, 0.80, 0.95, 0.98,
                 0.92, 0.60, 0.45, 0.85, 0.96, 0.94, 0.85, 0.70, 0.50, 0.35,
                 0.28, 0.25, 0.22, 0.20]
    elif kind == "gas":
        # 燃气：早中晚三餐高峰
        curve = [0.15, 0.12, 0.12, 0.12, 0.15, 0.35, 0.75, 0.85, 0.55, 0.35,
                 0.30, 0.65, 0.85, 0.50, 0.30, 0.28, 0.45, 0.70, 0.80, 0.55,
                 0.35, 0.25, 0.20, 0.17]
    else:  # water
        curve = [0.25, 0.22, 0.20, 0.20, 0.22, 0.35, 0.62, 0.80, 0.88, 0.85,
                 0.75, 0.70, 0.72, 0.80, 0.86, 0.84, 0.78, 0.70, 0.62, 0.55,
                 0.46, 0.38, 0.32, 0.28]
    return curve[int(hour) % 24]


# ---------------------------------------------------------------- 表计模型
class Meter:
    """一台表的状态机。只保留「表底」和「额定功率」两个关键量。"""

    def __init__(self, name, profile, level, reading, nominal_kw, kind, device_id,
                 phases=1, site_id=""):
        self.name = name
        self.profile = profile
        self.level = level              # 1 进线 / 2 分项 / 3 回路 / 0 不计入
        self.reading = float(reading)   # 累积表底，单调递增
        self.nominal_kw = float(nominal_kw)
        self.kind = kind                # electric / water / gas / steam / sensor
        self.device_id = device_id
        self.phases = phases            # 1 单相 / 3 三相
        self.site_id = site_id
        self.children = []
        self.this_power = 0.0           # 本轮实际功率（compute_power 填）
        self.is_virtual = False         # 虚拟表（手工填报用）不参与自动上报
        self.temp = 24.0
        self.humi = 55.0
        self.temp_drift = 0.0

    def compute_power(self, hour):
        """算出本周期实际功率，缓存到 self.this_power。**先算子表，再算父表**。

        ★ 为什么必须这样做（2026-10-24 踩过）：
          旧写法让父表按「子表名义值之和 × 1.04」算，而子表自己上报时又各自
          抖动了 ±6%。于是子表之和最大能到 1.06 倍，父表只有 1.04 倍 ——
          验收脚本「父表 >= Σ 子表」当场失败，看起来像演示数据算错了。
          改成先定子表的实际值，父表再由实际值汇总，恒定满足。
        """
        if self.children:
            for c in self.children:
                c.compute_power(hour)
            child_sum = sum(c.this_power for c in self.children)
            # 4% 线损 + 未装表负荷：父表一定 >= 子表之和
            self.this_power = child_sum * 1.04
        else:
            p = self.nominal_kw * load_factor(hour, self.kind)
            self.this_power = p * random.uniform(0.94, 1.06)   # 抖动让折线有毛刺
        return self.this_power


def build_payload(meter, hours):
    """按品种生成遥测字典。键名必须与平台/看板约定一致。"""
    hour = time.localtime().tm_hour
    if meter.kind == "sensor":
        meter.temp = round(meter.temp + random.uniform(-0.25, 0.25), 1)
        meter.humi = round(min(90, max(25, meter.humi + random.uniform(-1.2, 1.2))), 1)
        return {"temperature": meter.temp, "humidity": meter.humi}

    power = meter.this_power or meter.compute_power(hour)
    energy = round(power * hours, 4)          # 本周期电量 kWh（水/气/汽按 m³/t 同义）
    if energy <= 0:
        energy = round(abs(random.uniform(0.001, 0.004)), 4)
    meter.reading = round(meter.reading + energy, 4)

    if meter.kind == "electric":
        pf = round(random.uniform(0.88, 0.97), 3)
        out = {
            "energy": energy,
            "energy_reading": round(meter.reading, 3),
            "power_total": round(power, 2),
            "power_factor_total": pf,
            "frequency": round(random.uniform(49.92, 50.06), 2),
        }
        if meter.phases == 3:
            # 三相：略不平衡，但要满足「unbalance <= 2%」的验收断言
            skew = [random.uniform(-0.012, 0.012) for _ in range(3)]
            base_v = random.uniform(226.0, 233.0)
            v = [round(base_v * (1 + s), 2) for s in skew]
            p_each = power / 3.0
            i_each = [round(p_each * 1000 / x / pf, 2) if x else 0 for x in v]
            out.update({
                "voltage_a": v[0], "voltage_b": v[1], "voltage_c": v[2],
                "voltage_avg": round(sum(v) / 3, 2),
                "current_a": i_each[0], "current_b": i_each[1], "current_c": i_each[2],
                "current_avg": round(sum(i_each) / 3, 2),
                "power_a": round(p_each, 2), "power_b": round(p_each, 2), "power_c": round(p_each, 2),
                "power_factor_a": pf, "power_factor_b": pf, "power_factor_c": pf,
                "reactive_power_total": round(power * math.tan(math.acos(pf)), 2),
                "apparent_power_total": round(power / pf, 2),
                "voltage_unbalance": round(abs(max(v) - min(v)) / (sum(v) / 3) * 100, 2),
            })
        else:
            v = round(random.uniform(222.0, 234.0), 1)
            out.update({
                "voltage_a": v,
                "current_a": round(power * 1000 / v / pf, 3) if v else 0,
            })
        return out

    # 水 / 燃气 / 蒸汽
    return {
        "energy": energy,
        "energy_reading": round(meter.reading, 3),
        "power": round(power, 3),
    }


# ---------------------------------------------------------------- 发现设备
def discover(base, token, customer_id):
    """读客户名下全部设备 + 档案 + meterLevel，构建表计模型。"""
    profiles = {p["id"]["id"]: p["name"] for p in paged(base, "/api/deviceProfiles", token)}
    devices = paged(base, "/api/customer/%s/deviceInfos" % customer_id, token)

    meters = []
    for d in devices:
        did = d["id"]["id"]
        name = d.get("name") or ""
        prof_name = profiles.get((d.get("deviceProfileId") or {}).get("id"), "")
        ai = d.get("additionalInfo") or {}
        level = 0
        try:
            attrs = api(base, "/api/plugins/telemetry/DEVICE/%s/values/attributes/SERVER_SCOPE" % did, token)
            m = {x["key"]: x["value"] for x in (attrs or [])}
            level = int(m.get("meterLevel") or 0)
        except Exception:
            pass

        if prof_name in ELECTRIC_PROFILES:
            kind = "electric"
            # 相数按**档案**判断，不能按名字：演示数据里「三相园-办公区总表」
            # 挂的是「单相电能表」档案（办公照明本来就是单相负荷）。
            # 按名字会给单相表写 B/C 相键，而验收要求「单相表不写 B/C 相」。
            phases = 3 if prof_name == "电能表" else 1
            nominal = 60.0 if level == 1 else (20.0 if level == 2 else 8.0)
        elif prof_name in UTILITY_PROFILES:
            kind = UTILITY_PROFILES[prof_name]
            phases = 1
            nominal = 0.35 if kind == "gas" else (0.25 if kind == "water" else 0.18)
        elif prof_name in SENSOR_PROFILES:
            kind, phases, nominal = "sensor", 1, 0.0
        else:
            continue

        # 当前表底：接着历史往下走，不能从 0 开始（否则抄表算出「电量倒走」）
        reading = 0.0
        try:
            d2 = api(base, "/api/plugins/telemetry/DEVICE/%s/values/timeseries?keys=energy_reading&limit=1&orderBy=DESC" % did, token)
            pts = d2.get("energy_reading") or []
            if pts and pts[0].get("value") is not None:
                reading = float(pts[0]["value"])
        except Exception:
            pass

        m = Meter(name, prof_name, level, reading, nominal, kind, did,
                  phases=phases, site_id=ai.get("siteId") or "")
        # 虚拟表（additionalInfo.deviceVirtual == "virtual"）是「手工填报」页的载体，
        # 只有月首点、不写 energy_reading。给它自动上报等于自己演示的两种口径打架，
        # 还会让手工填报页的月值被小时数据淹没 —— 一律跳过。
        m.is_virtual = str(ai.get("deviceVirtual") or "").lower() == "virtual"
        meters.append(m)

        # 温度从历史接上，避免曲线从 24℃ 突然开始
        if kind == "sensor":
            try:
                d3 = api(base, "/api/plugins/telemetry/DEVICE/%s/values/timeseries?keys=temperature,humidity&limit=1&orderBy=DESC" % did, token)
                if d3.get("temperature"):
                    meters[-1].temp = float(d3["temperature"][0]["value"])
                if d3.get("humidity"):
                    meters[-1].humi = float(d3["humidity"][0]["value"])
            except Exception:
                pass

    # 建层级：**直接读平台已有的 Contains 关系**，不按名字猜。
    #
    # ★ 为什么不能自己猜（2026-10-24 实测）：
    #   第一版按「level 3 轮流挂到各 level 2」分配，结果把「空压机组」挂到了
    #   「办公区总表」下、「办公照明回路」挂到了「车间动力总表」下 ——
    #   数字仍然守恒，但演示时点开办公区会看到空压机，一眼就是错的。
    #   演示数据的层级关系本来就建好了（账单、验收都按它算），照着用即可。
    by_id = {m.device_id: m for m in meters}
    for m in meters:
        if m.kind != "electric":
            continue
        try:
            rels = api(base, "/api/relations?fromId=%s&fromType=DEVICE&relationType=Contains"
                       "&relationTypeGroup=COMMON" % m.device_id, token)
        except Exception:
            rels = []
        for r in (rels or []):
            to = r.get("to") or {}
            if to.get("entityType") != "DEVICE":
                continue
            child = by_id.get(to.get("id"))
            if child and child is not m and child.kind == "electric":
                m.children.append(child)

    return meters


# ---------------------------------------------------------------- 上报
def device_token(base, token, device_id):
    cred = api(base, "/api/device/%s/credentials" % device_id, token)
    return cred.get("credentialsId")


def push(base, token, meter, hours, dry=False):
    payload = build_payload(meter, hours)
    # 必须带 ts：不带时平台会把整包存成一个 "values" 键（2026-10-24 实测）
    body = {"ts": int(time.time() * 1000), "values": payload}
    if dry:
        return payload
    dtok = device_token(base, token, meter.device_id)
    api(base, "/api/v1/%s/telemetry" % dtok, method="POST", body=body)
    return payload


# ---------------------------------------------------------------- 主流程
def main():
    ap = argparse.ArgumentParser(description="现场演示模拟器（多能源持续上报）")
    ap.add_argument("--base", default="http://127.0.0.1:8090")
    ap.add_argument("--tenant", required=True)
    ap.add_argument("--tenant-pass", required=True)
    ap.add_argument("--customer", required=True, help="客户名称")
    ap.add_argument("--interval", type=float, default=60, help="上报间隔秒（默认 60）")
    ap.add_argument("--count", type=int, default=0, help="跑几轮，0=一直跑")
    ap.add_argument("--once", action="store_true", help="等价于 --count 1")
    ap.add_argument("--dry-run", action="store_true", help="只打印，不写库")
    ap.add_argument("--rebuild-totals", action="store_true",
                    help="每轮结束后重算资产汇总（看板「选场站」维度才更新）")
    ap.add_argument("--include-rtu", action="store_true",
                    help="连 RTU 的四台也模拟（默认跳过，真机在跑时别开）")
    ap.add_argument("--only", help="只模拟名字含该关键字的设备")
    ap.add_argument("--skip", default="", help="跳过名字含该关键字的设备（逗号分隔）")
    args = ap.parse_args()
    if args.once:
        args.count = 1

    base = args.base.rstrip("/")
    token = api(base, "/api/auth/login", method="POST",
                body={"username": args.tenant, "password": args.tenant_pass})["token"]

    custs = paged(base, "/api/customers", token)
    hit = [c for c in custs if args.customer in (c.get("title"), c.get("name"), c["id"]["id"])]
    if not hit:
        raise SystemExit("找不到客户「%s」。现有：%s" % (
            args.customer, ", ".join(c.get("title") or "?" for c in custs)))
    cid = hit[0]["id"]["id"]
    print("客户：%s（%s）" % (hit[0].get("title"), cid[:8]))

    meters = discover(base, token, cid)

    skips = [s.strip() for s in args.skip.split(",") if s.strip()]
    chosen = []
    for m in meters:
        if not args.include_rtu and m.name in RTU_DEFAULT:
            continue
        if args.only and args.only not in m.name:
            continue
        if any(s in m.name for s in skips):
            continue
        if m.is_virtual:
            continue
        chosen.append(m)

    by_kind = {}
    for m in chosen:
        by_kind[m.kind] = by_kind.get(m.kind, 0) + 1
    print("模拟设备：%d 台  (%s)" % (len(chosen),
          " / ".join("%s %d" % (k, v) for k, v in sorted(by_kind.items()))))
    if not chosen:
        raise SystemExit("没有可模拟的设备：客户名下没有表计，或全被 --skip/--only 排除了")
    if not args.include_rtu:
        print("已跳过 RTU 设备：%s（真机在跑，避免两个源同时写表底）" % ", ".join(sorted(RTU_DEFAULT)))

    hours = args.interval / 3600.0
    rounds = 0
    fail = 0
    print("-" * 96)
    try:
        while True:
            rounds += 1
            t0 = time.time()
            n_ok = 0
            for m in chosen:
                try:
                    p = push(base, token, m, hours, dry=args.dry_run)
                    n_ok += 1
                    if rounds == 1 or args.count == 1:
                        # 首轮逐台打印，之后只打汇总（否则日志太长）
                        main_key = ("power_total" if m.kind == "electric"
                                    else "temperature" if m.kind == "sensor" else "power")
                        print("  %-36s %-18s %s" % (m.name[:34], main_key, p.get(main_key)))
                except Exception as e:
                    fail += 1
                    print("  ✗ %-34s %s" % (m.name[:34], e))

            if args.rebuild_totals and not args.dry_run:
                try:
                    r = api(base, "/api/energy/asset-totals/rebuild", token, method="POST",
                            body={"customerId": cid, "days": 2})
                    print("  ↻ 资产汇总已刷新（%s 个资产）" % (r or {}).get("assetsWritten", "?"))
                except Exception as e:
                    print("  ! 资产汇总刷新失败：%s" % e)

            print("[%s] 第 %d 轮：%d/%d 成功，耗时 %.1fs%s" % (
                time.strftime("%H:%M:%S"), rounds, n_ok, len(chosen),
                time.time() - t0, "（dry-run，未写库）" if args.dry_run else ""))
            if args.count and rounds >= args.count:
                break
            time.sleep(max(1.0, args.interval - (time.time() - t0)))
    except KeyboardInterrupt:
        print("\n已停止（Ctrl-C）")

    print("-" * 96)
    print("完成 %d 轮，失败 %d 次" % (rounds, fail))
    if fail:
        print("有失败项，按上面的 ✗ 查（常见：设备 token 取不到 / 平台不可达）")
    return 1 if fail else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as e:
        print("✗ %s" % e, file=sys.stderr)
        sys.exit(1)
