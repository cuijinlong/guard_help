#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RTU 模拟上报（2026-11-02）

<h3>干什么</h3>
让 ED2-Gateway 下的 7 台模拟设备持续产生新鲜数据，覆盖：
三相电能质量、水、燃气、蒸汽、热力、环境、可控设备。

真实 RTU（ED1-Gateway）继续由板子自己上报，本脚本**不碰**那三台 ——
同一台表被两个源同时写会让表底跳变，抄表判 abnormal。

<h3>为什么用 REST 而不是 MQTT</h3>
本脚本跑在服务器上，直接调 `POST /api/plugins/telemetry/{实体}/timeseries/{scope}`
最省事，也不需要网关注册、不用管 v1/gateway/telemetry 的报文格式。
**键名用平台标准名**（voltage_a / energy_reading …），因为不走规则链翻译 ——
翻译是给硬件 RTU 准备的（它发厂家代号）。

<h3>数据要点（写错会让看板空白或抄表失败）</h3>
- `energy_reading` **必须单调递增** —— 抄表按 (本期 − 上期) × 倍率 算账期用量
- 父表增量 >= 子表之和（本脚本没有层级，单表独立）
- 三相电压落在 GB/T 12325 的 220V ±7%（204.6~235.4V）
- 不平衡度 ≤ 2%（GB/T 15543）
- 频率 49.8~50.2 Hz（GB/T 15945）

