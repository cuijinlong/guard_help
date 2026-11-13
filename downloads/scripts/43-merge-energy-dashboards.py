#!/usr/bin/env python3
"""合并重复的能源管理看板 —— 一份租户级模板 + assigned_customers，绝不按客户复制。

背景（2026-11-13 客户提出）
    平台有 N 个客户就有 N+1 份同名看板：租户一份、每个客户一份。
    新增客户要复制一整套，改一处部件配置要改 N 遍，副本之间还会漂移。
    TB 原生就支持「租户级看板 + assigned_customers 指定可见客户」，
    根本不需要复制。

本脚本做四件事
    ① 每个标题只保留一份看板（优先租户级；没有租户级就把客户那份提升为租户级）
    ② 把「场站 / 用电分项 / 分析范围 / 实时默认范围 / 电能品种」这些
       写死某个客户资产 id 的别名改成 assetType —— 运行时按当前用户权限解析，
       客户 A 只拿到客户 A 的场站（数据权限由 TB RBAC 保证，已实测）
    ③ 给保留的看板设 assigned_customers = 全部客户（TB 原生可见性）
    ④ 客户菜单统一指向合并后的看板 id，多余的菜单副本删除

用法
    python3 43-merge-energy-dashboards.py --audit          # 只读：列出计划与内容差异
    python3 43-merge-energy-dashboards.py --dry-run        # 打印将要执行的 SQL，不落库
    python3 43-merge-energy-dashboards.py --apply          # 执行（自动先备份）
    python3 43-merge-energy-dashboards.py --restore DIR    # 从备份回滚

安全设计
    · --apply 之前**强制**先备份到 ~/.energy-dashboard-bak/merge-<时间戳>/
    · 内容不一致的标题默认**跳过**（只有 --force 才合并），避免丢掉客户专属配置
    · 全程只改 dashboard / custom_menu 两张表，不动 widget_type
"""

import argparse
import json
import os
import subprocess
import sys
import time

PG = os.environ.get("ENERGY_PG_CONTAINER", "energy-postgres")
DB = os.environ.get("ENERGY_PG_DB", "thingsboard")
USER = os.environ.get("ENERGY_PG_USER", "postgres")
BAK_ROOT = os.path.expanduser("~/.energy-dashboard-bak")

# 写死客户资产 id 的别名 → 按 assetType 动态解析。
#
# ★ 2026-11-13 修正：不能只按别名名猜。
#   同一个名字在不同看板里指向的占位符不一样 —— 比如「场站」在「能耗概览」里是
#   05a1（场站），在「能源流向」里是 05a2（组织）。按名字统一改成 assetType=场站，
#   会把「组织汇总」错改成「单个场站」，数据直接变少一半。
#
#   所以真正的映射以**模板 JSON** 为准（45-align-dashboard-templates.py 已把它们
#   改成 assetType）。这里的表只作为「模板里找不到这个标题」时的兜底。
ALIAS_RULES = {
    "场站": {"type": "assetType", "assetTypes": ["场站"]},
    "用电分项": {"type": "assetType", "assetTypes": ["energy_item_library"]},
    "分析范围（用能区域）": {"type": "assetType", "assetTypes": ["energy_area_library"]},
    "实时默认范围（电能）": {"type": "assetType", "assetTypes": ["场站"]},
    "电能品种": {
        "type": "assetType",
        "assetTypes": ["default"],
        "assetNameFilter": "电能",
    },
    "按分组维度": {
        "type": "assetType",
        "assetTypes": [
            "energy_item_library",
            "energy_area_library",
            "energy_usage_library",
            "energy_space_library",
        ],
    },
}

# 保持原样的别名（公共主数据 / 本身就是动态类型），改反而会破坏
KEEP_ALIASES = {
    "能源参数字典",
    "能源品种（能源参数字典）",
    "所有设备",       # entityType: DEVICE，天然按权限隔离
    "按分组维度",     # entityList 指向公共字典 UUID
}


def psql(sql, tuples_only=True):
    cmd = ["docker", "exec", PG, "psql", "-U", USER, "-d", DB]
    if tuples_only:
        cmd.append("-tA")
    cmd += ["-c", sql]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"psql 失败:\n{r.stderr}\nSQL: {sql[:300]}")
    return r.stdout


