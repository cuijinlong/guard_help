#!/usr/bin/env python3
"""客户菜单清理：删「参数报表」与「平台自检」，把「仪表板」提到「组织」上面。

## 为什么要单独一个脚本

客户实际看到的菜单是数据库里的 **CustomMenu**（业务导航·能源管理），
不是前端 menu.models.ts 的静态定义 —— 前端那套客户块只有在
「客户没有绑定自定义菜单、且租户下没有 CUSTOMER 作用域默认菜单」时才兜底。
所以在 UI 代码里删掉菜单项，对已有客户**无效**，必须改库。

`EnergyMenuInstaller`（后端）在新建客户 / repair-init 时会生成菜单，
那里也要同步改 —— 两边都改才不会被覆盖回去。

## 用法

    python3 38-customer-menu-cleanup.py --check     # 只看会改什么
    python3 38-customer-menu-cleanup.py            # 打补丁（幂等）
    python3 38-customer-menu-cleanup.py --restore  # 从备份还原

幂等：重复跑不会重复删除或反复移动。

## 这一轮改了什么（2026-11-13 客户要求）

1. 「综合报表 ▾ 参数报表」→ 删掉菜单入口（看板与后端接口保留）
2. 「平台自检」一级入口 → 删掉（客户在那一页只能看清单，修不了）
3. 「仪表板」→ 从菜单最后一项提到「组织」上面
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

DB_CONTAINER = os.environ.get('PG_CONTAINER', 'energy-postgres')
DB_USER = os.environ.get('PG_USER', 'postgres')
DB_NAME = os.environ.get('PG_DB', 'thingsboard')
BAK_DIR = os.path.expanduser('~/.energy-customer-menu-bak')

DROP_CHILD = '参数报表'          # 从「综合报表」里删的子项
DROP_TOP = '平台自检'            # 从一级删的项
MOVE_ITEM = '仪表板'             # 要移动的项
ANCHOR = '组织'                  # 移到它上面


def psql(sql: str) -> str:
    r = subprocess.run(
        ['docker', 'exec', DB_CONTAINER, 'psql', '-U', DB_USER, '-d', DB_NAME, '-tAc', sql],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f'psql 失败：{r.stderr[:400]}')
    return r.stdout


def menu_ids() -> list[str]:
    """所有 CUSTOMER 作用域的菜单（客户实际用的就是这些）。"""
    out = psql("SELECT id FROM custom_menu WHERE scope='CUSTOMER' ORDER BY created_time")
    return [x.strip() for x in out.splitlines() if x.strip()]


def plan(cfg: dict) -> tuple[dict, list[str]]:
    items = cfg.get('items') or []
    notes = []

    for it in items:
        if (it.get('name') or '').strip() == '综合报表' and it.get('pages'):
            before = len(it['pages'])
            it['pages'] = [p for p in it['pages'] if (p.get('name') or '').strip() != DROP_CHILD]
            if len(it['pages']) != before:
                notes.append(f'删 {DROP_CHILD}（综合报表下 {before} → {len(it["pages"])} 项）')

    before = len(items)
    items = [i for i in items if (i.get('name') or '').strip() != DROP_TOP]
    if len(items) != before:
        notes.append(f'删一级项 {DROP_TOP}')

    mv = next((i for i in items if (i.get('name') or '').strip() == MOVE_ITEM), None)
    anchor = next((i for i in items if (i.get('name') or '').strip() == ANCHOR), None)
    if mv and anchor:
        mi, ai = items.index(mv), items.index(anchor)
        if mi > ai:
            items.pop(mi)
            items.insert(items.index(anchor), mv)
            notes.append(f'{MOVE_ITEM} 移到 {ANCHOR} 之前')
    elif not mv:
        notes.append(f'! 没有「{MOVE_ITEM}」项')
    elif not anchor:
        notes.append(f'! 没有「{ANCHOR}」项')

    cfg['items'] = items
    return cfg, notes


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true', help='只报告，不写库')
    ap.add_argument('--restore', action='store_true', help='从备份还原')
    args = ap.parse_args()

    os.makedirs(BAK_DIR, exist_ok=True)
    ids = menu_ids()
    if not ids:
        sys.exit('库里没有 CUSTOMER 作用域的菜单，无需处理')

    if args.restore:
        for cid in ids:
            bak = os.path.join(BAK_DIR, f'{cid}.json')
            if not os.path.exists(bak):
                print(f'  {cid[:8]} 没有备份，跳过')
                continue
            body = open(bak, encoding='utf-8').read()
            psql(f"UPDATE custom_menu SET config = $c${body}$c$ WHERE id='{cid}'")
            print(f'  {cid[:8]} 已还原')
        return

    for cid in ids:
        raw = psql(f"SELECT config FROM custom_menu WHERE id='{cid}'").strip()
        if not raw:
            print(f'  {cid[:8]} config 为空，跳过')
            continue
        cfg = json.loads(raw)
        new, notes = plan(json.loads(raw))   # 深拷贝：plan 会原地改

        if not notes:
            print(f'  {cid[:8]} 无需改动')
            continue
        if all(n.startswith('!') for n in notes):
            print(f'  {cid[:8]} 结构不符（{"; ".join(notes)}），跳过')
            continue

        print(f'  {cid[:8]}：')
        for n in notes:
            print(f'      {n}')
        if args.check:
            continue

        bak = os.path.join(BAK_DIR, f'{cid}.json')
        if not os.path.exists(bak):        # 只在首次改动前备份，不覆盖原始版本
            open(bak, 'w', encoding='utf-8').write(raw)
            print(f'      备份 → {bak}')

        body = json.dumps(new, ensure_ascii=False, separators=(',', ':'))
        psql(f"UPDATE custom_menu SET config = $c${body}$c$ WHERE id='{cid}'")
        print('      已写库')

    if args.check:
        print('\n（--check：没有写库）')


if __name__ == '__main__':
    main()
