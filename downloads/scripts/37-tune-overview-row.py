#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""调「能耗概览」第一排（用能品种那一行）的高度，去掉多余的上面留白。

<h3>为什么需要它</h3>
第一排是 `energy_management.analysis_bar` 部件，里面只有一条 34px 的下拉
（场站 / 用能品种 / 分析范围）。但 TB 的栅格是**正方形格子**：列宽随屏宽变化，
`sizeY=1` 的行高也跟着等比放大，而内容固定 34px，于是内容上下各留一片空白。

实测（2026-11-07，同一台机器改窗口宽度）：

| 窗口宽 | 格子高 | 内容上留白 |
| --- | --- | --- |
| 1280 | 32.5px | -0.75px（内容已溢出格子） |
| 1440 | 39.2px | 2.6px |
| 1600 | 45.8px | 5.9px |
| 1920 | 59.2px | 12.6px |
| 2560 | 85.8px | 25.9px |

宽屏上这一行会显得「特别高、上面空一大块」，客户原话是
「高度调成正正好好……不要因为这一行的高度太高导致上面留白」。

<h3>怎么修</h3>
写进看板的 `configuration.settings.dashboardCss`（TB 原生支持，会在
`dashboard-page.component.ts` 里被前缀化后插进页面，只作用于这一个看板）：

```css
.tb-dashboard-page gridster { padding-top: 4px !important; }
gridster-item:has(.widget-type-system-energy_management-analysis_bar) { max-height: 46px; }
```

- **`max-height` 而不是 `height`**：1280 宽时格子只有 32.5px，写死 46px 会让这一行
  压到下一排上（实测重叠 3px）。`max-height` 在窄屏不生效，只压宽屏。
- **`padding-top: 10px → 4px`**：看板顶部原本还有一圈栅格内边距，收窄后这一排
  更贴近顶栏。
- 用 `:has()` 精准选中分析栏所在的格子，不影响其它部件。

改完实测：1280/1440/1600/1920/2560 五种宽度下都不重叠，宽屏留白从 12.6/25.9px
降到 6px。

<h3>为什么不能只靠部件自己的样式</h3>
行高由 `gridster-item` 决定，而它是部件**外面**的元素，部件的 `templateCss`
够不到（样式作用域只覆盖部件内部）。所以必须走看板级 `dashboardCss`。

<h3>为什么这个看板不在仓库 JSON 里</h3>
「能耗概览」是安装流程在库里生成的（仓库 `data/json/tenant/dashboards/`
下没有它），所以 `scripts/26-sync-dashboard-templates.py` 不会覆盖它 ——
但也意味着**重装 / 重建看板后这个 CSS 会丢**，需要重跑本脚本。

<h3>幂等</h3>
`dashboardCss` 已经是目标值就跳过，重复执行不产生版本噪音。