def q_str(s):
    if s is None:
        return "NULL"
    return "'" + s.replace("'", "''") + "'"


def load_dashboards():
    raw = psql(
        "SELECT json_agg(json_build_object("
        "'id', id::text, 'title', title, 'customerId', customer_id::text,"
        "'config', configuration, 'assigned', assigned_customers)) "
        "FROM dashboard"
    )
    return json.loads(raw or "[]")


def load_customers():
    raw = psql("SELECT json_agg(json_build_object('id', id::text, 'title', title)) FROM customer")
    return json.loads(raw or "[]")


def load_menus():
    raw = psql(
        "SELECT json_agg(json_build_object('id', id::text, 'name', name,"
        "'scope', scope, 'assignee', assignee_type, 'config', config)) FROM custom_menu"
    )
    return json.loads(raw or "[]")


# ---------------------------------------------------------------- 归一化对比

def _norm_filter(f):
    if not isinstance(f, dict):
        return
    if f.get("type") == "singleEntity" and f.get("singleEntity"):
        f["singleEntity"]["id"] = "PLACEHOLDER"
    elif f.get("type") == "entityList" and f.get("entityList"):
        f["entityList"] = ["PLACEHOLDER"] * len(f["entityList"])


def norm_config(cfg_str):
    """把看板配置归一化，便于判断两份副本是否只是「引用了不同客户的实体」。

    三处随机/客户相关的东西都要抹平，否则每份副本都长得不一样：
      ① entityAliases 的 **key 是随机 UUID**（每次复制看板都重新生成）
      ② alias filter 里写死的实体 id
      ③ 各部件 datasources[].entityAliasId 指向上面的随机 UUID
    三者必须一起归一化 —— 只做 ①② 会漏掉 ③，states/widgets 立刻报差异。
    """
    if not cfg_str:
        return "{}"
    d = json.loads(cfg_str)
    raw_aliases = d.get("entityAliases") or {}

    # ① 按 alias 名字分组；同名（「能耗洞察」有 4 个「场站」）按 filter 内容排序定序
    groups = {}
    for k in sorted(raw_aliases):
        v = raw_aliases[k]
        name = v.get("alias") or k
        vv = json.loads(json.dumps(v, ensure_ascii=False))
        _norm_filter(vv.get("filter"))
        groups.setdefault(name, []).append(vv)

    norm_aliases = {}
    id_to_name = {}
    for name in sorted(groups):
        lst = groups[name]
        lst.sort(key=lambda x: json.dumps(x.get("filter"), sort_keys=True, ensure_ascii=False))
        for i, vv in enumerate(lst):
            nk = f"{name}#{i}"
            norm_aliases[nk] = vv

    for k, v in raw_aliases.items():
        name = v.get("alias") or k
        same = groups.get(name) or []
        idx = 0
        if len(same) > 1:
            target = json.loads(json.dumps(v, ensure_ascii=False))
            _norm_filter(target.get("filter"))
            same_sorted = sorted(
                same, key=lambda x: json.dumps(x.get("filter"), sort_keys=True, ensure_ascii=False)
            )
            target_s = json.dumps(target.get("filter"), sort_keys=True, ensure_ascii=False)
            for i, sv in enumerate(same_sorted):
                if json.dumps(sv.get("filter"), sort_keys=True, ensure_ascii=False) == target_s:
                    idx = i
                    break
        id_to_name[k] = f"{name}#{idx}"

    d["entityAliases"] = norm_aliases
    if "entityAliasOrder" in d:
        d["entityAliasOrder"] = sorted(norm_aliases)

    # ③ 把部件里对 alias 的引用换成归一化名字
    def rewrite(o):
        if isinstance(o, dict):
            for kk, vv in list(o.items()):
                if kk == "entityAliasId" and isinstance(vv, str) and vv in id_to_name:
                    o[kk] = id_to_name[vv]
                else:
                    rewrite(vv)
        elif isinstance(o, list):
            for x in o:
                rewrite(x)

    for key in ("states", "widgets", "settings"):
        if key in d:
            rewrite(d[key])

    return json.dumps(d, ensure_ascii=False, sort_keys=True)


