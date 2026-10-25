#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""隐藏能源看板右上角 TB 自带的时间选择器与实体选择器。

<h3>为什么需要</h3>
能源系列看板把时间范围搬进了自己的部件里：

- 「查询设置」（`energy_management.query_panel`）
- 「分析条件」（`energy_management.analysis_bar`）

两者都能切**实时 / 历史**，并且带着自己的实体（分项/场站/设备）级联选择。
如果右上角还留着 TB 原生的时间选择器与实体选择器，同一个页面上就有两套
互不相干的时间源 —— 客户改上面那套不动下面的数据，看起来像「功能坏了」。

TB 原生支持这两个开关（`configuration.settings`）：

```
showDashboardTimewindow : false   # 右上角时间选择器
showEntitiesSelect      : false   # 右上角实体选择器
```

注意：**编辑模式不受影响**。`dashboard-page.component.html` 里 `isEdit` 分支
不读这两个开关，管理员进「编辑仪表板」时仍然能改时间窗口，只是查看/演示时
不显示 —— 正好是要的效果。

<h3>它改哪些看板</h3>
只改标题在白名单里的能源/报表看板；「峰谷时段」「客户能源档案」这两个配置页
保留原生实体选择器（它们的部件依赖它）。

<h3>幂等</h3>
已经是目标值就跳过，重复执行不产生版本噪音。

<h3>用法</h3>
```bash
python3 scripts/28-hide-dashboard-toolbar.py              # 预演
python3 scripts/28-hide-dashboard-toolbar.py --apply      # 执行
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

# 部件内已有自己的时间/实体入口的能源与报表看板
ENERGY_TITLES = {
    '区域能耗', '盘查报告', '基础报表', '综合能耗', '能耗洞察', '能耗概览',
    '历史能耗', '闲时能耗', '分项能耗', '手工填报', '抄表功能', '我的账单',
    '参数报表', '电能质量', '实时能耗', '能源流向', '节能记录', '峰谷分析',
}

# 保留原生选择器的配置页
KEEP_TITLES = {'峰谷时段', '客户能源档案'}


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


def main():
    global BASE
    ap = argparse.ArgumentParser(description='隐藏能源看板右上角的 TB 时间/实体选择器')
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

    changed = same = skipped = 0
    for row in rows:
        title = (row.get('title') or '').strip()
        if title not in ENERGY_TITLES:
            if title in KEEP_TITLES:
                skipped += 1
            continue
        did = row['id']['id']
        detail = api('/api/dashboard/%s' % did, tok) or {}
        cfg = detail.setdefault('configuration', {})
        settings = cfg.get('settings')
        if not isinstance(settings, dict):
            settings = {}
            cfg['settings'] = settings
        if settings.get('showDashboardTimewindow') is False and settings.get('showEntitiesSelect') is False:
            same += 1
            continue

        cid = (row.get('customerId') or {}).get('id')
        owner = (row.get('customerId') or {}).get('title') or (
            ('模板' if not cid else cid['id'][:8]))
        before = (settings.get('showDashboardTimewindow'), settings.get('showEntitiesSelect'))
        print('  %-10s %-8s %s → (False, False)' % (title, owner, before))
        if not a.apply:
            changed += 1
            continue
        settings['showDashboardTimewindow'] = False
        settings['showEntitiesSelect'] = False
        api('/api/dashboard', tok, method='POST', body=detail)
        changed += 1

    print('\n%s：%d 个需更新，%d 个已符合，%d 个配置页保留'
          % ('已执行' if a.apply else '预演', changed, same, skipped))
    if changed and not a.apply:
        print('加 --apply 执行。')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except RuntimeError as e:
        print('✗ %s' % e)
        sys.exit(1)
