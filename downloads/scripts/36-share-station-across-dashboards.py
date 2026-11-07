#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""让客户菜单里的所有看板共用右上角场站选择器。

<h3>为什么需要</h3>

右上角场站（`tb-station-select`）是**整个平台唯一的统计范围开关**。
客户在 A 页切到「生产园区」，翻到 B 页却发现数字还是办公园区的 ——
这不是「两个页面数字对不上」，是统计范围本身没统一。

实测 2026-11-06：客户菜单 27 个页面里有 3 个没开顶栏场站：

    能耗概览         showStationSelect=false  → 首页就没有场站开关
    电能质量数据集    showStationSelect=false  → 数据集页切场站没反应
    组织与场站        showStationSelect=false  → **这是对的**（见下方例外）

<h3>例外：组织与场站</h3>

`组织与场站` 这一页本身就是**管理场站**的地方，场站由页面自己的树选择，
顶栏再放一个「当前场站」会让「你在看哪个场站」与「你在编辑哪个场站」
变成两个概念。所以它保持关闭 —— 这是唯一例外。

<h3>顺带修的两件事</h3>

1. `toolbarAlwaysOpen: false` —— 顶栏默认折叠，只有鼠标悬停才出现。
   场站开关藏在悬停层里，客户根本找不到（实测闲时能耗就是这样）。
   本脚本统一改成常显。
2. `settings` 里多余的老键（`showTitle` / `showDashboardsSelect` …）会让
   不同页面的顶栏长得不一样。统一收敛成三个键：
   `showDashboardTimewindow=false` / `showEntitiesSelect=false` / `showStationSelect=true`
   —— 时间由部件内的「查询设置 / 分析条件」管，实体选择器另有入口，
   只剩场站这一个开关留在顶栏。

<h3>幂等</h3>

已经是目标值就跳过；重复执行不产生版本噪音。

<h3>用法</h3>

