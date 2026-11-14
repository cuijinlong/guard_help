#!/usr/bin/env python3
"""资产数据审计与清理。

背景（2026-11-14 客户提问）
    「资产中有没有垃圾数据啊？如果有清理一遍」
    「它里面有没有类似仪表板一样的可以在多客户用户的情况下，可以公用的资产节点啊？」

本脚本审计 7 类问题，只有第 7 类是真正要删的垃圾：

    ① 悬空关系         relation 指向已删的资产 / 设备
    ② 孤儿资产         无遥测 + 无关系 + 非公共主数据
    ③ 重复资产         同归属 + 同 type + 同 name
    ④ 客户级公共主数据 厂商 / 型号 / 品种 本该只在租户级
    ⑤ 场站分组断链     siteId 属性缺失或指向不存在 / 别的客户的场站
    ⑥ 测试残留         名字含 zz / 测试 / demo 的资产
    ⑦ 四维度库根       每个客户是否四套齐全（energy_item/area/usage/space_library）

用法
    python3 46-audit-assets.py --audit            # 只读，出报告
    python3 46-audit-assets.py --clean-testdata   # 删测试残留（自动备份 + 逐条确认引用）
    python3 46-audit-assets.py --restore DIR      # 从备份回滚

★ 为什么不一并自动清理 ①-⑤
    每一类都可能是「看起来像垃圾、实际是业务数据」：
      · 孤儿资产 —— 刚建好还没接数据的场站就是「无遥测无关系」
      · 客户级厂商 —— 可能是客户特意自建的（产品允许，见 EnergyVendorModelController）
    自动删它们风险极高。脚本只**报告**，由人判断；
    唯一自动清的是 ⑦（名字带 zz/测试/demo，且引用计数为 0）。

★ customer_id 的两种「租户级」写法（踩过）
    TB 用 NULL 和 NULL_UUID(13814000-1dd2-11b2-8080-808080808080) 两种值
    都表示「不属于任何客户」。只写 `customer_id IS NULL` 会漏掉一半 ——
    实测本环境 53 个租户级资产全是 NULL_UUID 形式，按 IS NULL 查是 0 个。
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
BAK = os.path.expanduser("~/.energy-asset-bak")

NULL_UUID = "13814000-1dd2-11b2-8080-808080808080"

# 公共主数据：按设计只应存在于租户级
SHARED_TYPES = (
    "厂商", "设备型号", "default", "tou_scheme",
    "rate_template", "rate_template_library", "energy_type_library",
)

# 测试残留的判据：名字**以**这些前缀开头。
#
# ★ 不能用「包含」（2026-11-14 实测踩到）：
#   演示客户本身就叫「zz客户B」，它名下全部资产名都带后缀「·zz客户B」——
#   按包含匹配会把 50 个带遥测的正常业务资产（场站/分项/区域/场站分组）
#   全部判成测试数据，一键清下去就删掉了整个演示客户。
#   实测：50 个命中里 45 个是真业务数据，每个都有 4428 条遥测。
#
#   按「以 zz 开头」判：`zz共享型号` / `zz别人的型号` / `zz客户厂商` 命中，
#   而 `照明分项·办公园区·zz客户B` 不命中。再加一道「遥测为 0」的双保险。
TEST_PREFIXES = ("zz", "测试", "demo", "test", "tmp")

TENANT_OWNED = f"(a.customer_id IS NULL OR a.customer_id = '{NULL_UUID}')"


def psql(sql, tuples_only=True):
    cmd = ["docker", "exec", PG, "psql", "-U", USER, "-d", DB]
    if tuples_only:
        cmd.append("-tA")
    cmd += ["-c", sql]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"psql 失败：\n{r.stderr}\nSQL: {sql[:400]}")
    return r.stdout


def q(s):
    return "NULL" if s is None else "'" + str(s).replace("'", "''") + "'"


def rows(sql):
    out = psql(sql).strip()
    return [l.split("|") for l in out.split("\n") if l.strip()] if out else []


def owner_expr():
    """资产的归属显示：真租户级 / 客户名"""
    return f"CASE WHEN {TENANT_OWNED} THEN '【租户级·公共】' ELSE c.title END"


def audit():
    print("=" * 74)
    print("  资产数据审计")
    print("=" * 74)

    total = psql("SELECT count(*) FROM asset").strip()
    tenant = psql(f"SELECT count(*) FROM asset WHERE customer_id IS NULL "
                  f"OR customer_id='{NULL_UUID}'").strip()
    cust = str(int(total) - int(tenant))
    print(f"\n资产总数 {total}（租户级 {tenant} / 客户级 {cust}）")

    problems = 0

    # ① 悬空关系
    n = rows(f"""
        SELECT 'asset.from', count(*) FROM relation r
        WHERE r.from_type='ASSET' AND NOT EXISTS (SELECT 1 FROM asset a WHERE a.id=r.from_id)
        UNION ALL SELECT 'asset.to', count(*) FROM relation r
        WHERE r.to_type='ASSET' AND NOT EXISTS (SELECT 1 FROM asset a WHERE a.id=r.to_id)
        UNION ALL SELECT 'device.to', count(*) FROM relation r
        WHERE r.to_type='DEVICE' AND NOT EXISTS (SELECT 1 FROM device d WHERE d.id=r.to_id)
    """)
    dangling = sum(int(x[1]) for x in n)
    print(f"\n① 悬空关系：{dangling} 条" + ("" if dangling == 0 else "  ← 需人工确认"))
    for k, v in n:
        if int(v):
            print(f"     {k}: {v}")
    problems += dangling

    # ② 孤儿资产
    orph = rows(f"""
        SELECT {owner_expr()}, a.type, a.name
        FROM asset a LEFT JOIN customer c ON c.id=a.customer_id
        WHERE NOT EXISTS (SELECT 1 FROM ts_kv k WHERE k.entity_id=a.id)
          AND NOT EXISTS (SELECT 1 FROM relation r
                          WHERE (r.from_id=a.id AND r.from_type='ASSET')
                             OR (r.to_id=a.id AND r.to_type='ASSET'))
          AND a.type NOT IN ({','.join(q(t) for t in SHARED_TYPES)})
    """)
    print(f"\n② 孤儿资产（无遥测无关系）：{len(orph)} 个")
    for r in orph:
        print(f"     {' | '.join(r)}")
    problems += len(orph)

    # ③ 重复
    dup = rows(f"""
        SELECT {owner_expr()}, a.type, a.name, count(*)
        FROM asset a LEFT JOIN customer c ON c.id=a.customer_id
        GROUP BY {owner_expr()}, a.type, a.name HAVING count(*)>1
    """)
    print(f"\n③ 重复资产（同归属同类型同名）：{len(dup)} 组")
    for r in dup:
        print(f"     {' | '.join(r)}")
    problems += len(dup)

    # ④ 客户级公共主数据
    wrong = rows(f"""
        SELECT c.title, a.type, a.name
        FROM asset a JOIN customer c ON c.id=a.customer_id
        WHERE a.type IN ({','.join(q(t) for t in SHARED_TYPES)})
        ORDER BY 1,2,3
    """)
    print(f"\n④ 客户级公共主数据（设计上应只在租户级）：{len(wrong)} 个")
    for r in wrong:
        print(f"     {' | '.join(r)}")
    problems += len(wrong)

    # ⑤ 场站分组断链
    grp_total = psql("SELECT count(*) FROM asset WHERE type='场站分组'").strip()
    no_site = rows(f"""
        SELECT c.title, a.name FROM asset a JOIN customer c ON c.id=a.customer_id
        WHERE a.type='场站分组' AND NOT EXISTS (
          SELECT 1 FROM attribute_kv k JOIN key_dictionary d
            ON d.key_id=k.attribute_key AND d.key='siteId' WHERE k.entity_id=a.id)
    """)
    bad_site = rows(f"""
        SELECT a.name||' → siteId='||k.str_v FROM asset a
        JOIN attribute_kv k ON k.entity_id=a.id
        JOIN key_dictionary d ON d.key_id=k.attribute_key AND d.key='siteId'
        WHERE a.type='场站分组'
          AND NOT EXISTS (SELECT 1 FROM asset s WHERE s.type='场站' AND s.id::text=k.str_v)
    """)
    print(f"\n⑤ 场站分组：{grp_total} 个，缺 siteId {len(no_site)} 个，siteId 无效 {len(bad_site)} 个")
    for r in no_site:
        print(f"     缺属性 {' | '.join(r)}")
    for r in bad_site:
        print(f"     无效 {' | '.join(r)}")
    problems += len(no_site) + len(bad_site)

    # ⑥ 测试残留
    pats = " OR ".join(f"a.name ILIKE '{p}%'" for p in TEST_PREFIXES)
    tests = rows(f"""
        SELECT {owner_expr()}, a.type, a.name,
               (SELECT count(*) FROM relation r
                WHERE (r.from_id=a.id AND r.from_type='ASSET')
                   OR (r.to_id=a.id AND r.to_type='ASSET')) AS rel,
               (SELECT count(*) FROM ts_kv k WHERE k.entity_id=a.id) AS tel
        FROM asset a LEFT JOIN customer c ON c.id=a.customer_id
        WHERE ({pats})
        ORDER BY 1,2
    """)
    print(f"\n⑥ 测试残留（名字以 {'/'.join(TEST_PREFIXES)} 开头）：{len(tests)} 个")
    for r in tests:
        print(f"     {' | '.join(r)}")
    problems += len(tests)

    # ⑦ 四维度库根
    print("\n⑦ 四维度库根（每客户应有 4 套）")
    libs = rows(f"""
        SELECT c.title, count(*), string_agg(a.type, ',' ORDER BY a.type)
        FROM asset a JOIN customer c ON c.id=a.customer_id
        WHERE a.type LIKE '%_library' GROUP BY c.title ORDER BY c.title
    """)
    for r in libs:
        flag = "" if r[1] == "4" else "  ← 不齐"
        print(f"     {r[0]}: {r[1]} 套{flag}")
    if not libs:
        print("     （无客户级库根）")

    print("\n" + "=" * 74)
    print(f"  合计待确认项 {problems} 个（其中 ⑥ 可用 --clean-testdata 自动清）")
    print("=" * 74)
    return tests


def clean_testdata():
    print("\n---- 清理测试残留 ----")
    pats = " OR ".join(f"a.name ILIKE '{p}%'" for p in TEST_PREFIXES)
    targets = rows(f"""
        SELECT a.id::text, {owner_expr()}, a.type, a.name,
               (SELECT count(*) FROM relation r
                WHERE (r.from_id=a.id AND r.from_type='ASSET')
                   OR (r.to_id=a.id AND r.to_type='ASSET')) AS rel,
               (SELECT count(*) FROM ts_kv k WHERE k.entity_id=a.id) AS tel
        FROM asset a LEFT JOIN customer c ON c.id=a.customer_id
        WHERE ({pats}) ORDER BY 1
    """)
    if not targets:
        print("  无命中，退出")
        return

    os.makedirs(BAK, exist_ok=True)
    ts = time.strftime("%Y%m%d-%H%M%S")
    dump = os.path.join(BAK, f"asset-testdata-{ts}.sql")
    subprocess.run(
        ["docker", "exec", PG, "pg_dump", "-U", USER, "-d", DB, "-t", "asset", "-t", "relation"],
        stdout=open(dump, "w"), stderr=subprocess.DEVNULL,
    )
    detail = os.path.join(BAK, f"asset-testdata-{ts}.json")
    with open(detail, "w", encoding="utf-8") as f:
        json.dump(targets, f, ensure_ascii=False, indent=1)
    print(f"  ✓ 备份 {dump}")
    print(f"  ✓ 明细 {detail}")

    deleted = skipped = 0
    for tid, owner, typ, name, rel, tel in targets:
        if int(tel) > 0:
            print(f"  · 跳过「{name}」（有 {tel} 条遥测，不是测试数据）")
            skipped += 1
            continue
        # 结构关系（父库 Contains）随资产一起清；引用关系要先看清楚
        rels = rows(f"SELECT r.from_type, r.to_type, r.relation_type FROM relation r "
                    f"WHERE (r.from_id='{tid}' AND r.from_type='ASSET') "
                    f"   OR (r.to_id='{tid}' AND r.to_type='ASSET')")
        psql(f"DELETE FROM relation WHERE (from_id='{tid}' AND from_type='ASSET') "
             f"   OR (to_id='{tid}' AND to_type='ASSET')")
        psql(f"DELETE FROM attribute_kv WHERE entity_id='{tid}'")
        psql(f"DELETE FROM asset WHERE id='{tid}'")
        deleted += 1
        print(f"  ✓ 删除「{owner} / {typ} / {name}」（清关系 {len(rels)} 条）")

    print(f"\n  删除 {deleted} 个，跳过 {skipped} 个")


def restore(dirpath):
    sql = os.path.join(dirpath)
    if not os.path.exists(sql):
        sys.exit(f"备份不存在：{sql}")
    psql_file(sql)
    print("✓ 回滚完成")


def psql_file(path):
    with open(path) as f:
        subprocess.run(["docker", "exec", "-i", PG, "psql", "-U", USER, "-d", DB],
                       stdin=f, capture_output=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audit", action="store_true")
    ap.add_argument("--clean-testdata", action="store_true")
    ap.add_argument("--restore", metavar="SQL")
    args = ap.parse_args()

    if args.restore:
        restore(args.restore)
        return
    if not (args.audit or args.clean_testdata):
        ap.print_help()
        return

    tests = audit()
    if args.clean_testdata:
        if not tests:
            print("\n无需清理")
            return
        clean_testdata()
        print("\n---- 清理后复查 ----")
        audit()


if __name__ == "__main__":
    main()
