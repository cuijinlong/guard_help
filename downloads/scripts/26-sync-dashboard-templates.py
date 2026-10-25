#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把仓库里的看板模板同步进数据库（租户级模板）。

<h3>为什么需要</h3>
看板模板（`guard-server/src/main/data/json/tenant/dashboards/*.json`）只在
**首次安装**时由 `InstallScripts#createDefaultTenantDashboards` 导入一次。
之后修改仓库里的 JSON 不会自动生效：

- 新建客户复制的是**数据库里**的旧模板
- 于是「改好了模板 → 重建客户 → 还是老样子」

这个脚本按标题找到数据库里的租户级模板（`customer_id` 为空），
用仓库 JSON 覆盖它的 `configuration`，`version` 自增。

<h3>它不改什么</h3>
- **不改已复制给客户的看板副本** —— 那是客户自己的资产。需要单独修：
  例如「能源分析看板数据源」用 `25-fix-analysis-scope.py`。
- 不删不建看板，只更新同标题的那一份。

<h3>用法</h3>
```bash
# 预演：列出会更新哪些模板、各自差异（只对比长度与占位符）
python3 scripts/26-sync-dashboard-templates.py

# 执行
python3 scripts/26-sync-dashboard-templates.py --apply
```

`--dir` 可指定模板目录，默认自动定位仓库里的
`guard-server/src/main/data/json/tenant/dashboards`。
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

# 部署目录（~/energy-app）里没有仓库源码，模板目录通常在别处。
# 依次尝试：脚本上一级 / 再上一级 / 常见工作区路径；都不在就要求 --dir。
DEFAULT_DIRS = [
    os.path.join(HERE, '..', '..', 'guard-server', 'src', 'main', 'data', 'json', 'tenant', 'dashboards'),
    os.path.join(HERE, '..', 'guard-server', 'src', 'main', 'data', 'json', 'tenant', 'dashboards'),
    os.path.join(HERE, '..', '..', '..', 'guard-server', 'src', 'main', 'data', 'json', 'tenant', 'dashboards'),
    os.path.expanduser('~/Documents/workspace/iot-rule-engine/guard-server/src/main/data/json/tenant/dashboards'),
]


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


def template_dir(explicit):
    if explicit:
        return explicit
    for d in DEFAULT_DIRS:
        if os.path.isdir(d):
            return os.path.realpath(d)
    return None


def main():
    global BASE
    ap = argparse.ArgumentParser(description='同步看板模板到数据库')
    ap.add_argument('--base', default=BASE)
    ap.add_argument('--tenant', default='')
    ap.add_argument('--tenant-pass', default='')
    ap.add_argument('--dir', default='')
    ap.add_argument('--apply', action='store_true', help='真正写库（默认只预演）')
    a = ap.parse_args()
    BASE = a.base

    tdir = template_dir(a.dir)
    if not tdir:
        print('✗ 找不到模板目录，用 --dir 指定 '
              'guard-server/src/main/data/json/tenant/dashboards')
        return 2

    tenant, pwd = credentials(a)
    if not tenant or not pwd:
        print('✗ 缺少租户管理员凭据')
        return 2
    tok = api('/api/auth/login', method='POST',
              body={'username': tenant, 'password': pwd})['token']

    # 租户级模板：customerId 为空的 dashboard
    by_title = {}
    for d in paged('/api/tenant/dashboards', tok):
        if (d.get('customerId') or {}).get('id'):
            continue
        by_title[d.get('title') or ''] = d

    files = sorted(f for f in os.listdir(tdir) if f.endswith('.json'))
    updated = same = missing = 0
    for fname in files:
        path = os.path.join(tdir, fname)
        try:
            tpl = json.load(open(path, encoding='utf-8'))
        except Exception as e:
            print('  ! %s 解析失败：%s' % (fname, e))
            continue
        title = tpl.get('title') or ''
        cur = by_title.get(title)
        if not cur:
            print('  ! 数据库里没有模板「%s」（%s）' % (title, fname))
            missing += 1
            continue

        detail = api('/api/dashboard/%s' % cur['id']['id'], tok) or {}
        old_cfg = json.dumps(detail.get('configuration') or {}, sort_keys=True, ensure_ascii=False)
        new_cfg = json.dumps(tpl.get('configuration') or {}, sort_keys=True, ensure_ascii=False)
        if old_cfg == new_cfg:
            same += 1
            continue

        print('  %-24s %s' % (title, fname))
        if not a.apply:
            updated += 1
            continue
        detail['configuration'] = tpl.get('configuration')
        api('/api/dashboard', tok, method='POST', body=detail)
        updated += 1

    print('\n%s：更新 %d 个模板，%d 个已一致，%d 个数据库里缺对应项'
          % ('已同步' if a.apply else '预演', updated, same, missing))
    if updated and not a.apply:
        print('加 --apply 执行；之后新建的客户才会用到新模板。')
        print('存量客户的看板副本需要各自的修复脚本（如 25-fix-analysis-scope.py）。')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except RuntimeError as e:
        print('✗ %s' % e)
        sys.exit(1)
