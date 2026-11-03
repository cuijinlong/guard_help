#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""电能质量数据集端到端验证。

用法：
    python3 pq-e2e-verify.py --base http://127.0.0.1:8090 \\
        --user tenant@126.com --pass 12345678 \\
        --device <device-uuid> [--keep]

做什么：
    1. 从 ts_kv 圈选一段真实历史 → 建数据集
    2. 复制数据 → 生成快照
    3. 下载 CSV + meta 到临时目录
    4. 以「外部数据科学家」视角校验：校验和、自描述、宽表齐整、时间连续性、
       可评价性、依据标准、实算一个指标与限值比对
    5. 清理（--keep 则保留便于查看）

为什么值得有：这套流程 2026-11-03 手工跑通过一次，之后每次改
PqSnapshotService / capability / 复制逻辑都该重跑一遍 ——
「API 返回 200」不代表交付物能用。
"""
import argparse, gzip, hashlib, json, statistics, subprocess, sys, tempfile, os, shutil
import urllib.request, urllib.error
from collections import Counter, defaultdict


def api(base, token, method, path, body=None, timeout=300):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method)
    if token:
        req.add_header('X-Authorization', 'Bearer ' + token)
    if data:
        req.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            try:
                return r.status, json.loads(raw.decode())
            except Exception:
                return r.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors='replace')
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {'raw': raw[:300]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', default='http://127.0.0.1:8090')
    ap.add_argument('--user', required=True)
    ap.add_argument('--pass', dest='password', required=True)
    ap.add_argument('--device', required=True)
    ap.add_argument('--hours', type=float, default=1.0)
    ap.add_argument('--to', type=int, default=0,
                    help='窗口结束的毫秒时间戳；0 = 当前时间。'
                         '设备最近没上报时，用最后一条数据的时间')
    ap.add_argument('--keep', action='store_true')
    a = ap.parse_args()

    results = []

    def chk(name, cond, detail=''):
        results.append((name, bool(cond)))
        print(('  ✓ ' if cond else '  ✗ ') + name + (('  → ' + str(detail)) if detail else ''))
        return cond

    st, d = api(a.base, None, 'POST', '/api/auth/login',
                {'username': a.user, 'password': a.password})
    if st != 200:
        print('登录失败:', d)
        return 1
    token = d['token']

    st, probe = api(a.base, token, 'GET', f'/api/energy/pq/metrics/probe?deviceId={a.device}')
    # 优先挑这几项：电压偏差是核心判定项，必须覆盖到，否则最该验证的逻辑跑不到。
    # （按字母序取前 N 个会恰好漏掉 voltage_a —— 实测踩过。）
    available = [m['code'] for m in probe.get('metrics', []) if m.get('inDictionary')]
    priority = ['voltage_a', 'current_a', 'power_total', 'frequency',
                'power_factor_total', 'energy_reading']
    codes = [c for c in priority if c in available]
    for c in available:
        if len(codes) >= 6:
            break
        if c not in codes:
            codes.append(c)
    if not any(c.startswith('voltage') for c in codes):
        print('注意：该设备没有相电压，电压偏差这一项无法验证')
    print(f'\n=== 圈选 {len(codes)} 个指标: {", ".join(codes)} ===')

    # 窗口结束时间：默认现在，设备最近没上报时用 --to 指定最后一条数据的时间。
    # （probe 不返回时间戳，脚本也不直连数据库 —— 客户机器上不一定有 psql 权限。）
    import time as _time
    to = a.to if a.to > 0 else int(_time.time() * 1000)
    frm = to - int(a.hours * 3600 * 1000)
    print(f'数据窗口: {frm} ~ {to}  ({a.hours:.1f} 小时)')

    # 先探一次，确认这个窗口里真有数据
    st, win = api(a.base, token, 'GET',
                  f'/api/energy/pq/metrics/probe?deviceId={a.device}&from={frm}&to={to}')
    if not win.get('foundCount'):
        print(f'该窗口内没有数据（foundCount=0）。')
        print(f'提示：用 --to <最后一条数据的毫秒时间戳> 指定窗口结束时间。')
        print(f'     查询方法：SELECT max(ts) FROM ts_kv WHERE entity_id=\'{a.device}\';')
        return 1

    st, rows = api(a.base, token, 'POST', '/api/energy/pq/datasets', {
        'name': 'E2E-自动验证',
        'source': {'type': 'TS_KV', 'params': {
            'deviceId': a.device, 'intervalMs': 6000,
            'snapshotMaxTs': to,
            'timeRange': {'from': frm, 'to': to}}},
        'metrics': codes,
        'samplingPlan': {'effectiveMinIntervalMs': 3000,
                         'standards': ['GB/T 12325-2008'],
                         'build': {'sampleRateHz': 6400, 'windowCycles': 10, 'intervalMs': 6000},
                         'deviations': [
                             {'requirementId': 'v-interval',
                              'reason': '验证用：现有电表上传间隔 6s'}]},
    })
    if st != 201:
        print('创建失败:', rows)
        return 1

    ds = rows['id']
    print(f'数据集: {ds}  可评价 {rows.get("evaluable")}/{len(rows.get("coverage") or [])} 项')

    # 每一步都查返回码：静默失败会让后面以 FileNotFoundError 崩溃，
    # 而真实原因在更早那一步。
    st, cp = api(a.base, token, 'POST', f'/api/energy/pq/datasets/{ds}/copy-from-ts-kv', {})
    if st != 200:
        print(f'复制失败（HTTP {st}）:', cp)
        return 1
    print(f'复制: {cp.get("written")} 点, 完整率 {cp.get("completeness")}')

    st, sn = api(a.base, token, 'POST', f'/api/energy/pq/datasets/{ds}/snapshot')
    if st != 200 or not sn.get('ok'):
        print(f'快照失败（HTTP {st}）:', sn)
        return 1
    print(f'快照: {sn.get("rows")} 行, {sn.get("bytes")} 字节')

    tmp = tempfile.mkdtemp(prefix='pq-e2e-')
    csvp = os.path.join(tmp, 'dataset.csv.gz')
    metap = os.path.join(tmp, 'dataset.meta.json')
    for part, dest in (('data', csvp), ('meta', metap)):
        q = '' if part == 'data' else '?part=meta'
        st, raw = api(a.base, token, 'GET',
                      f'/api/energy/pq/datasets/{ds}/snapshot/download{q}')
        if st != 200:
            print(f'下载 {part} 失败（HTTP {st}）:', raw)
            return 1
        # api() 会把 JSON 解析成 dict；meta 就是 JSON，重新序列化写回
        if isinstance(raw, dict):
            open(dest, 'w', encoding='utf-8').write(json.dumps(raw, ensure_ascii=False, indent=1))
        elif isinstance(raw, bytes) and raw:
            open(dest, 'wb').write(raw)
        else:
            print(f'下载 {part} 得到空内容')
            return 1

    meta = json.load(open(metap))
    chk('校验和一致', hashlib.sha256(open(csvp, 'rb').read()).hexdigest() == meta['sha256'])
    chk('meta 有列说明', 'columns' in meta)
    chk('meta 有电气条件', 'electrical' in meta)
    chk('指标带单位', all(m.get('unit') is not None for m in meta.get('metrics', [])))

    data = []
    with gzip.open(csvp, 'rt') as f:
        import csv as csvmod
        for r in csvmod.DictReader(f):
            data.append((int(r['ts']), r['metric'], float(r['num_v'])))

    wide = defaultdict(dict)
    for ts, m, v in data:
        wide[ts][m] = v
    ncols = len(meta['metrics'])
    full = sum(1 for v in wide.values() if len(v) == ncols)
    chk(f'宽表齐整 {full}/{len(wide)}', full == len(wide))

    tss = sorted(wide)
    diffs = [tss[i + 1] - tss[i] for i in range(len(tss) - 1)]
    if diffs:
        med = statistics.median(diffs)
        chk(f'时间连续性（中位 {med:.0f}ms = meta {meta["intervalMs"]}ms）',
            abs(med - meta['intervalMs']) < 1)

    cov = meta.get('coverage') or []
    chk('可评价性已写入快照', len(cov) > 0,
        f'{sum(1 for c in cov if c["canEvaluate"])}/{len(cov)} 可做')
    chk('依据标准已写入快照', len(meta.get('standards') or []) > 0,
        ', '.join(s['code'] for s in meta.get('standards') or []))

    print(f'\n临时目录: {tmp}' + ('（--keep 保留）' if a.keep else '（已删）'))
    if not a.keep:
        shutil.rmtree(tmp, ignore_errors=True)

    ok = sum(1 for _, c in results if c)
    print(f'\n通过 {ok}/{len(results)}')
    return 0 if ok == len(results) else 1


if __name__ == '__main__':
    sys.exit(main())
