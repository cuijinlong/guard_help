#!/usr/bin/env python3
"""修「能耗概览」看板里两个非法 entityAlias id。

## 症状

租户打开「能耗概览」，5 个部件一直转圈，控制台/页面提示
`Failed to parse the payload`。抓 WebSocket 能看到前端发的订阅命令里：

    "entityFilter": {"type":"singleEntity",
                     "singleEntity":{"id":"<该客户用电分项根 id>","entityType":"ASSET"}}

`id` 是**中文占位文本**而不是 UUID。后端 Jackson 反序列化 UUID 直接失败，
整个订阅命令被丢弃 —— 于是这些部件永远收不到数据。

## 为什么只有这一块看板

全库扫描 91 块看板，只有 2 块「能耗概览」有这个问题：

| 看板 | 归属 | 别名 |
| --- | --- | --- |
| `0c90c6c0…` | zz客户B | 场站 / 用电分项 |
| `73dd2240…` | 租户级（模板） | 场站 / 用电分项 |

代码里 `EnergyBootstrapInstaller` 用的是 `00000000-0000-0000-0000-00000000xxxx`
形式的占位符（合法 UUID，前端当哨兵不当实体查），而这两块里是中文描述文本 ——
属于更早期遗留的脏数据。所以 `repairCustomerDashboards` 也修不了它：
那里判的是 `raw.contains("00000000-0000-0000-0000-00000000")`，中文占位符不匹配。

## 修法

按看板所属客户，替换成该客户的真实资产：

    场站      → <客户>·单相园区（第一个场站）
    用电分项  → 用能分项·<客户>（用能分项根）

租户级看板（customer_id 为空）用 `--demo-customer` 指定的客户（默认「平台演示中心」）
作为演示默认值 —— 模板本身要能让租户看到东西，否则无法自检。

## 用法

    python3 41-fix-energy-aliases.py --check     # 只报告
    python3 41-fix-energy-aliases.py            # 修（幂等）
    python3 41-fix-energy-aliases.py --restore  # 从备份还原
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
BAK_DIR = os.path.expanduser('~/.energy-dashboard-bak')

UUID_RE = re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
                     r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')

# 别名 → 该别名应该指向什么资产
WANT = {
    '场站': 'site',          # 客户的第一个场站
    '用电分项': 'item_root',  # 客户的用能分项根
}


def psql(sql: str) -> str:
    r = subprocess.run(
        ['docker', 'exec', DB_CONTAINER, 'psql', '-U', DB_USER, '-d', DB_NAME, '-tAc', sql],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f'psql 失败：{r.stderr[:400]}')
    return r.stdout


def one(sql: str) -> str | None:
    out = psql(sql).strip()
    return out.splitlines()[0].strip() if out.strip() else None


def find_customer_id(title: str) -> str | None:
    return one(f"SELECT id FROM customer WHERE title='{title}' LIMIT 1")


def find_asset(customer_id: str, name: str) -> str | None:
    return one("SELECT id FROM asset "
               f"WHERE customer_id='{customer_id}' AND name='{name}' LIMIT 1")


def resolve_targets(customer_id: str, customer_name: str) -> dict:
    """返回 {'site': id, 'item_root': id}。"""
    out = {}
    site = find_asset(customer_id, f'单相园区·{customer_name}')
    if not site:   # 命名规则兜底
        site = one("SELECT id FROM asset WHERE customer_id='%s' "
                   "AND name LIKE '%%园区%%' AND name NOT LIKE '%%区域%%' "
                   "AND name NOT LIKE '%%分项%%' AND name NOT LIKE '%%能耗类型%%' "
                   "AND name NOT LIKE '%%空间%%' AND name NOT LIKE '%%物理%%' "
                   "ORDER BY created_time LIMIT 1" % customer_id)
    if site:
        out['site'] = site

    item = find_asset(customer_id, f'用能分项·{customer_name}')
    if not item:
        item = one("SELECT id FROM asset WHERE customer_id='%s' "
                   "AND name LIKE '用能分项%%' ORDER BY length(name), created_time LIMIT 1" % customer_id)
    if item:
        out['item_root'] = item
    return out


def bad_aliases(cfg: dict) -> list[tuple[str, str, str]]:
    """[(aliasKey, aliasName, currentId)]，只列 id 不是合法 UUID 的。"""
    bad = []
    for k, v in (cfg.get('entityAliases') or {}).items():
        eid = ((v.get('filter') or {}).get('singleEntity') or {}).get('id')
        if eid and not UUID_RE.match(str(eid)):
            bad.append((k, v.get('alias') or '', str(eid)))
    return bad


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--restore', action='store_true')
    ap.add_argument('--demo-customer', default='平台演示中心',
                    help='租户级（模板）看板用哪个客户的数据作演示默认')
    args = ap.parse_args()

    os.makedirs(BAK_DIR, exist_ok=True)

    rows = [l for l in psql("SELECT id || '|' || coalesce(customer_id::text,'') "
                            "FROM dashboard ORDER BY title").strip().splitlines() if l.strip()]
    demos = find_customer_id(args.demo_customer)
    changed = 0

    for row in rows:
        did, cust = (row.split('|') + [''])[:2]
        raw = psql(f"SELECT configuration FROM dashboard WHERE id='{did}'").strip()
        if not raw:
            continue
        try:
            cfg = json.loads(raw)
        except Exception:
            continue
        bad = bad_aliases(cfg)
        if not bad:
            continue

        title = one(f"SELECT title FROM dashboard WHERE id='{did}'") or did[:8]

        if args.restore:
            bak = os.path.join(BAK_DIR, f'{did}.json')
            if not os.path.exists(bak):
                print(f'  {title}：没有备份，跳过')
                continue
            body = open(bak, encoding='utf-8').read().strip()
            psql(f"UPDATE dashboard SET configuration = $c${body}$c$ WHERE id='{did}'")
            print(f'  {title}：已还原')
            continue

        # 目标客户：看板自己的客户；租户级看板用演示客户
        if cust:
            cname = one(f"SELECT title FROM customer WHERE id='{cust}'") or ''
            targets = resolve_targets(cust, cname)
            who = cname
        else:
            cname = args.demo_customer
            targets = resolve_targets(demos, cname) if demos else {}
            who = f'{cname}（模板演示默认）'

        print(f'\n▸ {title}  [{did[:8]}]  客户={who}')
        miss = []
        for k, alias, eid in bad:
            kind = WANT.get(alias)
            if not kind:
                print(f'    ! 别名 {alias!r} 不认识，跳过（当前 {eid!r}）')
                miss.append(alias)
                continue
            new = targets.get(kind)
            if not new:
                print(f'    ✗ 别名 {alias!r} 找不到对应资产，跳过')
                miss.append(alias)
                continue
            cfg['entityAliases'][k]['filter']['singleEntity']['id'] = new
            print(f'    ✓ {alias:8s} {eid!r} → {new}')

        if miss:
            print(f'    跳过 {len(miss)} 项，其余不写库以免半修')
            continue
        if args.check:
            print('    （--check：未写库）')
            continue

        bak = os.path.join(BAK_DIR, f'{did}.json')
        if not os.path.exists(bak):
            open(bak, 'w', encoding='utf-8').write(raw)
        body = json.dumps(cfg, ensure_ascii=False, separators=(',', ':'))
        psql(f"UPDATE dashboard SET configuration = $c${body}$c$ WHERE id='{did}'")
        print('    已写库')
        changed += 1

    if not changed and not args.check and not args.restore:
        print('\n没有需要修的看板（幂等）')


if __name__ == '__main__':
    main()
