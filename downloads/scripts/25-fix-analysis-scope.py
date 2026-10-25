#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把「能源分析」类看板副本的数据源从单一场站换成客户组织。

<h3>修的是什么</h3>
综合能耗 / 能耗洞察 / 能源流向 / 电能质量 / 盘查报告 这五个看板的
「场站」数据源别名，模板里是占位符 `…05a1`（= 单相园区）。
复制给客户时被替换成**单相场站**的真实 id，于是：

  · 场站能耗排名只出一行（三相园被排除）
  · 能源构成里少了三相园那台 12 t/天的生产蒸汽表，蒸汽占比虚高
  · KPI 只统计了客户一半的用能

2026-10-25 起模板改用 `…05a2`（= 客户组织），新客户直接正确。
本脚本修**存量客户**：把这五个看板里指向单相场站的别名换成组织。

<h3>用法</h3>
```bash
# 预演（打印会改哪些看板，不写库）
python3 scripts/25-fix-analysis-scope.py

# 执行
python3 scripts/25-fix-analysis-scope.py --apply
```

凭据默认读 `../DEPLOY-CREDENTIALS.txt`。
退出码 0 = 无需修改或已修好；1 = 有失败。
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

# 只改这些标题的看板 —— 能耗概览 / 实时能耗 的「场站」别名另有语义，不能动
TITLES = {'综合能耗', '能耗洞察', '能源流向', '电能质量', '盘查报告'}


def api(path, token=None, method='GET', body=None):
    req = urllib.request.Request(BASE + path, method=method)
    if body is not None:
        req.data = json.dumps(body).encode()
        req.add_header('Content-Type', 'application/json')
    if token:
        req.add_header('X-Authorization', 'Bearer ' + token)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
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


def main():
    global BASE
    ap = argparse.ArgumentParser(description='能源分析看板数据源改为客户组织')
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

    # 客户 → 组织
    org_by_customer = {}
    for org in paged('/api/tenant/assets?type=组织', tok) if False else paged('/api/tenant/assets', tok):
        if org.get('type') != '组织':
            continue
        cid = ((org.get('customerId') or {}).get('id'))
        if not cid:
            continue
        # 优先 isRoot 的组织
        ai = org.get('additionalInfo') or {}
        if cid not in org_by_customer or ai.get('isRoot'):
            org_by_customer[cid] = org

    if not org_by_customer:
        print('✗ 没有找到任何客户组织')
        return 2

    dashboards = paged('/api/tenant/dashboards', tok)
    fixed = skipped = 0
    for d in dashboards:
        title = d.get('title') or ''
        if title not in TITLES:
            continue
        cid = ((d.get('customerId') or {}).get('id'))
        org = org_by_customer.get(cid)
        if not org:
            print('  ! %s（客户 %s）无组织，跳过' % (title, (cid or '')[:8]))
            skipped += 1
            continue

        org_id = org['id']['id']
        # 列表接口不返回 configuration，必须逐个取详情
        detail = api('/api/dashboard/%s' % d['id']['id'], tok)
        cfg = (detail or {}).get('configuration') or {}
        aliases = cfg.get('entityAliases') or {}
        changed = []
        for aid, al in aliases.items():
            flt = al.get('filter') or {}
            se = flt.get('singleEntity') or {}
            if se.get('entityType') != 'ASSET' or not se.get('id'):
                continue
            if se['id'] == org_id:
                continue
            # 只改「能展开到多场站」的资产：跳过设备与分项根等（本脚本只处理单场站）
            try:
                target = api('/api/asset/%s' % se['id'], tok)
            except RuntimeError:
                continue
            if (target or {}).get('type') != '场站':
                continue
            se['id'] = org_id
            changed.append(al.get('alias') or aid)

        if not changed:
            skipped += 1
            continue
        print('  %-40s → 组织 %s（别名：%s）'
              % (title + '（' + (d.get('name') or '')[:12] + '）', org_id[:8], ', '.join(changed)))
        if a.apply:
            detail['configuration'] = cfg
            api('/api/dashboard', tok, method='POST', body=detail)
        fixed += 1

    print('\n%s：%d 个看板%s，%d 个跳过'
          % ('已修复' if a.apply else '预演', fixed,
             '' if a.apply else '待修改', skipped))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except RuntimeError as e:
        print('✗ %s' % e)
        sys.exit(1)