def diff_keys(a, b):
    """粗略指出差异出现在哪几个顶层键，供人工判断。"""
    da, db = json.loads(a), json.loads(b)
    keys = set(da) | set(db)
    return sorted(k for k in keys if json.dumps(da.get(k), sort_keys=True) != json.dumps(db.get(k), sort_keys=True))


# ---------------------------------------------------------------- 计划

def load_template_aliases():
    """读看板模板里的 entityAliases：title -> {aliasName: [filter, ...]}。

    模板是别名的**权威来源**（45-align-dashboard-templates.py 已把占位符改成
    assetType）。合并时按标题对齐，就不会把「组织」错改成「场站」。
    """
    import glob as _glob

    here = os.path.dirname(os.path.abspath(__file__))
    tdir = os.path.join(here, "..", "..", "..", "guard-server", "src", "main",
                        "data", "json", "tenant", "dashboards")
    out = {}
    for f in _glob.glob(os.path.join(tdir, "*.json")):
        try:
            d = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        title = d.get("title")
        if not title:
            continue
        m = {}
        for v in ((d.get("configuration") or {}).get("entityAliases") or {}).values():
            if v.get("alias"):
                m.setdefault(v["alias"], []).append(v.get("filter"))
        out[title] = m
    return out


def build_plan(dashboards, customers, force=False, tpl_aliases=None):
    by_title = {}
    for d in dashboards:
        by_title.setdefault(d["title"] or "(无标题)", []).append(d)

    cust_by_id = {c["id"]: c["title"] for c in customers}
    assigned_all = json.dumps(
        [
            {
                "customerId": {"entityType": "CUSTOMER", "id": c["id"]},
                "title": c["title"],
                "public": False,
            }
            for c in customers
        ],
        ensure_ascii=False,
    )

    actions = []
    skipped = []

    for title, group in sorted(by_title.items()):
        if len(group) < 2:
            continue

        tenant_ones = [d for d in group if not d["customerId"]]
        # 有租户级 → 用它；否则优先平台演示中心那份（数据最全），再否则第一份
        if tenant_ones:
            keep = tenant_ones[0]
        else:
            demo = [d for d in group if cust_by_id.get(d["customerId"]) == "平台演示中心"]
            keep = (demo or group)[0]

        drop = [d for d in group if d["id"] != keep["id"]]

        # 内容一致性检查：归一化后应与 keep 相同
        base = norm_config(keep["config"])
        diffs = []
        for d in drop:
            if norm_config(d["config"]) != base:
                diffs.append(
                    {
                        "id": d["id"],
                        "owner": cust_by_id.get(d["customerId"], "(租户)"),
                        "keys": diff_keys(keep["config"], d["config"]),
                    }
                )

        if diffs and not force:
            skipped.append({"title": title, "reason": "副本内容不一致（加 --force 仍可合并）", "diffs": diffs})
            continue

        # 别名迁移：优先用模板里的定义（已改成 assetType），否则回退到规则表
        cfg = json.loads(keep["config"] or "{}")
        alias_changes = []
        tpl = (tpl_aliases or {}).get(title) or {}
        for aid, av in (cfg.get("entityAliases") or {}).items():
            name = av.get("alias")
            if name in KEEP_ALIASES:
                continue
            want = None
            cands = tpl.get(name) or []
            if cands:
                uniq = {json.dumps(c, sort_keys=True) for c in cands}
                if len(uniq) == 1:
                    want = cands[0]
            if want is None:
                want = ALIAS_RULES.get(name)
            if want is None:
                continue
            old = av.get("filter")
            if json.dumps(old, sort_keys=True) == json.dumps(want, sort_keys=True):
                continue
            av["filter"] = want
            alias_changes.append((name, old, want))

        actions.append(
            {
                "title": title,
                "keep": keep,
                "promote": bool(keep["customerId"]),
                "drop": drop,
                "aliasChanges": alias_changes,
                "config": json.dumps(cfg, ensure_ascii=False),
                "assigned": assigned_all,
                "diffs": diffs,
            }
        )

    return actions, skipped, assigned_all


