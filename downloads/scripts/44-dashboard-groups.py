#!/usr/bin/env python3
"""按菜单功能给仪表板建分组，并清掉分组里的垃圾数据。

背景（2026-11-13 客户）
    「如果是一个菜单下的功能的仪表板给我把分组加一下」
    「现在我看分组里面有大量的垃圾数据」

「分组」= TB 的仪表板实体分组（`entity_group.type = 'DASHBOARD'`），
前端 `/dashboards` 页面左侧按它分栏。

实测发现的两类垃圾
    ① 悬空关联：`relation` 指向已删除的 dashboard。实测 All 分组 92 条关联里
       58 条指向不存在的看板 —— 看板合并删副本后遗留下来。
    ② 空分组：销户/极简开户/模板验证等测试客户消失后，它们的
       `xxx Dashboards` 分组留在库里，前端照样列出来。

本脚本
    · `--audit`  列出分组现状与垃圾明细，不改任何东西
    · `--clean`  清悬空关联 + 删空分组（含「每客户一套」旧机制留下的两个）
    · `--group`  按菜单功能建分组并把看板块挂进去（幂等）
    · `--apply`  = --clean + --group

分组口径与 `EnergyMenuInstaller` 的菜单一一对应 —— 菜单怎么分组，
仪表板列表就怎么分组，两处不同步客户会看到「菜单里有、仪表板里找不到」。

不删除任何看板本身。想删看板请用 43-merge-energy-dashboards.py 或手工确认。
"""

import argparse
import json
import os
import subprocess
import sys
import time
import uuid

PG = os.environ.get("ENERGY_PG_CONTAINER", "energy-postgres")
DB = os.environ.get("ENERGY_PG_DB", "thingsboard")
USER = os.environ.get("ENERGY_PG_USER", "postgres")

# 菜单功能 → 该组下应有哪些看板（标题严格对齐 EnergyMenuInstaller）
MENU_GROUPS = {
    "能耗查询": ["实时能耗", "历史能耗", "抄表功能"],
    "能耗分析": ["峰谷分析", "分项能耗", "区域能耗", "我的账单"],
    "综合报表": ["基础报表", "手工填报"],
    "能耗优化": ["闲时能耗", "负载预测", "用能建议", "用能质量"],
    "设备管理": ["设备运维", "设备分组", "设备拓扑"],
    "空调管理": ["空调运行监控", "运行计划与配置", "每日复盘报告"],
}

# 顶层单块入口：不进分组，留在 All 里（菜单里也是一级菜单）
TOP_LEVEL = ["能耗概览", "告警事件", "综合能耗", "能源流向", "盘查报告", "节能记录", "组织与场站"]

# 租户运营台 / 特殊入口：不属于客户功能菜单，单列一组便于管理
TENANT_OPS = ["峰谷时段", "客户能源档案", "客户诊断报告"]

# 旧「每客户一套」机制留下的分组名，一律删除（看板已合并为租户级共享）
LEGACY_SUFFIX = " Dashboards"


def psql(sql, tuples_only=True):
    cmd = ["docker", "exec", PG, "psql", "-U", USER, "-d", DB]
    if tuples_only:
        cmd.append("-tA")
    cmd += ["-c", sql]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"psql 失败:\n{r.stderr}\nSQL: {sql[:400]}")
    return r.stdout


def q(s):
    return "NULL" if s is None else "'" + str(s).replace("'", "''") + "'"


def tenant_id():
    v = psql("SELECT id::text FROM tenant ORDER BY created_time LIMIT 1").strip()
    if not v:
        sys.exit("找不到租户")
    return v


def load_groups():
    raw = psql(
        "SELECT coalesce(json_agg(json_build_object("
        "'id', g.id::text, 'name', g.name, 'ownerType', g.owner_type, 'ownerId', g.owner_id::text,"
        "'total', (SELECT count(*) FROM relation r WHERE r.from_id=g.id AND r.from_type='ENTITY_GROUP'"
        "           AND r.relation_type='Contains' AND r.to_type='DASHBOARD'),"
        "'dangling', (SELECT count(*) FROM relation r WHERE r.from_id=g.id AND r.from_type='ENTITY_GROUP'"
        "           AND r.relation_type='Contains' AND r.to_type='DASHBOARD'"
        "           AND NOT EXISTS (SELECT 1 FROM dashboard d WHERE d.id=r.to_id))"
        ") ORDER BY g.name), '[]'::json) "
        "FROM entity_group g WHERE g.type='DASHBOARD'"
    )
    return json.loads(raw)


def load_dashboards():
    raw = psql(
        "SELECT coalesce(json_agg(json_build_object("
        "'id', d.id::text, 'title', d.title, 'owner', coalesce(c.title,'租户级')) "
        "ORDER BY d.title), '[]'::json) "
        "FROM dashboard d LEFT JOIN customer c ON c.id=d.customer_id"
    )
    return json.loads(raw)


