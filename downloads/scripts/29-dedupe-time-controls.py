#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""去掉重复的时间选择：看板里已有「查询设置 / 分析条件」时，其余部件不再自带时间范围。

<h3>为什么要管这件事</h3>
能源看板的时间入口有**两类**：

| 类型 | 出现在 | 谁负责时间 |
| --- | --- | --- |
| 枢纽部件 | `query_panel`（左侧查询设置）、`analysis_bar`（顶部分析条件） | 用户在这里选，结果部件跟随 |
| 自管部件 | `asset_stats_chart` / `distribution_chart` / `ranking_list` | 它们自带「按日/按月/按年 + 起止」 |

单个看板里两类并存时，页面上就有两个时间源。用户在左边选「按月」，
右边的部件仍按自己的「今天」出数 —— 两处各说各话，看起来像数据错了。

这三个部件本身有开关：

```
config.settings.timeMode = 'own'    # 用部件自己的时间选择（单看板时才有意义）
config.settings.timeMode = 'state'  # 跟随枢纽部件下发的 state（本脚本要的状态）
```

**只在看板确实有枢纽部件时才改**。像「能耗洞察」这种没有查询设置的看板，
部件自带的时间选择就是唯一入口，改成 state 会让它没有时间可用。

<h3>它不改什么</h3>
- 不改看板右上角的 TB 时间选择器（那是 `28-hide-dashboard-toolbar.py` 的事）
- 不改 `audit_report` / `sankey_flow` / `power_quality` / `energy_overview` /
  `saving_records` —— 它们没有 `timeMode` 开关，时间控件是写死的。
  这类部件只在**没有**枢纽部件的看板里出现，目前不构成重复。
  如果哪天把它们放进带枢纽部件的看板，脚本会打印警告，需要改部件代码。

<h3>幂等</h3>
已经是 `state` 的跳过；重复执行不产生版本噪音。

<h3>用法</h3>
```bash
python3 scripts/29-dedupe-time-controls.py            # 预演
python3 scripts/29-dedupe-time-controls.py --apply    # 执行
```
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

BASE = 'http://127.0.0.1:8090'
HERE = os.path.dirname(os.path.abspath(__file__))

# 提供时间入口的枢纽部件
HUB_TYPES = {'query_panel', 'analysis_bar'}
# 有 timeMode 开关、可切到「跟随 state」的部件
SWITCHABLE = {'asset_stats_chart', 'distribution_chart', 'ranking_list'}
# 时间控件写死、无法自动切换的部件（只在无枢纽看板里合法）
#
# tou_analysis 原本也在这里（自带「时/日/月/年」分段）。2026-10-25 已把它的
# 分段删掉、粒度改由查询设置下发的 grain 决定，所以它不再是问题部件。
HARDCODED = {'audit_report', 'sankey_flow', 'power_quality',
             'energy_overview', 'saving_records'}


def api(path, token=None, method='GET', body=None):
    req = urllib.request.Request(BASE + path, method=method)
    if body is not None:
        req.data = json.dumps(body).encode()
        req.add_header('Content-Type', 'application/json')
    if token:
        req.add_header('X-Authorization', 'Bearer ' + token)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read().decode()
            return json.loads(raw) if raw.strip() else None
    except urllib.error.HTTPError as e:
        raise RuntimeError('HTTP %s %s → %s'
                           % (e.code, path, e.read().decode('utf-8', 'replace')[:300]))
    except urllib.error.URLError as e:
        raise RuntimeError('连不上平台：%s' % e.reason)


def paged(path, token):
    out, page = [], 0
    while True:
        sep = '&' if '?' in path else '?'
        d = api('%s%spageSize=500&page=%d' % (path, sep, page), token)
        out.extend(d.get('data') or [])
        if not d.get('hasNext'):
            return out
        page += 1


def credentials(args):
    if args.tenant and args.tenant_pass:
        return args.tenant, args.tenant_pass
    path = os.path.join(HERE, '..', 'DEPLOY-CREDENTIALS.txt')
    text = open(path, encoding='utf-8', errors='replace').read() if os.path.exists(path) else ''
    m = re.search(r'租户管理员\s+(\S+@\S+)\s*/\s*(\S+)', text)
    return ((args.tenant or (m.group(1) if m else '')),
            (args.tenant_pass or (m.group(2) if m else '')))


def short(t):
    return (t or '').replace('system.energy_management.', '')


def main():
    global BASE
    ap = argparse.ArgumentParser(description='去掉看板里重复的时间选择控件')
    ap.add_argument('--base', default=BASE)
    ap.add_argument('--tenant', default='')
    ap.add_argument('--tenant-pass', default='')
    ap.add_argument('--apply', action='store_true', help='真正写库（默认只预演）')
    a = ap.parse_args()
    BASE = a.base

    tenant, pwd = credentials(a)
    if not tenant or not pwd:
        print('✗ 缺少租户管理员凭据')
        return 2
    tok = api('/api/auth/login', method='POST',
              body={'username': tenant, 'password': pwd})['token']

    rows = paged('/api/tenant/dashboards', tok)
    print('库里共 %d 个看板（含模板与客户副本）\n' % len(rows))

    changed = same = nohub = 0
    warns = []
    for row in rows:
        title = (row.get('title') or '').strip()
        did = row['id']['id']
        detail = api('/api/dashboard/%s' % did, tok) or {}
        cfg = detail.get('configuration') or {}
        widgets = cfg.get('widgets') or {}

        types = {wid: short(w.get('typeFullFqn')) for wid, w in widgets.items()}
        hubs = sorted({t for t in types.values() if t in HUB_TYPES})
        own = [wid for wid, t in types.items() if t in SWITCHABLE]
        hard = sorted({t for t in types.values() if t in HARDCODED})

        if not hubs:
            nohub += 1
            continue

        # 有枢纽部件，但还有写死时间控件的部件 —— 只能在部件代码里改，先告警
        for t in hard:
            warns.append((title, t))

        touched = []
        for wid in own:
            w = widgets[wid]
            s = (w.get('config') or {}).get('settings')
            if s is None:
                s = {}
                w.setdefault('config', {})['settings'] = s
            if s.get('timeMode') == 'state':
                continue
            touched.append(types[wid])
            s['timeMode'] = 'state'

        # 列表接口里 customerId 可能是 null / 字符串 / {id,title} 三种形态，
        # 一律先取成纯字符串再用，否则 cid['id'] 会 TypeError。
        cid = row.get('customerId')
        if isinstance(cid, dict):
            cid = cid.get('id')
        owner = ((row.get('customerName') or '').strip()
                 or (str(cid)[:8] if cid else '模板'))

        if not touched:
            same += 1
            continue

        print('  %-12s %-8s 枢纽=%-14s 关闭自带时间：%s'
              % (title, owner, ','.join(hubs), ','.join(touched)))
        if a.apply:
            api('/api/dashboard', tok, method='POST', body=detail)
        changed += 1

    if warns:
        print('\n⚠ 这些部件的时间控件是写死的，脚本改不了（需改部件代码）：')
        seen = set()
        for title, t in warns:
            if (title, t) in seen:
                continue
            seen.add((title, t))
            print('    %-12s %s' % (title, t))
        print('  —— 它们只在没有查询设置/分析条件的看板里出现，目前不构成重复。')

    print('\n%s：%d 个看板需处理，%d 个已符合，%d 个无枢纽部件（保持原样）'
          % ('已执行' if a.apply else '预演', changed, same, nohub))
    if changed and not a.apply:
        print('加 --apply 执行。')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except RuntimeError as e:
        print('✗ %s' % e)
        sys.exit(1)
