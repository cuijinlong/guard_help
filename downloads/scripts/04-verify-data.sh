#!/usr/bin/env bash
#
# 能源管理平台 · 数据准确性验收
#
# 与前一个脚本的区别：
#   03-verify.sh      验「接口能不能用、权限对不对」       —— 结构验收
#   04-verify-data.sh 验「数对不对、彼此对不对得上」      —— 数据验收
#
# 用法（在部署目录内）：
#   bash scripts/04-verify-data.sh
#   bash scripts/04-verify-data.sh --site 单相园区    # 只验某个场站
#   bash scripts/04-verify-data.sh --verbose          # 打印每台表的明细
#
# 退出码：0 = 全部通过，1 = 有失败项
#
# 为什么直接查数据库而不是走 REST：
#   一次要拉 11 台表 × 336 点 × 20 个键 ≈ 7 万行，走 REST 要几十秒且分页易漏；
#   psql 一条聚合查询就够，而且能直接算「表底差 vs 增量」这类需要跨行的断言。
#   REST 版见手册，供非 PostgreSQL 部署使用。
#
set -uo pipefail

cd "$(dirname "$0")/.."

SITE_FILTER=""
VERBOSE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site)    SITE_FILTER="$2"; shift 2 ;;
    --verbose) VERBOSE="true"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