def audit(groups, dashboards):
    print("=" * 70)
    print(f"  仪表板 {len(dashboards)} 块 / 分组 {len(groups)} 个")
    print("=" * 70)

    total_dangling = sum(g["dangling"] for g in groups)
    empty = [g for g in groups if g["total"] == 0]
    legacy = [g for g in groups if g["name"].endswith(LEGACY_SUFFIX)]

    print(f"\n悬空关联（指向已删看板）：{total_dangling} 条")
    for g in groups:
        if g["dangling"]:
            print(f"    {g['name']:32s} {g['dangling']} 条")

    if empty:
        print(f"\n空分组：{len(empty)} 个")
        for g in empty:
            print(f"    {g['name']}")

    if legacy:
        print(f"\n旧「每客户一套」机制的分组：{len(legacy)} 个")
        for g in legacy:
            print(f"    {g['name']}  (存活看板 {g['total'] - g['dangling']} 块)")

    titles = {d["title"] for d in dashboards}
    print("\n按菜单功能应建的分组：")
    for gname, members in MENU_GROUPS.items():
        missing = [m for m in members if m not in titles]
        exist = next((g for g in groups if g["name"] == gname), None)
        flag = f"已存在 {exist['total']} 块" if exist else "待建"
        print(f"    {gname:8s} {flag:14s} " + " / ".join(members))
        if missing:
            print(f"             ⚠ 库里没有这些看板：{missing}")

    grouped = {m for ms in MENU_GROUPS.values() for m in ms} | set(TOP_LEVEL) | set(TENANT_OPS)
    rest = sorted(titles - grouped)
    if rest:
        print(f"\n不属于任何菜单分组的看板（保留在 All，不删）：{len(rest)} 块")
        for t in rest:
            print(f"    {t}")


def clean(tid):
    print("\n---- 清理分组垃圾 ----")

    n = psql(
        "WITH del AS (DELETE FROM relation r USING entity_group g "
        "WHERE r.from_id=g.id AND r.from_type='ENTITY_GROUP' "
        "AND r.relation_type='Contains' AND r.to_type='DASHBOARD' AND g.type='DASHBOARD' "
        "AND NOT EXISTS (SELECT 1 FROM dashboard d WHERE d.id=r.to_id) RETURNING 1) "
        "SELECT count(*) FROM del"
    ).strip()
    print(f"  ✓ 清掉悬空关联 {n} 条")

    # 归属错位：看板被提升为租户级（customer_id=NULL）后，
    # 它原来在客户分组里的那条关联还留着 —— 表现为「客户的仪表板列表里
    # 出现租户级共享看板」，而租户自己的列表里反而看不到。
    # 43-merge-energy-dashboards.py 提升归属时会发生，这里收拾干净。
    mis = psql(
        "WITH del AS ("
        "DELETE FROM relation r USING entity_group g, dashboard d "
        "WHERE r.from_id=g.id AND r.from_type='ENTITY_GROUP' "
        "AND r.relation_type='Contains' AND r.to_type='DASHBOARD' "
        "AND g.type='DASHBOARD' AND g.owner_type='CUSTOMER' "
        "AND d.id=r.to_id AND d.customer_id IS NULL RETURNING r.to_id) "
        "SELECT count(*) FROM del"
    ).strip()
    print(f"  ✓ 清掉「租户级看板挂在客户分组」的错位关联 {mis} 条")

    # 顺手把租户级看板补回租户 All（上一步会把它们从客户分组里摘掉）
    psql(
        "INSERT INTO relation (from_id, from_type, to_id, to_type, relation_type_group, relation_type, version) "
        "SELECT g.id, 'ENTITY_GROUP', d.id, 'DASHBOARD', 'FROM_ENTITY_GROUP', 'Contains', 1 "
        "FROM entity_group g, dashboard d "
        "WHERE g.type='DASHBOARD' AND g.owner_type='TENANT' AND g.name='All' "
        f"AND g.owner_id={q(tid)} AND d.customer_id IS NULL "
        "ON CONFLICT DO NOTHING"
    )

    # 旧机制/测试残留：名字形如「<客户名> Dashboards」且该客户已不存在。
    #
    # ★ 不能只按后缀删（2026-11-14 修正）。
    #   TB 的 findOrCreateReadOnlyEntityGroupForCustomer 会给**每个活着的客户**
    #   建一个「<客户名> Dashboards」只读组，它是客户实体组权限的一部分。
    #   只按后缀删会把活客户的组也删掉，下次开户又重建 —— 反复抖动。
    #   判据必须加一条：customer 表里找不到这个名字才算残留。
    names = psql(
        "SELECT string_agg(quote_literal(g.name), ',') FROM entity_group g "
        "WHERE g.type='DASHBOARD' AND g.owner_type='TENANT' "
        f"AND g.owner_id={q(tid)} "
        "AND g.name LIKE '%" + LEGACY_SUFFIX.strip() + "' "
        "AND NOT EXISTS (SELECT 1 FROM customer c "
        "                WHERE c.title = left(g.name, length(g.name) - "
        f"                   {len(LEGACY_SUFFIX)}))"
    ).strip()
    if names:
        psql(
            "DELETE FROM relation r USING entity_group g "
            "WHERE r.from_id=g.id AND r.from_type='ENTITY_GROUP' AND r.to_type='DASHBOARD' "
            f"AND g.type='DASHBOARD' AND g.name IN ({names})"
        )
        cnt = psql(
            f"WITH del AS (DELETE FROM entity_group WHERE type='DASHBOARD' AND name IN ({names}) RETURNING 1) "
            "SELECT count(*) FROM del"
        ).strip()
        print(f"  ✓ 删除已销户客户的残留分组 {cnt} 个")
    else:
        print("  · 无已销户客户的残留分组")


