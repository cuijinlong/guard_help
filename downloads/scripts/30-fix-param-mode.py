#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把「查询设置」部件的指标选择模式刷成统一形态（存量客户修复）。

<h3>为什么需要</h3>
看板模板（`data/json/tenant/dashboards/*.json`）只在**建客户时**复制一份给客户。
之后再改模板，已建客户的看板副本**不会跟着变** —— 副本是客户自己的资产。

于是改了模板之后会出现「新装的客户是对的、老客户还是老样子」，
典型症状：

- 模板里 `param_report` / `meter_reading` 的 `query_panel.multiParam` 已改成 `false`
  （左侧只列一级指标的下拉），但存量客户的看板还是 `true`
  （分组多选，把二级指标摊在左侧）

`26-sync-dashboard-templates.py` 只处理租户级模板，不管客户副本 ——
所以需要这个脚本。

<h3>它改什么</h3>
遍历所有客户名下的看板，把 `query_panel` 部件的 `settings.multiParam` 置为
脚本里指定的值（默认 `false`），**其它设置一律不动**（时间范围、默认指标、
数据源绑定、客户自己的调整都保留）。

<h3>它不改什么</h3>
- 不改租户级模板（那是 26 号脚本的活）
- 不碰非 `query_panel` 的部件
- 不动看板的别名、布局、版本历史

<h3>用法</h3>
```bash
# 预演：只列出会改哪些看板
python3 scripts/30-fix-param-mode.py

# 执行
python3 scripts/30-fix-param-mode.py --apply

# 指定看板（默认处理所有含 query_panel 的客户副本）
python3 scripts/30-fix-param-mode.py --apply --titles 参数报表,抄表功能

# 反向（把多选开回来，一般不用）
python3 scripts/30-fix-param-mode.py --apply --multi true
```

幂等：已经是目标值的看板会被跳过，重复跑无副作用。
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
        d = api('%s%spageSize=200&page=%d' % (path, sep, page), token)
        out.extend(d.get('data') or [])
        if not d.get('hasNext'):
            return out
        page += 1


def credentials(args):
    if args.tenant and args.tenant_pass:
        return args.tenant, args.tenant_pass
    for cand in (os.path.join(HERE, '..', 'DEPLOY-CREDENTIALS.txt'),
                 os.path.join(HERE, 'DEPLOY-CREDENTIALS.txt')):
        if os.path.exists(cand):
            text = open(cand, encoding='utf-8', errors='replace').read()
            m = re.search(r'租户管理员\s+(\S+@\S+)\s*/\s*(\S+)', text)
            if m:
                return m.group(1), m.group(2)
    return '', ''


def is_query_panel(widget):
    return 'query_panel' in (widget.get('typeFullFqn') or '')


def main():
    global BASE
    ap = argparse.ArgumentParser(description='统一客户看板里「查询设置」的指标选择模式')
    ap.add_argument('--base', default=BASE)
    ap.add_argument('--tenant', default='')
    ap.add_argument('--tenant-pass', default='')
    ap.add_argument('--titles', default='',
                    help='只处理这些标题（逗号分隔）；留空 = 所有含 query_panel 的看板')
    ap.add_argument('--multi', default='false', choices=['true', 'false'],
                    help='目标值：false=单选下拉（默认，左侧只列一级指标）')
    ap.add_argument('--apply', action='store_true', help='真正写库（默认只预演）')
    a = ap.parse_args()
    BASE = a.base

    tenant, pwd = credentials(a)
    if not tenant or not pwd:
        print('✗ 缺少租户管理员凭据（--tenant / --tenant-pass，或部署目录的 DEPLOY-CREDENTIALS.txt）')
        return 2
    tok = api('/api/auth/login', method='POST',
              body={'username': tenant, 'password': pwd})['token']

    target = (a.multi == 'true')

    only_titles = set(t.strip() for t in a.titles.split(',') if t.strip())

    all_dash = paged('/api/tenant/dashboards', tok)
    customers = {(d.get('customerId') or {}).get('id') for d in all_dash}
    customers.discard(None)
    print('库里共 %d 个看板，其中客户副本 %d 个（涉及 %d 个客户）'
          % (len(all_dash), sum(1 for d in all_dash if (d.get('customerId') or {}).get('id')),
             len(customers)))
    print()

    changed = skipped = no_qp = 0
    for row in all_dash:
        cid = (row.get('customerId') or {}).get('id')
        title = row.get('title') or ''
        if not cid:
            continue                      # 租户级模板交给 26 号脚本
        if only_titles and title not in only_titles:
            continue
        did = row['id']['id']
        detail = api('/api/dashboard/%s' % did, tok) or {}
        cfg = detail.get('configuration') or {}
        widgets = cfg.get('widgets') or {}

        touched = []
        for wid, w in widgets.items():
            if not is_query_panel(w):
                continue
            settings = ((w.get('config') or {}).get('settings')) or {}
            # 未配置时默认就是 false（见 query_panel：settings.multiParam === true 才开）
            # 所以用 bool() 归一，不能拿 None is False 判定 —— 否则会把一堆
            # 「本来就没配、实际已是单选」的看板列成待修复（实测 10 个假阳性）。
            cur = settings.get('multiParam') is True
            if cur == target:
                continue
            touched.append(wid)

        if not touched:
            # 区分「没有 query_panel」与「已经是目标值」
            if any(is_query_panel(w) for w in widgets.values()):
                skipped += 1
            else:
                no_qp += 1
            continue

        print('  %-14s %s  改 %d 个 query_panel（multiParam → %s）'
              % (title, did[:8], len(touched), a.multi))
        changed += 1
        if not a.apply:
            continue

        for wid in touched:
            w = widgets[wid]
            w.setdefault('config', {}).setdefault('settings', {})['multiParam'] = target
        detail['configuration'] = cfg
        api('/api/dashboard', tok, method='POST', body=detail)

    print()
    print('%s：%d 个看板需要处理，%d 个已是目标值，%d 个无 query_panel'
          % ('已执行' if a.apply else '预演', changed, skipped, no_qp))
    if changed and not a.apply:
        print('加 --apply 执行。幂等，重复跑只处理还不是目标值的那些。')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except RuntimeError as e:
        print('✗ %s' % e)
        sys.exit(1)