def build_menu_plan(menus, actions):
    """把菜单里的 dashboardId 换成合并后的 id；合并成一份 ALL 菜单。"""
    id_map = {}
    for a in actions:
        id_map[a["keep"]["id"]] = a["keep"]["id"]
        for d in a["drop"]:
            id_map[d["id"]] = a["keep"]["id"]

    energy_menus = [
        m
        for m in menus
        if m.get("scope") == "CUSTOMER" and "能源管理" in (m["name"] or "")
    ]
    others = [m for m in menus if m not in energy_menus]

    def rewrite(obj):
        if isinstance(obj, dict):
            for k, v in list(obj.items()):
                if k == "dashboardId" and isinstance(v, str) and v in id_map:
                    obj[k] = id_map[v]
                else:
                    rewrite(v)
        elif isinstance(obj, list):
            for v in obj:
                rewrite(v)

    picked = None
    for m in energy_menus:
        if m["assignee"] == "ALL":
            picked = m
            break
    if picked is None and energy_menus:
        picked = energy_menus[0]

    if picked is None:
        return None, others + energy_menus

    cfg = json.loads(picked["config"] or "{}")
    rewrite(cfg)
    remaining = [m for m in energy_menus if m["id"] != picked["id"]]
    return (
        {"keep": picked, "config": json.dumps(cfg, ensure_ascii=False), "drop": remaining},
        others,
    )


# ---------------------------------------------------------------- 输出

def print_report(actions, skipped, menu_plan, customers):
    print("=" * 72)
    print(f"  客户 {len(customers)} 个：" + " / ".join(c["title"] for c in customers))
    print("=" * 72)

    total_drop = sum(len(a["drop"]) for a in actions)
    print(f"\n可合并标题 {len(actions)} 个，将删除副本 {total_drop} 块\n")

    for a in actions:
        owner = "租户级" if not a["keep"]["customerId"] else "提升为客户级→租户级"
        print(f"· {a['title']}  [{owner}]  保留 {a['keep']['id'][:8]}，删 {len(a['drop'])} 份")
        for d in a["drop"]:
            print(f"      删除 {d['id'][:8]}")
        if a["promote"]:
            print("      ⚠ 该看板原为客户级，将置 customer_id = NULL")
        for name, old, new in a["aliasChanges"]:
            print(f"      别名「{name}」→ {new['type']} {new.get('assetTypes') or new.get('assetNameFilter','')}")
        if a["diffs"]:
            print(f"      ⚠ 强制合并（{len(a['diffs'])} 份内容有差异，差异键已记录到备份）")

    if skipped:
        print(f"\n跳过 {len(skipped)} 个标题（内容不一致，需 --force）：\n")
        for s in skipped:
            print(f"· {s['title']}  — {s['reason']}")
            for d in s["diffs"]:
                print(f"      {d['owner']:12s} {d['id'][:8]}  差异键={d['keys']}")

    if menu_plan:
        print(f"\n菜单：保留「{menu_plan['keep']['name']}」"
              f"(assignee={menu_plan['keep']['assignee']})，"
              f"删除 {len(menu_plan['drop'])} 份重复菜单")
        for m in menu_plan["drop"]:
            print(f"      删除菜单 {m['id'][:8]} assignee={m['assignee']}")
    else:
        print("\n菜单：未找到能源管理菜单，跳过")


# ---------------------------------------------------------------- 执行

def do_backup(dashboards, menus):
    ts = time.strftime("%Y%m%d-%H%M%S")
    d = os.path.join(BAK_ROOT, f"merge-{ts}")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "dashboards.json"), "w", encoding="utf-8") as f:
        json.dump(dashboards, f, ensure_ascii=False, indent=1)
    with open(os.path.join(d, "custom_menu.json"), "w", encoding="utf-8") as f:
        json.dump(menus, f, ensure_ascii=False, indent=1)
    print(f"  ✓ 备份 → {d}")
    return d