def default_group_configuration():
    """与 TB 后端 EntityGroupConfiguration.createDefaultEntityGroupConfiguration(DASHBOARD) 一致。

    ★ 这个字段不能省（2026-11-14 踩坑）。
    直接 INSERT 一个 configuration 为 NULL 的组，后端能存、`GET /api/entityGroup/{id}`
    也能返回，但前端 `GroupConfigTableConfigService#prepareConfiguration` 第 78 行读的是
    `entityGroup.configuration.columns.filter(...)` —— 直接 TypeError，
    Angular resolver 失败 → **整个路由重定向到首页**。

    实测症状：分组列表里能看见这些分组，点进去 URL 跳回 `/`，什么错误也不提示。
    只有 All（有配置）和历史分组能正常打开 —— 正是客户报的「除了 all 都不能点」。

    TB 原生的 `BaseEntityGroupService#saveEntityGroup` 本来会在 id 为空且配置为空时
    自动补上，手写 SQL 把这道保障绕过了。所以脚本必须自己写全。
    """
    return {
        "columns": [
            {"type": "ENTITY_FIELD", "key": "created_time", "sortOrder": "DESC"},
            {"type": "ENTITY_FIELD", "key": "title", "sortOrder": "NONE"},
        ],
        "settings": {},
        "actions": {},
    }


def ensure_group(tid, name):
    """建或取分组，返回 id。

    已存在但 configuration 为空的（旧版本脚本建的）会补上默认配置 ——
    幂等，可反复执行。
    """
    row = psql(
        "SELECT id::text||'|'||CASE WHEN configuration IS NULL THEN 'null' ELSE 'ok' END "
        "FROM entity_group WHERE type='DASHBOARD' "
        f"AND owner_type='TENANT' AND owner_id={q(tid)} AND name={q(name)}"
    ).strip()
    cfg = json.dumps(default_group_configuration(), ensure_ascii=False)
    if row:
        gid, state = row.split("|", 1)
        if state == "null":
            psql(f"UPDATE entity_group SET configuration = {q(cfg)} WHERE id = {q(gid)}")
            print(f"      · 补全「{name}」的列配置（原为空，会导致点不进去）")
        return gid
    gid = str(uuid.uuid4())
    psql(
        "INSERT INTO entity_group (id, created_time, type, name, owner_id, owner_type, configuration, version) "
        f"VALUES ({q(gid)}, {int(time.time() * 1000)}, 'DASHBOARD', {q(name)}, "
        f"{q(tid)}, 'TENANT', {q(cfg)}, 1)"
    )
    return gid


def group(tid, dashboards):
    print("\n---- 按菜单功能建分组 ----")
    by_title = {d["title"]: d["id"] for d in dashboards}

    def add_all(gid, title):
        did = by_title.get(title)
        if not did:
            return False
        psql(
            "INSERT INTO relation (from_id, from_type, to_id, to_type, relation_type_group, relation_type, version) "
            f"VALUES ({q(gid)}, 'ENTITY_GROUP', {q(did)}, 'DASHBOARD', 'FROM_ENTITY_GROUP', 'Contains', 1) "
            "ON CONFLICT DO NOTHING"
        )
        return True

    for gname, members in MENU_GROUPS.items():
        gid = ensure_group(tid, gname)
        hit = sum(1 for m in members if add_all(gid, m))
        print(f"  ✓ {gname:8s} {hit} 块")

    gid = ensure_group(tid, "租户运营台")
    hit = sum(1 for m in TENANT_OPS if add_all(gid, m))
    print(f"  ✓ 租户运营台 {hit} 块（不面向客户菜单）")

    print(f"  · 顶层入口 {len(TOP_LEVEL)} 块留在 All：{' / '.join(TOP_LEVEL)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audit", action="store_true")
    ap.add_argument("--clean", action="store_true")
    ap.add_argument("--group", action="store_true")
    ap.add_argument("--apply", action="store_true", help="= --clean + --group")
    args = ap.parse_args()

    if not any([args.audit, args.clean, args.group, args.apply]):
        ap.print_help()
        return

    tid = tenant_id()
    groups = load_groups()
    dashboards = load_dashboards()

    if args.audit:
        audit(groups, dashboards)
        return

    do_clean = args.clean or args.apply
    do_group = args.group or args.apply

    if do_clean:
        clean(tid)
    if do_group:
        group(tid, dashboards)

    print("\n---- 结果 ----")
    audit(load_groups(), load_dashboards())


if __name__ == "__main__":
    main()