<h3>用法</h3>
```bash
python3 scripts/37-tune-overview-row.py            # 预演，只打印会改哪些
python3 scripts/37-tune-overview-row.py --apply    # 执行
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

# 只处理这一份看板（租户级与客户副本同名，都会被改到）
TARGET_TITLES = {'能耗概览'}

DASHBOARD_CSS = """.tb-dashboard-page gridster { padding-top: 4px !important; }
gridster-item:has(.widget-type-system-energy_management-analysis_bar) { max-height: 46px; }"""


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
    """凭据来源，按优先级：显式参数 → DEPLOY-CREDENTIALS.txt → .env。

    第一优先是 docker-98-rebuild.sh 生成的 DEPLOY-CREDENTIALS.txt，但
    只有跑过重装的机器才有；`.env` 里的 TB_API_USERNAME / TB_API_PASSWORD
    是任何一次 docker-00/02 部署后都必然存在的，所以补这一层兜底。
    """
    if args.tenant and args.tenant_pass:
        return args.tenant, args.tenant_pass

    root = os.path.join(HERE, '..')
    text = ''
    cred = os.path.join(root, 'DEPLOY-CREDENTIALS.txt')
    if os.path.exists(cred):
        text = open(cred, encoding='utf-8', errors='replace').read()
    # 格式（docker-98-rebuild.sh 生成）：  租户管理员     tenant@x.com / 密码
    m = re.search(r'租户管理员\s+(\S+@\S+)\s*/\s*(\S+)', text)
    tenant = args.tenant or (m.group(1) if m else '')
    pwd = args.tenant_pass or (m.group(2) if m else '')

    if not (tenant and pwd):
        env = os.path.join(root, '.env')
        if os.path.exists(env):
            kv = {}
            for line in open(env, encoding='utf-8', errors='replace'):
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, v = line.split('=', 1)
                    kv[k.strip()] = v.strip().strip('"\'')
            tenant = tenant or kv.get('TB_API_USERNAME', '')
            pwd = pwd or kv.get('TB_API_PASSWORD', '')

    return tenant, pwd


def main():
    global BASE
    ap = argparse.ArgumentParser(
        description='调「能耗概览」第一排高度：去掉分析栏多余的上面留白')
    ap.add_argument('--base', default=BASE)
    ap.add_argument('--tenant', default='')
    ap.add_argument('--tenant-pass', default='')
    ap.add_argument('--apply', action='store_true', help='真正写库（默认只预演）')
    a = ap.parse_args()
    BASE = a.base

    tenant, pwd = credentials(a)
    if not tenant or not pwd:
        print('✗ 缺少租户管理员凭据。三种给法任选其一：')
        print('  ① --tenant <邮箱> --tenant-pass <密码>')
        print('  ② 部署目录放 DEPLOY-CREDENTIALS.txt（重装脚本会生成）')
        print('  ③ 部署目录 .env 里设 TB_API_USERNAME / TB_API_PASSWORD')
        return 2
    try:
        tok = api('/api/auth/login', method='POST',
                  body={'username': tenant, 'password': pwd})['token']
    except RuntimeError as e:
        if '401' not in str(e):
            raise
        print('✗ 登录失败：%s' % tenant)
        print('  这个账号登不进去。.env 里的 TB_API_USERNAME/PASSWORD 可能还是')
        print('  模板默认值（tenant@thingsboard.org / tenant），真实租户管理员请用')
        print('  --tenant <邮箱> --tenant-pass <密码> 指定，或放 DEPLOY-CREDENTIALS.txt。')
        return 2

    rows = paged('/api/tenant/dashboards', tok)
    print('库里共 %d 个看板（含模板与客户副本）\n' % len(rows))

    changed = same = 0
    for row in rows:
        title = (row.get('title') or '').strip()
        if title not in TARGET_TITLES:
            continue
        did = row['id']['id']
        detail = api('/api/dashboard/%s' % did, tok) or {}
        cfg = detail.setdefault('configuration', {})
        settings = cfg.get('settings')
        if not isinstance(settings, dict):
            settings = {}
            cfg['settings'] = settings

        cur = settings.get('dashboardCss') or ''
        if cur.strip() == DASHBOARD_CSS.strip():
            same += 1
            print('  %-10s %s  已符合，跳过' % (title, did[:8]))
            continue

        cid_obj = row.get('customerId') or {}
        if isinstance(cid_obj, str):
            cid_obj = {'id': cid_obj}
        cid = cid_obj.get('id')
        owner = cid_obj.get('title') or (cid[:8] if cid else '模板')
        print('  %-10s %-8s %s  将写入 dashboardCss（原长 %d 字符）'
              % (title, owner, did[:8], len(cur)))
        if not a.apply:
            changed += 1
            continue
        settings['dashboardCss'] = DASHBOARD_CSS
        api('/api/dashboard', tok, method='POST', body=detail)
        changed += 1

    print('\n%s：%d 个需更新，%d 个已符合'
          % ('已执行' if a.apply else '预演', changed, same))
    if changed and not a.apply:
        print('加 --apply 执行。')
    if changed and a.apply:
        print('刷新浏览器（Cmd/Ctrl+Shift+R）看效果。')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except RuntimeError as e:
        print('✗ %s' % e)
        sys.exit(1)