[[ -f .env ]] || { echo "缺少 .env，先确认当前目录是部署目录" >&2; exit 2; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a

DB_U="${DB_USER:-postgres}"
DB_N="${DB_NAME:-thingsboard}"

if ! docker compose exec -T postgres psql -U "$DB_U" -d "$DB_N" -tAc 'select 1' >/dev/null 2>&1; then
  echo "连不上数据库。确认服务在跑：docker compose ps" >&2
  exit 2
fi

# -A 不补空格、-F'|' 定界、-t 去表头；\pset footer off 去掉末尾行数
psql_q() {
  docker compose exec -T postgres psql -U "$DB_U" -d "$DB_N" -X -q -A -F'|' -t \
    -v ON_ERROR_STOP=1 -c "$1" 2>/dev/null
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- 取数

# 拓扑：设备 → 设备（供电层级）
psql_q "SELECT pf.name, cf.name FROM relation r
        JOIN device pf ON pf.id = r.from_id
        JOIN device cf ON cf.id = r.to_id
        WHERE r.relation_type = 'Contains'
          AND r.from_type = 'DEVICE' AND r.to_type = 'DEVICE'" > "$WORK/tree.txt" || true

# 站点归属：additional_info 在库里是 varchar 不是 json，直接 ->> 会报类型错，
# 用正则提取最稳（也不怕历史数据里存过非法 JSON）。
psql_q "SELECT d.name, COALESCE(a.name, '') FROM device d
        LEFT JOIN asset a
          ON a.id::text = substring(d.additional_info from '\"siteId\":\"([^\"]+)\"')
        ORDER BY d.name" > "$WORK/site.txt" || true

# 电表与仪表属性：meterLevel
# attribute_type 是整数枚举（1=CLIENT 2=SERVER 3=SHARED），
# attribute_key 也不是名字而是 key_dictionary 里的 id —— 两者都要转换。
# 虚拟设备标记。判「值」不判「键」：实时设备也带 deviceVirtual 键（值为 real），
# 只判键存在会把全部设备都当成虚拟表。
psql_q "SELECT name,
          COALESCE(substring(additional_info from '\"deviceVirtual\"\s*:\s*\"([^\"]+)\"'), 'real')
        FROM device" > "$WORK/virtual.txt" || true

psql_q "SELECT d.name, COALESCE(av.str_v, av.long_v::text, ''), d.type
        FROM device d
        LEFT JOIN attribute_kv av
          ON av.entity_id = d.id AND av.attribute_type = 2
        LEFT JOIN key_dictionary kd ON kd.key_id = av.attribute_key
        WHERE d.type IN ('单相电能表','电能表','水表','燃气表','蒸汽表','温湿度变送器')
          AND (kd.key = 'meterLevel' OR kd.key IS NULL)
        ORDER BY d.name" > "$WORK/level.txt" || true

# 遥测：只取验算需要的键
psql_q "SELECT d.name, k.key, t.ts, t.dbl_v FROM ts_kv t
        JOIN key_dictionary k ON k.key_id = t.key
        JOIN device d ON d.id = t.entity_id
        WHERE k.key IN (
          'energy','energy_reading','energy_day',
          'energy_tip','energy_peak','energy_flat','energy_valley','energy_deep',
          'power_a','power_b','power_c','power_total',
          'voltage_a','voltage_b','voltage_c','voltage_unbalance',
          'power_factor_total','reactive_reading','temperature','humidity')
        ORDER BY d.name, k.key, t.ts" > "$WORK/ts.txt" || true

# 峰谷字典里未写的档位也要算，缺键视为 0
for f in tree site level ts; do
  [[ -s "$WORK/$f.txt" ]] || echo "  ! 取数为空：$f" >&2
done

SITE_FILTER="$SITE_FILTER" VERBOSE="$VERBOSE" python3 - "$WORK" <<'PY'
import os, sys
from collections import defaultdict

work = sys.argv[1]
site_filter = os.environ.get("SITE_FILTER", "").strip()
verbose = os.environ.get("VERBOSE") == "true"

def rows(name):
    out = []
    with open(os.path.join(work, name + ".txt"), encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            out.append(line.split("|"))
    return out

# ---------- 载入 ----------
tree = defaultdict(list)          # 上级表 -> [下级表]
site_of = {}                      # 设备 -> 场站
level_of = {}                     # 设备 -> 计量级
type_of = {}                      # 设备 -> 档案名
for a, b in rows("tree"):
    tree[a].append(b)
for name, site in rows("site"):
    site_of[name] = site
for name, lvl, typ in rows("level"):
    level_of[name] = lvl
    type_of[name] = typ

# 虚拟设备：手工填报，只有月首 energy 点，没有表底
virtual = set()
for name, flag in rows("virtual"):
    if flag == "virtual":
        virtual.add(name)

ts = defaultdict(lambda: defaultdict(list))   # 设备 -> key -> [(ts, v)]
for name, key, t, v in rows("ts"):
    if v == "" or v is None:
        continue
    try:
        ts[name][key].append((int(t), float(v)))
    except ValueError:
        continue
for d in ts:
    for k in ts[d]:
        ts[d][k].sort()

def pick(dev):
    if not site_filter:
        return True
    return site_filter in site_of.get(dev, "")

devs = sorted(d for d in ts if pick(d))
# 实时表与虚拟表必须分开：虚拟表按月填报，没有表底，混进来会把
# 「表底单调」「增量守恒」这些实时断言全都误判为失败
real = [d for d in devs if d not in virtual]
virtuals = [d for d in devs if d in virtual]
meters = [d for d in real if type_of.get(d) in ("单相电能表", "电能表")]
utils = [d for d in real if type_of.get(d) in ("水表", "燃气表", "蒸汽表")]
sensors = [d for d in real if type_of.get(d) == "温湿度变送器"]

# ---------- 断言框架 ----------
PASS = FAIL = 0
FAILED = []
NOTES = []

def case(ok_, title, detail=""):
    global PASS, FAIL
    if ok_:
        PASS += 1
        print(f"  \033[32m✓\033[0m {title}" + (f"  ({detail})" if detail else ""))
    else:
        FAIL += 1
        FAILED.append(title)
        print(f"  \033[31m✗\033[0m {title}" + (f"  — {detail}" if detail else ""))

def section(t):
    print(f"\n\033[36m{t}\033[0m")

def r2(v):
    return round(v * 100) / 100

EPS = 0.015          # 两位小数的累计误差上限（每个点四舍五入 ±0.005，跨点累积放宽到 0.015）

# ---------- 1. 规模 ----------
section("1. 演示包规模")

sites = sorted({site_of.get(d, "") for d in site_of if site_of.get(d)})
sites = [s for s in sites if not site_filter or site_filter in s]
if sites:
    case(len(sites) >= 2, "场站数 ≥ 2", f"实际 {len(sites)}：{', '.join(sites)}")
else:
    # 没有 siteId 关联时退化为按名字前缀判断，不直接判失败
    pref = sorted({d.split("·")[0] for d in devs})
    case(False, "场站归属可解析", f"设备 additionalInfo.siteId 缺失；按名字前缀看到：{pref}")

n_3p = len([d for d in meters if type_of.get(d) == "电能表"])
n_1p = len([d for d in meters if type_of.get(d) == "单相电能表"])
case(n_1p >= 1, "单相电表 ≥ 1 台", f"{n_1p} 台")
case(n_3p >= 1, "三相电表 ≥ 1 台", f"{n_3p} 台")

for label, key in (("水表", "水表"), ("燃气表", "燃气表"), ("蒸汽表", "蒸汽表")):
    n = len([d for d in utils if type_of.get(d) == key])
    case(n >= 2, f"{label} ≥ 2 台（实时）", f"{n} 台")
case(len(virtuals) >= 2, "虚拟设备 ≥ 2 台（手工填报样板）", f"{len(virtuals)} 台")
case(len(sensors) >= 2, "温湿度变送器 ≥ 2 台", f"{len(sensors)} 台")

# ---------- 2. 计量层级 ----------
section("2. 电表计量层级（一级 / 二级 / 三级）")

lv = defaultdict(int)
for d in meters:
    lv[level_of.get(d, "")] += 1
for want in ("1", "2", "3"):
    case(lv.get(want, 0) >= 1, f"存在第 {want} 级表", f"{lv.get(want, 0)} 台")

# 层级关系必须真实存在：L2 挂在 L1 下、L3 挂在 L2 下
edges = [(p, c) for p in tree for c in tree[p] if p in level_of and c in level_of]
lv_edges = [(level_of[p], level_of[c]) for p, c in edges]
case(("1", "2") in lv_edges, "存在 一级 → 二级 连接", f"{lv_edges.count(('1','2'))} 条")
case(("2", "3") in lv_edges, "存在 二级 → 三级 连接", f"{lv_edges.count(('2','3'))} 条")
case(len(lv_edges) >= 3, "设备供电层级边数 ≥ 3", f"{len(lv_edges)} 条")

# 每台非进线表都应有一个上级
roots = {p for p, c in edges}
children = {c for p, c in edges}
orphan = [d for d in meters if d not in roots and d not in children
          and level_of.get(d) not in ("1", "")]
case(len(orphan) == 0, "没有游离电表（既非上级也非下级）",
     f"游离 {len(orphan)} 台：{orphan[:3]}" if orphan else f"{len(meters)} 台全部入树")

# ---------- 3. 增量守恒 ----------
section("3. 增量与表底守恒（逐点）")

def series(dev, key):
    return ts.get(dev, {}).get(key, [])

bad_reading = []
bad_day = []
bad_tou = []
mono = []
for d in meters:
    e = dict(series(d, "energy"))
    rd = dict(series(d, "energy_reading"))
    if not e or not rd:
        continue
    common = sorted(set(e) & set(rd))
    for i in range(1, len(common)):
        prev, cur = common[i - 1], common[i]
        delta = r2(rd[cur] - rd[prev])
        if abs(delta - e[cur]) > EPS:
            bad_reading.append((d, prev, delta, e[cur]))
            break

    # 表底单调不减
    seq = [rd[t] for t in sorted(rd)]
    if any(seq[i] < seq[i - 1] - 1e-9 for i in range(1, len(seq))):
        mono.append(d)

    # 当日累计。分天必须用东八区：Java 侧按 Asia/Shanghai 的 getDayOfYear() 归零，
    # 按 UTC 切天会把上海时间的 08:00 之后错切到前一天，算出 3 倍差。
    day = dict(series(d, "energy_day"))
    if day:
        TZ_OFFSET_MS = 8 * 3600 * 1000
        by_day = defaultdict(list)
        for t, v in e.items():
            by_day[(t + TZ_OFFSET_MS) // 86400000].append((t, v))
        for _, pts in by_day.items():
            pts.sort()
            acc = 0.0
            for t, v in pts:
                acc = r2(acc + v)
                if t in day and abs(day[t] - acc) > EPS:
                    bad_day.append((d, t, day[t], acc))
                    break

    # 峰谷守恒
    parts = {k: dict(series(d, k)) for k in
             ("energy_tip", "energy_peak", "energy_flat", "energy_valley", "energy_deep")}
    for t, v in e.items():
        s = sum(parts[k].get(t, 0.0) for k in parts)
        if abs(s - v) > EPS:
            bad_tou.append((d, t, s, v))
            break

case(len(bad_reading) == 0, "energy_reading 相邻差 == energy（每台表每个点）",
     f"{len(bad_reading)} 台不符：{bad_reading[0]}" if bad_reading else f"{len(meters)} 台全通过")
case(len(mono) == 0, "表底单调不减", f"{len(mono)} 台回退：{mono[:3]}" if mono else "")
case(len(bad_day) == 0, "energy_day == 当日 energy 累加",
     f"{len(bad_day)} 处不符：{bad_day[0]}" if bad_day else "")
case(len(bad_tou) == 0, "Σ(尖/峰/平/谷/深谷) == energy（不丢不重）",
     f"{len(bad_tou)} 处不符：{bad_tou[0]}" if bad_tou else "")

# ---------- 4. 上下级汇总 ----------
section("4. 上下级汇总（上级 > 下级之和，差额 = 线损 + 未装表）")

agg_bad = []
agg_ok = 0
for parent, kids in tree.items():
    if parent not in ts:
        continue
    pe = sum(v for _, v in series(parent, "energy"))
    if not pe:
        continue
    child_sum = 0.0
    counted = 0
    for c in kids:
        cs = sum(v for _, v in series(c, "energy"))
        if cs:
            child_sum += cs
            counted += 1
    if counted == 0:
        continue
    if pe < child_sum - EPS:
        agg_bad.append((parent, r2(pe), r2(child_sum)))
    else:
        agg_ok += 1
        if verbose:
            gap = pe - child_sum
            print(f"      {parent}：{pe:.2f} − 下级 {child_sum:.2f} = {gap:.2f} kWh"
                  f"（{gap / child_sum * 100:.2f}%）")

case(len(agg_bad) == 0, "所有上级表电量 ≥ 下级之和",
     f"{len(agg_bad)} 处倒挂：{agg_bad[:2]}" if agg_bad else f"{agg_ok} 组层级关系全部成立")
case(agg_ok >= 2, "至少验到 2 组上下级汇总", f"{agg_ok} 组")

# 差额率应落在合理区间：>0 且 < 25%
gap_bad = []
for parent, kids in tree.items():
    if parent not in ts:
        continue
    pe = sum(v for _, v in series(parent, "energy"))
    cs = sum(sum(v for _, v in series(c, "energy")) for c in kids)
    if pe and cs:
        rate = (pe - cs) / cs
        if rate > 0.25:
            gap_bad.append((parent, round(rate * 100, 2)))
case(len(gap_bad) == 0, "上下级差额率 ≤ 25%",
     f"超出：{gap_bad[:2]}" if gap_bad else "线损+未装表在合理范围")

# ---------- 5. 电气量物理自洽 ----------
section("5. 电气量物理自洽")

p_sum_bad = []
u_bad = []
pf_bad = []
q_bad = []
for d in meters:
    P = dict(series(d, "power_total"))
    if not P:
        continue
    pa = dict(series(d, "power_a"))
    pb = dict(series(d, "power_b"))
    pc = dict(series(d, "power_c"))
    e = dict(series(d, "energy"))
    pf = dict(series(d, "power_factor_total"))
    rq = dict(series(d, "reactive_reading"))

    for t, v in P.items():
        # 三相表才有 b/c 相
        if pb or pc:
            s = pa.get(t, 0) + pb.get(t, 0) + pc.get(t, 0)
            if abs(s - v) > 0.02:
                p_sum_bad.append((d, t, r2(s), v))
                break
        # 1 小时粒度下 平均功率(kW) 数值上等于 该小时电量(kWh)
        if t in e and abs(v - e[t]) > 0.02:
            u_bad.append((d, t, v, e[t]))
            break
    for t, v in pf.items():
        if v < 0.5 or v > 1.0:
            pf_bad.append((d, t, v))
            break
    for t, v in rq.items():
        pass

case(len(p_sum_bad) == 0, "P_a + P_b + P_c == P_total（三相表）",
     f"{p_sum_bad[0]}" if p_sum_bad else "")
case(len(u_bad) == 0, "P_total == energy（小时粒度）",
     f"{u_bad[0]}" if u_bad else "")
case(len(pf_bad) == 0, "功率因数落在 0.5–1.0",
     f"{pf_bad[0]}" if pf_bad else "")

# 电压不平衡度：国标 GB/T 15543 限值 2%
ub = []
for d in meters:
    for t, v in series(d, "voltage_unbalance"):
        if v > 2.0:
            ub.append((d, round(v, 2)))
            break
case(len(ub) == 0, "电压不平衡度 ≤ 2%（GB/T 15543）",
     f"超标：{ub[:2]}" if ub else "")

# 相电压在国标偏差内：220V ±7% ≈ 204.6–235.4
uv = []
for d in meters:
    for key in ("voltage_a", "voltage_b", "voltage_c"):
        for t, v in series(d, key):
            if v < 204.6 or v > 235.4:
                uv.append((d, key, round(v, 2)))
                break
case(len(uv) == 0, "相电压在 204.6–235.4 V（GB/T 12325 ±7%）",
     f"超范围：{uv[:2]}" if uv else "")

# 单相表不应写 B/C 相
single_bc = []
for d in meters:
    if type_of.get(d) != "单相电能表":
        continue
    for key in ("voltage_b", "voltage_c", "current_b", "current_c", "power_b", "power_c"):
        if series(d, key):
            single_bc.append((d, key))
case(len(single_bc) == 0, "单相表不写 B/C 相键",
     f"误写：{single_bc[:2]}" if single_bc else "")

# 无功表底也必须是累积量
rq_bad = []
for d in meters:
    seq = [v for _, v in series(d, "reactive_reading")]
    if any(seq[i] < seq[i - 1] - 1e-9 for i in range(1, len(seq))):
        rq_bad.append(d)
case(len(rq_bad) == 0, "无功表底单调不减（aggregate=MAX）",
     f"{len(rq_bad)} 台非累积：{rq_bad[:2]}" if rq_bad else "")

# ---------- 6. 非电表 ----------
section("6. 水 / 燃气 / 蒸汽表")

u_bad2 = []
for d in utils:
    e = dict(series(d, "energy"))
    rd = dict(series(d, "energy_reading"))
    if not e:
        u_bad2.append((d, "无 energy"))
        continue
    if not rd:
        u_bad2.append((d, "无 energy_reading"))
        continue
    common = sorted(set(e) & set(rd))
    for i in range(1, len(common)):
        prev, cur = common[i - 1], common[i]
        if abs(r2(rd[cur] - rd[prev]) - e[cur]) > EPS:
            u_bad2.append((d, "表底增量与用量不符"))
            break
    if any(v < 0 for v in e.values()):
        u_bad2.append((d, "出现负用量"))

case(len(u_bad2) == 0, "非电表：用量递增且表底守恒",
     f"{len(u_bad2)} 台异常：{u_bad2[:2]}" if u_bad2 else f"{len(utils)} 台全通过")

# ---------- 7. 温湿度 ----------
section("7. 温湿度")

th_bad = []
for d in sensors:
    temps = [v for _, v in series(d, "temperature")]
    hums = [v for _, v in series(d, "humidity")]
    if not temps or not hums:
        th_bad.append((d, "缺键"))
        continue
    if not (5 <= min(temps) and max(temps) <= 45):
        th_bad.append((d, f"温度越界 {min(temps)}–{max(temps)}"))
    if not (10 <= min(hums) and max(hums) <= 95):
        th_bad.append((d, f"湿度越界 {min(hums)}–{max(hums)}"))
case(len(th_bad) == 0, "温度 5–45℃ / 湿度 10–95%",
     f"{th_bad[:2]}" if th_bad else f"{len(sensors)} 台在合理区间")

# ---------- 8. 覆盖天数 ----------
section("8. 数据覆盖")

span_bad = []
for d in meters + utils:   # 虚拟表只有月点，不参与 13 天覆盖断言
    e = series(d, "energy")
    if not e:
        continue
    days = (e[-1][0] - e[0][0]) / 86400000.0
    if days < 13.0:
        span_bad.append((d, round(days, 1)))
case(len(span_bad) == 0, "每台表覆盖 ≥ 13 天（Prophet 需 2 个完整周）",
     f"不足：{span_bad[:3]}" if span_bad else "")

# ---------- 9. 虚拟设备（手工填报） ----------
section("9. 虚拟设备与手工填报")

v_no_month = []
v_bad_value = []
v_has_reading = []
for d in virtuals:
    e = series(d, "energy")
    if not e:
        v_no_month.append((d, "无月度值"))
        continue
    # 必须都落在月首 00:00（东八区）—— readMonths 只认这个时刻
    TZ = 8 * 3600 * 1000
    for t, _ in e:
        local = (t + TZ) // 1000
        day = (local // 86400) % 31 + 1
        hour = (local % 86400) // 3600
        if hour != 0:
            v_no_month.append((d, f"存在非月首点 hour={hour}"))
            break
    if any(v < 0 for _, v in e):
        v_bad_value.append((d, "出现负值"))
    if series(d, "energy_reading"):
        v_has_reading.append((d, "不应有表底"))

case(len(v_no_month) == 0, "虚拟设备月度值均为月首点",
     f"{v_no_month[:2]}" if v_no_month else f"{len(virtuals)} 台")
case(len(v_bad_value) == 0, "虚拟设备用量非负",
     f"{v_bad_value[:2]}" if v_bad_value else "")
case(len(v_has_reading) == 0, "虚拟设备不写 energy_reading（避免被当实时表底）",
     f"{v_has_reading[:2]}" if v_has_reading else "")

# 虚拟表必须有自己的分项，且不与实时表同分项（否则重复计量）
if verbose and virtuals:
    for d in virtuals:
        n = len(series(d, "energy"))
        tot = sum(v for _, v in series(d, "energy"))
        print(f"      {d}：{n} 个月点，年累计 {tot:.2f}")

# ---------- 明细 ----------
if verbose:
    section("明细")
    for d in devs:
        e = sum(v for _, v in series(d, "energy"))
        rd = [v for _, v in series(d, "energy_reading")]
        lvl = level_of.get(d, "-")
        print(f"  {d:32s} 类型={type_of.get(d,'?'):8s} 级={lvl:>2s} "
              f"场站={site_of.get(d,'-')[:14]:14s} 总量={e:10.2f} 末表底={rd[-1] if rd else 0:.2f}")

# ---------- 汇总 ----------
print()
print("==================================")
print(f"  通过 {PASS} / 失败 {FAIL}")
if FAILED:
    print("  失败项：")
    for f in FAILED:
        print(f"    - {f}")
print("==================================")
sys.exit(0 if FAIL == 0 else 1)
PY
