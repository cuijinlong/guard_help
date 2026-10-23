#!/usr/bin/env python3
"""
客户视角权限探针（customer surface probe）

为什么需要它
------------
之前的验收全是「用租户或客户 token 调我认为重要的接口」。
但客户打开页面时，是**看板部件**在发请求 —— 部件会去读租户级主数据
（能源品种、费率模板、字典），客户没有权限，于是 403、图表空白。

这类问题在 API 级断言里永远看不见：断言不调那些 URL。
本脚本改为「把客户会触发的请求全打一遍」，任何 4xx 都算缺陷。

用法
----
    python3 27-customer-surface-probe.py --base http://127.0.0.1:8090 \
        --tenant tenant@126.com --tenant-pass 12345678 \
        --customer customer@126.com --customer-pass 12345678

    --json    机器可读输出
    --strict  有任何 4xx 时退出码 2（供验收脚本调用）

判定口径
--------
· 2xx / 404（资源不存在，属正常）→ 通过
· 401 / 403                      → **缺陷**：客户读不到自己的页面数据
· 5xx                            → **缺陷**：服务端错误
· 200 + 空数组                   → **不算通过**，见下方「语义断言」

语义断言（2026-10-23 新增）
---------------------------
上一版只判 4xx/5xx，结果 295 条全通、客户打开「能耗概览」却是 4 张 0.0 卡片
和一个「所选范围内无数据」的日历。原因是部件把「品种资产」当取数实体，
接口返回 200 + {}，被当成了通过。所以补两类真实用户能看见的断言：

  S1 设备有遥测 → 所属场站的 energy_total 必须非空
     （否则设备页有数、场站页和概览页是 0）
  S2 看板 alias 不能把品种/字典资产当取数实体
     （它们只有属性没有遥测，取数必然为空；子树还跨同租户全部客户）
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone


class Api:
    def __init__(self, base, token=None):
        self.base = base.rstrip('/')
        self.token = token

    def call(self, path, method='GET', body=None):
        url = self.base + path
        data = json.dumps(body).encode() if body is not None else None
        headers = {'Content-Type': 'application/json'}
        if self.token:
            headers['X-Authorization'] = 'Bearer ' + self.token
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                try:
                    return r.status, json.loads(raw) if raw else None
                except Exception:
                    return r.status, raw[:200]
        except urllib.error.HTTPError as e:
            body_text = e.read().decode('utf-8', 'ignore')[:300]
            return e.code, body_text
        except Exception as e:
            return 0, str(e)


def login(base, user, password):
    api = Api(base)
    code, data = api.call('/api/auth/login', 'POST', {'username': user, 'password': password})
    if code != 200 or not isinstance(data, dict) or 'token' not in data:
        print(f'登录失败 {user}: {code} {data}', file=sys.stderr)
        sys.exit(1)
    return data['token']


def page_all(api, path, limit=500):
    """把分页接口的数据全取回来（客户名下的资产/设备可能超过一页）"""
    out, page = [], 0
    while True:
        sep = '&' if '?' in path else '?'
        code, data = api.call(f'{path}{sep}pageSize={limit}&page={page}')
        if code != 200 or not isinstance(data, dict):
            break
        rows = data.get('data') or []
        out.extend(rows)
        if not data.get('hasNext'):
            break
        page += 1
        if page > 20:
            break
    return out


def build_probes(api):
    """构造「客户打开页面会触发的请求」清单。

    分三类：
      A. 客户自己的资源（必须可读）
      B. 客户看板里引用的实体（必须可读）
      C. 部件共用的主数据（品种/字典/费率模板 —— 客户页面也要用）
    """
    probes = []          # (分组, 说明, path)

    def add(group, label, path):
        probes.append((group, label, path))

    assets = page_all(api, '/api/user/assets')
    devices = page_all(api, '/api/user/devices')
    dashboards = page_all(api, '/api/user/dashboards')

    print(f'客户名下：资产 {len(assets)} / 设备 {len(devices)} / 看板 {len(dashboards)}',
          file=sys.stderr)

    # ---- A. 客户自己的资源 ----
    for d in devices[:40]:
        did = d['id']['id']
        add('A 自有设备', d.get('name', did)[:26],
            f'/api/plugins/telemetry/DEVICE/{did}/values/timeseries'
            f'?keys=energy,energy_reading,power_total&startTs=0&endTs={2**62 // 1000}&limit=5')
        add('A 自有设备', d.get('name', did)[:26] + ' · 属性',
            f'/api/plugins/telemetry/DEVICE/{did}/values/attributes/SERVER_SCOPE')

    for a in assets[:60]:
        aid = a['id']['id']
        atype = a.get('type') or ''
        add('A 自有资产', f'{atype} {a.get("name", aid)[:22]} · 遥测',
            f'/api/plugins/telemetry/ASSET/{aid}/values/timeseries'
            f'?keys=energy_total,water_total,energy_day&startTs=0&endTs={2**62 // 1000}&limit=5')
        add('A 自有资产', f'{atype} {a.get("name", aid)[:22]} · 属性',
            f'/api/plugins/telemetry/ASSET/{aid}/values/attributes/SERVER_SCOPE')
        add('A 自有资产', f'{atype} {a.get("name", aid)[:22]} · 关系',
            f'/api/relations?fromId={aid}&fromType=ASSET&relationType=Contains')

    for db in dashboards[:25]:
        did = db['id']['id']
        add('A 自有看板', db.get('title', did)[:24],
            f'/api/dashboard/{did}')

    # ---- B. 客户看板里引用到的实体 id（这是 403 的真正来源）----
    #
    # 看板配置里会写死品种资产 id、字典根 id。部件按这些 id 去读属性/关系，
    # 客户没有租户级读权限 → 403。把它们全抽出来逐个探。
    seen_ids = set()
    for db in dashboards:
        did = db['id']['id']
        code, full = api.call(f'/api/dashboard/{did}')
        if code != 200 or not isinstance(full, dict):
            continue
        blob = json.dumps(full, ensure_ascii=False)
        for key in ('"id":"', ):
            pass
        import re
        # 看板配置里的所有 uuid
        for m in re.finditer(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', blob):
            seen_ids.add(m.group(0))
        # 看板里的 alias 指向的实体（也走一遍）
        add('B 看板引用', db.get('title', '')[:22] + ' · config', f'/api/dashboard/{did}')

    own = {a['id']['id'] for a in assets} | {d['id']['id'] for d in devices} | {x['id']['id'] for x in dashboards}
    foreign = sorted(seen_ids - own)
    print(f'看板配置里引用了 {len(seen_ids)} 个 uuid，其中非客户自有 {len(foreign)} 个',
          file=sys.stderr)
    for fid in foreign[:60]:
        add('B 看板引用', fid[:8] + ' · 资产属性',
            f'/api/plugins/telemetry/ASSET/{fid}/values/attributes/SERVER_SCOPE')
        add('B 看板引用', fid[:8] + ' · 关系',
            f'/api/relations?fromId={fid}&fromType=ASSET&relationType=Contains')

    # ---- C. 部件共用的主数据 ----
    add('C 主数据', '指标参数（客户版接口）', '/api/energy/metric-params')

    # ---- C2. 部件「运行时」拿到的 id（最容易漏的一类）----
    #
    # 旧版部件不调 metric-params，而是从数据源绑定的资产拿 kindId，
    # 然后去读那个资产的 SERVER_SCOPE 属性（paramDict）和 Contains 关系。
    # 这些 id 不在看板 config 里，只有跑起来才知道 —— 必须显式探。
    code, mp = api.call("/api/energy/metric-params")
    if code == 200 and isinstance(mp, dict):
        kind_ids = []
        lib = mp.get('libraryId')
        if lib:
            kind_ids.append(('字典根', lib))
        for k in (mp.get('kinds') or []):
            if k.get('id'):
                kind_ids.append((k.get('name') or k['id'][:8], k['id']))
        print(f'metric-params 给出 {len(kind_ids)} 个主数据 id（品种/字典根）', file=sys.stderr)
        for name, kid in kind_ids:
            add('C2 部件运行时 id', f'{name} · paramDict',
                f'/api/plugins/telemetry/ASSET/{kid}/values/attributes/SERVER_SCOPE?keys=paramDict')
            add('C2 部件运行时 id', f'{name} · 全属性',
                f'/api/plugins/telemetry/ASSET/{kid}/values/attributes/SERVER_SCOPE')
            add('C2 部件运行时 id', f'{name} · Contains 关系',
                f'/api/relations?fromId={kid}&fromType=ASSET&relationType=Contains')
            add('C2 部件运行时 id', f'{name} · 资产详情',
                f'/api/asset/{kid}')
    add('C 主数据', '可见场站', '/api/energy/visible-sites')
    add('C 主数据', '电表树', '/api/energy/meter-reading/tree')
    # ⚠ 不要加 /api/deviceProfiles 与 /api/assetProfiles。
    #
    # 这两个端点写死了 @PreAuthorize("hasAuthority('TENANT_ADMIN')")，
    # 客户永远 403 —— 但**客户页面并不会调用它们**：
    #   · query_panel 只在 `if (!cid)`（租户分支）里调 deviceProfiles，
    #     客户走 attachDevices 分支（用 metric-params 下发品种，不碰档案列表）
    #   · assetProfiles 前端没有任何部件调用
    #   · energy_source_select / meter_type_config 用 deviceProfiles，
    #     但它们是租户配置页部件，客户看板里不含
    #
    # 把它们放进探针会制造「假阳性」—— 2026-10-23 首次跑探针时报了这 2 条，
    # 耗时排查才发现是探针自己编的，不是真实缺陷。
    # 判定客户真实会触发什么，依据只能是**部件源码**（controllerScript），
    # 不是「看起来像主数据就该能读」。
    add('C 主数据', '自检', '/api/energy/self-check')
    add('C 主数据', '当前用户', '/api/auth/user')
    add('C 主数据', '客户菜单', '/api/customMenu?assignToList=')

    return probes


TZ = timezone(timedelta(hours=8))


def semantic_checks(api):
    """语义断言：状态码 200 不代表页面上有东西。

    返回 `(checks, fails)`：checks 是实际执行的断言描述，fails 是失败项。
    每项失败都带 `remedy`（怎么修），因为看这个输出的人往往是运维，
    不是写这段代码的人。
    """
    checks = []
    fails = []
    now = int(time.time() * 1000)
    # 设备窗口 3 天：容忍定时汇总（默认 1 小时）与 RTU 上报间隔
    dev_from = now - 3 * 86400000
    today = int(datetime.now(TZ).replace(hour=0, minute=0, second=0, microsecond=0)
                .timestamp() * 1000)

    assets = page_all(api, '/api/user/assets')
    devices = page_all(api, '/api/user/devices')
    dashboards = page_all(api, '/api/user/dashboards')

    # ---- S1：设备有遥测 → 所属场站必须有汇总 ----
    site_of = {}
    for d in devices:
        did = d['id']['id']
        ai = d.get('additionalInfo') or {}
        if isinstance(ai, str):
            try:
                ai = json.loads(ai)
            except Exception:
                ai = {}
        site = ai.get('siteId')
        code, body = api.call(
            f'/api/plugins/telemetry/DEVICE/{did}/values/timeseries'
            f'?keys=energy&startTs={dev_from}&endTs={now}&limit=1&orderBy=DESC')
        if code != 200 or not isinstance(body, dict) or not body.get('energy'):
            continue
        if site:
            site_of.setdefault(site, []).append(d.get('name', did)[:24])

    checks.append('S1 设备有遥测的场站：%d 个' % len(site_of))
    for site, names in sorted(site_of.items()):
        code, body = api.call(
            f'/api/plugins/telemetry/ASSET/{site}/values/timeseries'
            f'?keys=energy_total&startTs={today - 2 * 86400000}&endTs={now}'
            f'&interval=86400000&agg=SUM&limit=100&orderBy=ASC')
        got = isinstance(body, dict) and body.get('energy_total')
        if code != 200 or not got:
            fails.append({
                'group': 'S1 场站汇总为空',
                'label': f'场站 {site[:8]}（下属 {len(names)} 台有遥测的设备）',
                'path': f'/api/plugins/telemetry/ASSET/{site}/values/timeseries?keys=energy_total',
                'code': code,
                'message': ('设备在报数，但场站 energy_total 没有值 —— '
                            '场站页 / 概览页会是 0。见下方 remedy'),
                'remedy': ('确认 AssetTotalsScheduler 是否在跑（日志搜「资产汇总刷新完成」），'
                            '或手工 POST /api/energy/asset-totals/rebuild {"days":2}'),
            })

    # ---- S2：看板 alias 不能把品种/字典资产当取数实体 ----
    kind_ids = set()
    code, mp = api.call('/api/energy/metric-params')
    if code == 200 and isinstance(mp, dict):
        if mp.get('libraryId'):
            kind_ids.add(mp['libraryId'])
        for k in (mp.get('kinds') or []):
            if k.get('id'):
                kind_ids.add(k['id'])

    leaked = 0
    for db in dashboards:
        code, full = api.call(f'/api/dashboard/{db["id"]["id"]}')
        if code != 200 or not isinstance(full, dict):
            continue
        cfg = full.get('configuration') or {}
        if isinstance(cfg, str):
            try:
                cfg = json.loads(cfg)
            except Exception:
                cfg = {}
        aliases = cfg.get('entityAliases') or {}
        for _, a in aliases.items():
            f = (a or {}).get('filter') or {}
            if f.get('type') != 'singleEntity':
                continue
            eid = (f.get('singleEntity') or {}).get('id')
            if eid in kind_ids:
                leaked += 1
                fails.append({
                    'group': 'S2 品种被当取数实体',
                    'label': f'{db.get("title", "")[:20]} / {(a or {}).get("alias", "")}',
                    'path': f'/api/dashboard/{db["id"]["id"]}',
                    'code': 200,
                    'message': f'alias 指向品种/字典资产 {eid}（它没有遥测）',
                    'remedy': '重新部署 energy_management.* 部件（resolveEntity 已过滤品种）',
                })
    checks.append('S2 看板 alias 引用品种资产：%d 处' % leaked)

    return checks, fails


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', default='http://127.0.0.1:8090')
    ap.add_argument('--tenant', required=True)
    ap.add_argument('--tenant-pass', required=True)
    ap.add_argument('--customer', required=True)
    ap.add_argument('--customer-pass', required=True)
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--strict', action='store_true')
    ap.add_argument('--max-per-group', type=int, default=0, help='每组最多显示多少条失败')
    args = ap.parse_args()

    ctoken = login(args.base, args.customer, args.customer_pass)
    ttoken = login(args.base, args.tenant, args.tenant_pass)
    capi = Api(args.base, ctoken)
    tapi = Api(args.base, ttoken)

    probes = build_probes(capi)

    results = []
    for group, label, path in probes:
        code, body = capi.call(path)
        msg = ''
        if code in (401, 403):
            msg = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)[:160]
        results.append({'group': group, 'label': label, 'path': path, 'code': code, 'message': msg})

    # 同一条 path 只报一次
    dedup, seen = [], set()
    for r in results:
        if r['path'] in seen:
            continue
        seen.add(r['path'])
        dedup.append(r)

    bad = [r for r in dedup if r['code'] in (401, 403) or r['code'] >= 500]
    ok = [r for r in dedup if r not in bad]

    # 语义断言：200 不等于有数据。失败项并入 bad，让 --strict 一起卡住。
    semantics, sem_fails = semantic_checks(capi)
    bad.extend(sem_fails)

    if args.json:
        print(json.dumps({'total': len(dedup) + len(semantics), 'failed': len(bad),
                          'semanticChecks': semantics, 'items': dedup + sem_fails},
                         ensure_ascii=False, indent=1))
    else:
        print(f'\n客户视角探针：HTTP {len(dedup)} 条，语义断言 {len(semantics)} 项，失败 {len(bad)} 条\n')
        groups = {}
        for r in bad:
            groups.setdefault(r['group'], []).append(r)
        for g in sorted(groups):
            rows = groups[g]
            print(f'✗ {g}（{len(rows)} 条）')
            limit = args.max_per_group or len(rows)
            for r in rows[:limit]:
                print(f'    {r["code"]}  {r["label"]}')
                print(f'         {r["path"][:120]}')
                if r['message']:
                    print(f'         → {r["message"][:150]}')
                if r.get('remedy'):
                    print(f'         → 修法：{r["remedy"][:160]}')
            print()
        if not bad:
            print('✓ 客户能读到自己页面需要的全部数据，且部件取数目标有效')

    if args.strict and bad:
        sys.exit(2)
    sys.exit(0)


if __name__ == '__main__':
    main()