```bash
python3 scripts/36-share-station-across-dashboards.py            # 预演
python3 scripts/36-share-station-across-dashboards.py --apply    # 执行
python3 scripts/36-share-station-across-dashboards.py --apply --all   # 含租户级看板
```
"""

import argparse
import base64
import json
import os
import subprocess
import sys

DB = os.environ.get('ENERGY_DB_CONTAINER', 'energy-postgres')
DBNAME = os.environ.get('ENERGY_DB_NAME', 'thingsboard')

# 保持关闭的唯一页面：它自己就是场站管理
EXCLUDE_TITLES = {'组织与场站'}

# 只动这两个键，其它一律不碰
#
# <h3>为什么不去“收敛”多余键</h3>
# 试过把 settings 统一成三个键，实测发现 `stateControllerId: "entity"` 是
# TB 的状态控制器类型，删掉后 state 广播会变 —— 客户的切换不再下发到部件。
# `showFilters` / `hideToolbar` / `suppressLoadingBar` 也各自有语义。
# 本脚本的职责只有一个：让顶栏场站开关可用，所以只碰这两项。
# ★ 只有显式写成 false 才是“折叠”，**不设置 = 默认常显**（实测：综合能耗没有
#   这个键，顶栏场站照样一直显示）。所以只修 false，不要给每个看板补 True。
REQUIRED = {
    'showStationSelect': True,   # 顶栏场站开关
}


def psql(sql, stdin=None):
    cmd = ['docker', 'exec', '-i', DB, 'psql', '-U', 'postgres', '-d', DBNAME, '-tA']
    if stdin is None:
        cmd += ['-c', sql]
    r = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(r.stderr.strip() or 'psql 失败')
    return r.stdout.strip()


def load(include_tenant=False):
    where = 'customer_id IS NOT NULL' if not include_tenant else 'TRUE'
    rows = psql(f"""SELECT replace(encode(convert_to(configuration,'UTF8'),'base64'),E'\\n','')
                       ||E'\\x01'||title||E'\\x01'||id
                    FROM dashboard WHERE {where} ORDER BY title, id""")
    out = []
    for line in rows.split('\n'):
        parts = line.split('\x01')
        if len(parts) != 3:
            continue
        b64, title, did = parts
        conf = json.loads(base64.b64decode(b64).decode())
        out.append((title, did, conf))
    return out


def push(did, conf):
    b64 = base64.b64encode(json.dumps(conf, ensure_ascii=False).encode()).decode()
    psql(None, stdin=f"UPDATE dashboard SET configuration=convert_from(decode('{b64}','base64'),'UTF8')"
                     f" WHERE id='{did}';")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--apply', action='store_true', help='真的写库；不加只预演')
    ap.add_argument('--all', action='store_true', help='含租户级看板（默认只改客户级）')
    args = ap.parse_args()

    changed = 0
    titles = set()
    # ★ 去重只用于「打印一次」，**不能跳过写入**（2026-11-07 修）。
    #
    #   原实现是 `if title in seen: continue`。而 load() 按 ORDER BY title, id 取行，
    #   加 --all 时同一 title 至少有「租户级模板」和「客户副本」两行 ——
    #   只有先出现的那行被改，另一行被 seen 挡掉。
    #   实测后果：跑完 --all 后客户副本是 true、模板仍是 false，
    #   租户登录看「能耗概览」右上角就是没有场站开关（客户原话
    #   「之前是有的，改回来」）。
    for title, did, conf in load(include_tenant=args.all):
        if title in EXCLUDE_TITLES:
            continue
        first_of_title = title not in titles
        titles.add(title)
        cur = conf.get('settings') or {}
        # ★ 只修**显式 false**，不补 None（2026-11-07 修，与 REQUIRED 上方注释对齐）。
        #
        #   原写法是 `cur.get(k) != v`，None != True → 也会补成 True。
        #   --all 时就会把「客户能源档案」「峰谷时段」这类**租户专用运营页**
        #   也塞上场站开关 —— 它们配的是跨客户的厂商/型号/费率主数据，
        #   挂一个「当前场站」只会让客户以为列表被筛过（与 home.component.ts
        #   对租户一律隐藏顶栏的理由完全相同）。
        #   只修 false 还有一个好处：不动「本来就没设」的页面，不制造版本噪音。
        need = {k: v for k, v in REQUIRED.items()
                if cur.get(k) is False and v is True}
        also_missing = [k for k, v in REQUIRED.items()
                        if k not in cur and v is True]
        # toolbarAlwaysOpen 只修显式的 false（None = TB 默认常显，补 True 是噪音）
        if cur.get('toolbarAlwaysOpen') is False:
            need['toolbarAlwaysOpen'] = True
        if not need:
            if first_of_title:
                if also_missing:
                    print(f'  跳过  {title:16s} 未设置该键（默认折叠，不主动补）')
                else:
                    print(f'  跳过  {title:16s} 已符合')
            continue
        bits = [f'{k}: {cur.get(k)!r} → {v!r}' for k, v in need.items()]
        # 必须逐行列出来：同一标题的模板与客户副本可能是**不同**的值
        # （实测「能耗概览」客户副本 true、模板 false）。
        # 只打第一行会让人以为「已符合」，而真正要改的那份被藏在下面。
        print(f'  {"改动" if args.apply else "待改"}  {title:16s} [{did[:8]}] ' + '; '.join(bits))
        if args.apply:
            conf.setdefault('settings', {})
            conf['settings'].update(REQUIRED)
            if need.get('toolbarAlwaysOpen'):
                conf['settings']['toolbarAlwaysOpen'] = True
            push(did, conf)
        changed += 1

    print()
    verb = '已改' if args.apply else '将改'
    print(f'{verb} {changed} 个看板（共 {len(titles)} 个标题）')
    if not args.apply and changed:
        print('加 --apply 才会真的写库')


if __name__ == '__main__':
    main()