<h3>用法</h3>
```bash
python3 scripts/31-rtu-simulate.py --once          # 发一轮（验收/自检用）
python3 scripts/31-rtu-simulate.py --interval 30   # 持续跑，Ctrl-C 停
python3 scripts/31-rtu-simulate.py --dry-run       # 只算不发
```
"""

import argparse
import json
import math
import random
import sys
import time
import urllib.error
import urllib.request

# 与 30-rtu-env-init.py 的白名单一致：这几台由真实 RTU 出数，不碰
REAL_DEVICES = {'ED1-Gateway', 'PowerMeter-DDSU666', 'Sensor-HZ8706', 'Relay-8CH'}


def api(base, path, token, method='GET', body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, method=method)
    if token:
        req.add_header('X-Authorization', 'Bearer ' + token)
    if data:
        req.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            t = r.read().decode()
            return r.status, (json.loads(t) if t.strip().startswith(('{', '[')) else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]


def paged(base, path, token):
    out, page = [], 0
    while True:
        sep = '&' if '?' in path else '?'
        _, d = api(base, '%s%spageSize=500&page=%d' % (path, sep, page), token)
        if not isinstance(d, dict):
            break
        out.extend(d.get('data') or [])
        if not d.get('hasNext'):
            break
        page += 1
    return out


# ---------------------------------------------------------------- 负载曲线
def load_factor(hour, kind):
    """一天内的负载系数，让曲线有形而不是一条直线（只影响大小，不影响单调性）"""
    if kind == 'elec':
        c = [0.35, 0.32, 0.30, 0.30, 0.33, 0.40, 0.55, 0.72, 0.88, 0.95,
             0.92, 0.85, 0.78, 0.86, 0.94, 0.96, 0.90, 0.80, 0.70, 0.62,
             0.55, 0.48, 0.42, 0.38]
    elif kind == 'steam':
        c = [0.20, 0.18, 0.18, 0.18, 0.20, 0.30, 0.55, 0.80, 0.95, 0.98,
             0.92, 0.60, 0.45, 0.85, 0.96, 0.94, 0.85, 0.70, 0.50, 0.35,
             0.28, 0.25, 0.22, 0.20]
    elif kind == 'gas':
        c = [0.15, 0.12, 0.12, 0.12, 0.15, 0.35, 0.75, 0.85, 0.55, 0.35,
             0.30, 0.65, 0.85, 0.50, 0.30, 0.28, 0.45, 0.70, 0.80, 0.55,
             0.35, 0.25, 0.20, 0.17]
    elif kind == 'heat':
        # 热力：早晚供暖高峰，中午最低
        c = [0.85, 0.88, 0.90, 0.92, 0.88, 0.75, 0.60, 0.50, 0.42, 0.35,
             0.30, 0.28, 0.26, 0.30, 0.34, 0.38, 0.45, 0.55, 0.68, 0.78,
             0.84, 0.86, 0.85, 0.84]
    else:
        c = [0.25, 0.22, 0.20, 0.20, 0.22, 0.35, 0.62, 0.80, 0.88, 0.85,
             0.75, 0.70, 0.72, 0.80, 0.86, 0.84, 0.78, 0.70, 0.62, 0.55,
             0.46, 0.38, 0.32, 0.28]
    return c[int(hour) % 24]


class Sim:
    """一台模拟设备的运行状态（表底要在两次上报之间累加）"""

    def __init__(self, dev, kind):
        self.id = dev['id']['id']
        self.name = dev['name']
        self.kind = kind
        self.reading = None      # 首次从平台读回来，避免重启后表底倒流

    def payload(self, hours):
        hour = time.localtime().tm_hour
        f = load_factor(hour, self.kind)

        if self.kind == 'elec3':
            return self._elec3(f, hours)
        if self.kind == 'water':
            return self._utility(f, hours, 0.35, 'm3')
        if self.kind == 'gas':
            return self._utility(f, hours, 0.18, 'm3', pressure=True)
        if self.kind == 'steam':
            return self._utility(f, hours, 0.12, 't', temp_pressure=True)
        if self.kind == 'heat':
            return self._heat(f, hours)
        if self.kind == 'ahu':
            return self._ahu(f)
        if self.kind == 'breaker':
            return self._breaker(f)
        return {}

    # ---- 三相电表：含电能质量全场景 ----
    def _elec3(self, f, hours):
        power = round(180 * f * random.uniform(0.95, 1.05), 2)          # kW
        energy = round(power * hours, 4)
        if energy <= 0:
            energy = round(random.uniform(0.001, 0.004), 4)
        if self.reading is None:
            self.reading = round(random.uniform(12000, 15000), 3)
        self.reading = round(self.reading + energy, 3)
        pf = round(random.uniform(0.90, 0.97), 3)

        # GB/T 12325：220V ±7% → 204.6~235.4；留余量取 214~231
        base_v = random.uniform(218.0, 229.0)
        sketch = [random.uniform(-0.006, 0.006) for _ in range(3)]
        v = [round(base_v * (1 + s), 2) for s in sketch]
        p_each = power / 3.0
        cur = [round(p_each * 1000 / x / pf, 2) if x else 0 for x in v]
        vavg = round(sum(v) / 3, 2)

        # 不平衡度 = 最大偏差 / 平均，GB/T 15543 ≤ 2%
        unb = round(max(abs(x - vavg) for x in v) / vavg * 100, 2)
        # 序分量：正序 ≈ 平均，负序 ≈ 不平衡引起的逆向分量，零序三相四线很小
        u1 = round(vavg, 2)
        u2 = round(vavg * unb / 100 * 0.6, 2)
        u0 = round(vavg * random.uniform(0.0005, 0.002), 2)
        iavg = round(sum(cur) / 3, 2)

        freq = round(random.uniform(49.95, 50.05), 2)
        out = {
            'energy': energy,
            'energy_reading': self.reading,
            'power_total': power,
            'reactive_power_total': round(power * math.tan(math.acos(pf)), 2),
            'apparent_power_total': round(power / pf, 2),
            'power_factor_total': pf,
            'frequency': freq,
            'voltage_a': v[0], 'voltage_b': v[1], 'voltage_c': v[2],
            'voltage_avg': vavg,
            'current_a': cur[0], 'current_b': cur[1], 'current_c': cur[2],
            'current_avg': iavg,
            'power_a': round(p_each, 2), 'power_b': round(p_each, 2),
            'power_c': round(p_each, 2),
            # 电能质量：电压偏差（相对 220V 额定）
            'voltage_deviation_a': round((v[0] - 220) / 220 * 100, 2),
            'voltage_deviation_b': round((v[1] - 220) / 220 * 100, 2),
            'voltage_deviation_c': round((v[2] - 220) / 220 * 100, 2),
            'frequency_deviation': round(freq - 50.0, 3),
            # 不平衡与序分量
            'voltage_unbalance': unb,
            'current_unbalance': round(random.uniform(0.2, 1.8), 2),
            'voltage_seq_positive': u1,
            'voltage_seq_negative': u2,
            'voltage_seq_zero': u0,
            'current_seq_positive': round(iavg, 2),
            'current_seq_negative': round(iavg * random.uniform(0.005, 0.02), 3),
            'current_seq_zero': round(iavg * random.uniform(0.002, 0.01), 3),
            # THD（GB/T 14549 电压 ≤5%，电流按负载）
            'voltage_thd_a': round(random.uniform(1.2, 3.8), 2),
            'voltage_thd_b': round(random.uniform(1.2, 3.8), 2),
            'voltage_thd_c': round(random.uniform(1.2, 3.8), 2),
            'current_thd_a': round(random.uniform(3.0, 12.0), 2),
            'current_thd_b': round(random.uniform(3.0, 12.0), 2),
            'current_thd_c': round(random.uniform(3.0, 12.0), 2),
            # 闪变（GB/T 12326：Pst ≤ 1.0，Plt ≤ 0.8）
            'flicker_pinst': round(random.uniform(0.15, 0.95), 2),
            'flicker_pst': round(random.uniform(0.20, 0.90), 2),
            'flicker_plt': round(random.uniform(0.15, 0.75), 2),
        }
        # 分次谐波：3/5/7/9/11/13 次，含率随次数递减
        for hk, scale in ((3, 1.8), (5, 1.2), (7, 0.8), (9, 0.5), (11, 0.35), (13, 0.25)):
            out['voltage_harmonic_%d' % hk] = round(random.uniform(0.1, scale), 2)
            out['current_harmonic_%d' % hk] = round(random.uniform(0.5, scale * 3), 2)
        return out

    # ---- 水 / 气 / 汽 ----
    def _utility(self, f, hours, base_flow, unit, pressure=False, temp_pressure=False):
        flow = round(base_flow * f * random.uniform(0.9, 1.1), 3)
        energy = round(flow * hours, 4)
        if energy <= 0:
            energy = round(random.uniform(0.0005, 0.002), 4)
        if self.reading is None:
            self.reading = round(random.uniform(2000, 5000), 3)
        self.reading = round(self.reading + energy, 3)
        out = {'power': flow, 'energy_reading': self.reading, 'energy': energy}
        if pressure:
            out['gas_pressure'] = round(random.uniform(1.8, 3.2), 2)
        if temp_pressure:
            out['steam_temp'] = round(random.uniform(160, 185), 1)
            out['steam_pressure'] = round(random.uniform(0.6, 0.9), 2)
        return out

    # ---- 热力 ----
    def _heat(self, f, hours):
        pf = round(420 * f * random.uniform(0.94, 1.06), 2)      # 热功率 kW
        gj = round(pf * 3.6 * hours / 1000, 4)                    # kW·h → GJ
        if gj <= 0:
            gj = round(random.uniform(0.0001, 0.0005), 4)
        if self.reading is None:
            self.reading = round(random.uniform(800, 2000), 3)
        self.reading = round(self.reading + gj, 3)
        supply = round(random.uniform(75, 85), 1)
        return {
            'heat_power': pf,
            'heat_flow': round(pf / 4.2 / max(1, (supply - 50)) * 3.6, 2),
            'supply_temp': supply,
            'return_temp': round(supply - random.uniform(10, 18), 1),
            'energy_reading': self.reading,
            'energy': gj,
        }

    # ---- 新风机组（可控）----
    def _ahu(self, f):
        return {
            'temperature': round(22 + random.uniform(-2, 3), 1),
            'humidity': round(48 + random.uniform(-8, 8), 1),
            'power': 1,          # 运行模式：1=自动
            'frequency': round(35 + f * 10 + random.uniform(-2, 2), 1),
        }

    # ---- 智能空开（可控）----
    def _breaker(self, f):
        return {
            'power': 1,          # 1=合闸
            'energy': round(random.uniform(0, 0.01), 4),
            'current_a': round(12 * f * random.uniform(0.9, 1.1), 2),
        }


# ---------------------------------------------------------------- 设备分类
def classify(name, profile):
    if name.startswith('PowerMeter-3P'):
        return 'elec3'
    if 'Water' in name:
        return 'water'
    if 'Gas' in name:
        return 'gas'
    if 'Steam' in name:
        return 'steam'
    if 'Heat' in name:
        return 'heat'
    if 'AHU' in name:
        return 'ahu'
    if 'Breaker' in name:
        return 'breaker'
    return None


def push(base, token, sim, hours, dry):
    payload = sim.payload(hours)
    if dry:
        return payload
    code, body = api(base, '/api/plugins/telemetry/DEVICE/%s/timeseries/SERVER_SCOPE' % sim.id,
                     token, 'POST', payload)
    if code not in (200, 204):
        raise RuntimeError('HTTP %s %s' % (code, body))
    return payload


def latest_reading(base, token, dev_id, key='energy_reading'):
    """读设备最近一次的表底。没有就返回 None。"""
    code, r = api(base,
                  '/api/plugins/telemetry/DEVICE/%s/values/timeseries?keys=%s&limit=1&orderBy=DESC'
                  % (dev_id, key), token)
    if code != 200 or not isinstance(r, dict):
        return None
    arr = r.get(key) or []
    if not arr:
        return None
    try:
        return float(arr[0]['value'])
    except (KeyError, TypeError, ValueError):
        return None


def backfill(base, token, sims, days, dry):
    """回填历史遥测：每小时一个点，覆盖最近 N 天。

    <p>为什么需要：新初始化的环境只有刚才那几轮实时数据，
    看板的日/周/月曲线全是空的 —— 客户第一眼看到的就是「系统没数据」。
    演示数据（demo-data）也是同样问题：一次性快照，几小时后全判陈旧。

    <p>表底必须单调：从「当前读数 - days*24*每小时用量」倒推起点，
    再逐小时累加，保证整条曲线严格递增（抄表判 abnormal 的判据）。
    """
    import datetime
    now = time.time()
    total = 0
    for sim in sims:
        # ★ 起点必须从**平台上的当前表底**往回推。
        #
        #   曾经的写法是模拟器内部计数（首次为 1000），跟平台上的真实值无关 ——
        #   回填写的是 1000~4000，而实时点已经是 13995，接上去就是一次倒流，
        #   抄表判 abnormal（实测 2026-11-02，每台表都有 1 次）。
        #
        #   读不到当前值（新设备）时才退回 1000。
        probe = sim.payload(1.0)
        per_hour = float(probe.get('energy') or 0.0005)
        cur = latest_reading(base, token, sim.id) if not dry else None
        if cur is None:
            cur = float(sim.reading or 1000)
        # 留 10% 余量：回填期用量按 per_hour 估，实际有峰谷波动
        start_reading = cur - per_hour * 24 * days * 1.1
        start_reading = max(start_reading, 1.0)
        sim.reading = round(start_reading, 3)

        points = []
        for d in range(days, 0, -1):
            for h in range(24):
                ts = int((now - d * 86400 + h * 3600) * 1000)
                payload = sim.payload(1.0)
                points.append((ts, payload))
        if dry:
            total += len(points)
            continue
        # 分批写：一次几十个点，太多会超时
        BATCH = 200
        for i in range(0, len(points), BATCH):
            chunk = points[i:i + BATCH]
            body = []
            for ts, payload in chunk:
                # TB 的 attributes/timeseries 批量格式：{"ts": ms, "values": {...}}
                body.append({'ts': ts, 'values': payload})
            code, r = api(base, '/api/plugins/telemetry/DEVICE/%s/timeseries/SERVER_SCOPE'
                          % sim.id, token, 'POST', body)
            if code not in (200, 204):
                raise RuntimeError('回填 %s 失败 HTTP %s %s' % (sim.name, code, str(r)[:120]))
            total += len(chunk)
    return total


def main():
    ap = argparse.ArgumentParser(description='RTU 模拟上报（ED2-Gateway 下的 7 台设备）')
    ap.add_argument('--base', default='http://127.0.0.1:8090')
    ap.add_argument('--tenant', default='tenant@126.com')
    ap.add_argument('--tenant-pass', default='12345678')
    ap.add_argument('--interval', type=int, default=0,
                    help='持续运行的间隔秒数（0 = 只跑一轮）')
    ap.add_argument('--once', action='store_true', help='只发一轮')
    ap.add_argument('--hours', type=float, default=None,
                    help='本周期时长（小时），默认按 --interval 推算，最少 5 分钟')
    ap.add_argument('--dry-run', action='store_true', help='只算不发')
    ap.add_argument('--backfill-days', type=int, default=0,
                    help='回填最近 N 天的历史数据（每小时一个点）。'
                         '演示前跑一次，看板立刻有曲线，不用等数据攒够')
    ap.add_argument('--customer', default=None,
                    help='只给这个客户名下的模拟设备发数据（默认全部）。'
                         '多客户同租户时建议指定，避免一个客户的数据串到另一个')
    args = ap.parse_args()

    _, r = api(args.base, '/api/auth/login', None, 'POST',
               {'username': args.tenant, 'password': args.tenant_pass})
    token = r['token']

    profiles = {p['id']['id']: p['name'] for p in paged(args.base, '/api/deviceProfiles', token)}
    devices = [d for d in paged(args.base, '/api/tenant/devices', token)
               if d['name'] not in REAL_DEVICES]

    if args.customer:
        cust = next((c for c in paged(args.base, '/api/customers', token)
                     if c.get('title') == args.customer), None)
        if cust is None:
            print('找不到客户「%s」' % args.customer)
            return 1
        cid = cust['id']['id']
        devices = [d for d in devices if (d.get('customerId') or {}).get('id') == cid]
        print('限定客户: %s (%s)' % (args.customer, cid[:8]))

    sims = []
    for d in devices:
        kind = classify(d['name'], profiles.get(d['deviceProfileId']['id']))
        if kind:
            sims.append(Sim(d, kind))

    if not sims:
        print('没有可模拟的设备，请先跑 30-rtu-env-init.py')
        return 1

    # 回填历史（演示前跑一次，让看板立刻有曲线）
    if args.backfill_days > 0:
        print('\n回填最近 %d 天历史（每小时一个点）…' % args.backfill_days)
        n = backfill(args.base, token, sims, args.backfill_days, args.dry_run)
        print('  回填 %d 个数据点%s' % (n, '（dry-run）' if args.dry_run else ''))
        if args.once:
            return 0

    hours = args.hours if args.hours is not None else max(args.interval, 300) / 3600.0
    print('模拟设备 %d 台，本周期 %.4f 小时' % (len(sims), hours))
    for s in sims:
        print('  %-20s %s' % (s.name, s.kind))

    rounds = 0
    while True:
        rounds += 1
        ok = fail = 0
        t0 = time.time()
        for s in sims:
            try:
                payload = push(args.base, token, s, hours, args.dry_run)
                ok += 1
                if args.dry_run or args.once or args.interval == 0:
                    keys = [k for k in payload if k in
                            ('energy_reading', 'power_total', 'voltage_a', 'voltage_unbalance',
                             'flicker_pst', 'heat_power', 'power')]
                    print('  %-20s %s' % (s.name, {k: payload[k] for k in keys}))
            except Exception as e:
                fail += 1
                print('  ✗ %-20s %s' % (s.name, e))

        print('[第 %d 轮] 成功 %d / 失败 %d（%.1fs）' % (rounds, ok, fail, time.time() - t0))

        if args.once or args.interval <= 0:
            return 0 if fail == 0 else 1
        time.sleep(args.interval)


if __name__ == '__main__':
    sys.exit(main())