def do_apply(actions, menu_plan):
    print("\n---- 执行 ----")
    for a in actions:
        kid = a["keep"]["id"]
        sets = [f"configuration = {q_str(a['config'])}", f"assigned_customers = {q_str(a['assigned'])}"]
        if a["promote"]:
            sets.append("customer_id = NULL")
        psql(f"UPDATE dashboard SET {', '.join(sets)} WHERE id = {q_str(kid)}")
        n_alias = len(a["aliasChanges"])
        print(f"  ✓ {a['title']:16s} 保留 {kid[:8]}  别名改 {n_alias} 处"
              + ("  并提升为租户级" if a["promote"] else ""))

        for d in a["drop"]:
            psql(f"DELETE FROM dashboard WHERE id = {q_str(d['id'])}")
        if a["drop"]:
            print(f"      删除副本 {len(a['drop'])} 块")

    if menu_plan:
        psql(
            "UPDATE custom_menu SET config = "
            f"{q_str(menu_plan['config'])}, assignee_type = 'ALL' "
            f"WHERE id = {q_str(menu_plan['keep']['id'])}"
        )
        print(f"  ✓ 菜单「{menu_plan['keep']['name']}」已重写并置 assignee=ALL")
        for m in menu_plan["drop"]:
            psql(f"DELETE FROM custom_menu WHERE id = {q_str(m['id'])}")
            print(f"      删除菜单 {m['id'][:8]}")


def do_restore(dirpath):
    dpath = os.path.join(dirpath, "dashboards.json")
    mpath = os.path.join(dirpath, "custom_menu.json")
    if not os.path.exists(dpath):
        sys.exit(f"备份不存在：{dpath}")
    dashboards = json.load(open(dpath, encoding="utf-8"))
    print(f"回滚 {len(dashboards)} 块看板…")
    for d in dashboards:
        psql(
            "INSERT INTO dashboard (id, created_time, title, configuration, assigned_customers,"
            " tenant_id, customer_id) VALUES ("
            f"{q_str(d['id'])}, {int(time.time()*1000)}, {q_str(d['title'])},"
            f" {q_str(d['config'])}, {q_str(d['assigned'])},"
            " '13814000-1dd2-11b2-8080-808080808080',"
            f" {q_str(d['customerId'])}) ON CONFLICT (id) DO UPDATE SET"
            " title = EXCLUDED.title, configuration = EXCLUDED.configuration,"
            " assigned_customers = EXCLUDED.assigned_customers, customer_id = EXCLUDED.customer_id"
        )
    if os.path.exists(mpath):
        menus = json.load(open(mpath, encoding="utf-8"))
        print(f"回滚 {len(menus)} 份菜单…")
        for m in menus:
            psql(
                "INSERT INTO custom_menu (id, created_time, tenant_id, customer_id, name, scope,"
                " assignee_type, config) VALUES ("
                f"{q_str(m['id'])}, {int(time.time()*1000)},"
                " '13814000-1dd2-11b2-8080-808080808080',"
                " '13814000-1dd2-11b2-8080-808080808080',"
                f" {q_str(m['name'])}, {q_str(m['scope'])}, {q_str(m['assignee'])},"
                f" {q_str(m['config'])}) ON CONFLICT (id) DO UPDATE SET"
                " config = EXCLUDED.config, assignee_type = EXCLUDED.assignee_type"
            )
    print("✓ 回滚完成")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audit", action="store_true", help="只读审计，列出计划")
    ap.add_argument("--dry-run", action="store_true", help="打印计划，不落库")
    ap.add_argument("--apply", action="store_true", help="执行迁移（自动备份）")
    ap.add_argument("--restore", metavar="DIR", help="从备份目录回滚")
    ap.add_argument("--force", action="store_true", help="内容不一致也合并")
    args = ap.parse_args()

    if args.restore:
        do_restore(args.restore)
        return

    if not (args.audit or args.dry_run or args.apply):
        ap.print_help()
        return

    dashboards = load_dashboards()
    customers = load_customers()
    menus = load_menus()
    print(f"读入 {len(dashboards)} 块看板 / {len(customers)} 个客户 / {len(menus)} 份菜单")

    actions, skipped, _ = build_plan(dashboards, customers, force=args.force,
                                     tpl_aliases=load_template_aliases())
    menu_plan, _ = build_menu_plan(menus, actions)
    print_report(actions, skipped, menu_plan, customers)

    if args.apply:
        if not actions:
            print("\n没有可合并项，退出")
            return
        do_backup(dashboards, menus)
        do_apply(actions, menu_plan)
        print("\n✓ 完成。下一步：")
        print("   1) 硬刷新浏览器，用客户账号打开「能耗概览」等看板")
        print("   2) 确认数据是自己的，不是别的客户的")
        print("   3) 不一致就 --restore 回滚")


if __name__ == "__main__":
    main()
