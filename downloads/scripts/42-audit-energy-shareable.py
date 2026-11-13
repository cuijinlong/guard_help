#!/usr/bin/env python3
"""能源看板「能否一份共享」的审计 —— 以及孤岛部件清单。

对应 AGENTS.md 的铁律「★ 能源看板一份共享，绝不按客户复制副本」。

## 三项检查

1. **纯 datasource 部件**（必须为 0 才能合并看板）
   这些部件把 entityAlias 的 id 直接塞进 TB 实体查询 URL。
   看板合并成一份后所有客户用同一个 id → A 客户看到 B 客户的表。

2. **重复看板**（同一标题多份副本）
   每多一份 = 多一份维护债。要按客户区分就改后端过滤，
   不是复制看板。

3. **孤岛部件**（没有任何看板引用）
   要么是废弃的，要么是漏挂的。前者删、后者挂上去。

## 用法

    python3 42-audit-energy-shareable.py            # 全部检查
    python3 42-audit-energy-shareable.py --datasource
    python3 42-audit-energy-shareable.py --dashboards
    python3 42-audit-energy-shareable.py --orphans
    python3 42-audit-energy-shareable.py --json

退出码：0 = 全部合规（或只查不判），1 = 有不合规项。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

DB_CONTAINER = os.environ.get('PG_CONTAINER', 'energy-postgres')
DB_USER = os.environ.get('PG_USER', 'postgres')
DB_NAME = os.environ.get('PG_DB', 'thingsboard')


def psql(sql: str) -> str:
    r = subprocess.run(
        ['docker', 'exec', DB_CONTAINER, 'psql', '-U', DB_USER, '-d', DB_NAME, '-tAc', sql],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f'psql 失败：{r.stderr[:400]}')
    return r.stdout


def all_widget_scripts() -> dict[str, dict]:
    """{fqn: descriptor}，只取能源相关。"""
    out = {}
    for line in psql("SELECT fqn || E'\\x01' || descriptor::text FROM widget_type "
                     "WHERE fqn LIKE '%energy%'").strip().splitlines():
        if '\x01' not in line:
            continue
        fqn, raw = line.split('\x01', 1)
        try:
            out[fqn.strip()] = json.loads(raw)
        except Exception:
            pass
    return out


def check_datasource() -> list[dict]:
    """纯 datasource（有 subscribe/onDataUpdated，但不调后端 API）的部件。"""
    bad = []
    for fqn, desc in sorted(all_widget_scripts().items()):
        js = desc.get('controllerScript') or ''
        if len(js) < 200:
            continue
        has_api = bool(re.search(r'/api/(?:energy|pq)', js))
        has_ds = bool(re.search(r'\bsubscribe\s*\(|onDataUpdated|datasources\s*\[', js))
        if has_ds and not has_api:
            bad.append({'fqn': fqn, 'name': desc.get('name') or ''})
    return bad


def check_dashboards() -> list[dict]:
    """同标题多份副本。"""
    rows = []
    for line in psql(
            "SELECT d.title || E'\\x01' || coalesce(c.title,'【租户级】') || E'\\x01' || d.id::text "
            "FROM dashboard d LEFT JOIN customer c ON c.id = d.customer_id ORDER BY d.title").strip().splitlines():
        p = line.split('\x01')
        if len(p) == 3:
            rows.append({'title': p[0], 'owner': p[1], 'id': p[2]})
    by_title: dict[str, list] = {}
    for r in rows:
        by_title.setdefault(r['title'], []).append(r)
    return [{'title': t, 'count': len(v), 'copies': v}
            for t, v in sorted(by_title.items()) if len(v) > 1]


def check_orphans() -> list[dict]:
    """没有任何看板引用的能源部件。"""
    dash_cfg = psql("SELECT configuration FROM dashboard")
    scripts = all_widget_scripts()
    out = []
    for fqn, desc in sorted(scripts.items()):
        short = fqn.split('.', 1)[-1]
        # 看板里 typeFullFqn 形如 "bundleAlias.fqn" 或 "system.bundleAlias.fqn"
        if fqn in dash_cfg or f'system.{fqn}' in dash_cfg or short in dash_cfg:
            continue
        out.append({'fqn': fqn, 'name': desc.get('name') or ''})
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--datasource', action='store_true')
    ap.add_argument('--dashboards', action='store_true')
    ap.add_argument('--orphans', action='store_true')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()
    run_all = not (args.datasource or args.dashboards or args.orphans)

    result, failed = {}, False

    if run_all or args.datasource:
        bad = check_datasource()
        result['pure_datasource'] = bad
        if bad:
            failed = True

    if run_all or args.dashboards:
        dup = check_dashboards()
        result['duplicate_dashboards'] = dup
        if dup:
            failed = True

    if run_all or args.orphans:
        orp = check_orphans()
        result['orphan_widgets'] = orp
        # 孤岛不算"不合规"，只是提示 —— 可能是留作后用
        # 但按铁律精神：要么删要么挂，不该长期躺在库里

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        sys.exit(1 if failed else 0)

    if 'pure_datasource' in result:
        bad = result['pure_datasource']
        if bad:
            print(f'✗ 纯 datasource 部件 {len(bad)} 个（合并看板后会串客户数据）：')
            for x in bad:
                print(f'    {x["fqn"]:44s} {x["name"]}')
            print('  → 必须改成走 /api/energy/*，由后端按身份过滤\n')
        else:
            print('✓ 没有纯 datasource 的能源部件（合并看板的数据前提已满足）\n')

    if 'duplicate_dashboards' in result:
        dup = result['duplicate_dashboards']
        if dup:
            total = sum(d['count'] for d in dup)
            print(f'✗ 重复看板：{len(dup)} 个标题共 {total} 块副本')
            for d in dup[:8]:
                owners = ' / '.join(c['owner'] for c in d['copies'])
                print(f'    {d["title"]:22s} ×{d["count"]}  {owners}')
            if len(dup) > 8:
                print(f'    … 另有 {len(dup)-8} 个标题')
            print('  → 应合并为一份，通过 assigned_customers 分发\n')
        else:
            print('✓ 没有重复看板\n')

    if 'orphan_widgets' in result:
        orp = result['orphan_widgets']
        if orp:
            print(f'! 孤岛部件 {len(orp)} 个（无任何看板引用）：')
            for x in orp:
                print(f'    {x["fqn"]:44s} {x["name"]}')
            print('  → 废弃的删掉，有用的挂到看板上\n')
        else:
            print('✓ 没有孤岛部件\n')

    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
