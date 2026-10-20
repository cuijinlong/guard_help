#!/usr/bin/env python3
"""
能源管理平台 · 客户基础数据导入（Excel / CSV 双格式）

客户用 Excel 填一张表（4 个工作表），本脚本把它变成平台里的：
    场站 → 分组 → 分项 → 设备 → 拓扑关系 → 用能区域/空间位置/用能性质

用法：
    # Excel（需要 openpyxl）
    python3 05-import-customer-data.py 客户数据.xlsx \
        --base http://127.0.0.1:8090 \
        --tenant-admin tenant@example.com --tenant-pass 'Tenant@12345'

    # CSV（零依赖，三个文件放在同一目录）
    python3 05-import-customer-data.py ./csv目录/ \
        --base http://127.0.0.1:8090 --tenant-admin ... --tenant-pass ...

可选参数：
    --customer-admin 邮箱 --customer-admin-pass 密码   同时建客户管理员
    --dry-run       只校验，不写库
    --out FILE      RTU 网关清单输出路径（默认 rtu-config.csv）

═══════════════════════════════════════════════════════════════════
Excel 的四个工作表（列名必须完全一致，顺序不限）
═══════════════════════════════════════════════════════════════════

【1. 场站】一行一个场站
    场站名称* | 场站分组 | 用能区域 | 空间位置 | 用能性质 | 备注
    * 必填，同一客户内唯一

【2. 设备】一行一台设备
    设备名称* | 所属场站* | 设备档案* | 层级* | 厂商 | 型号 | 分项 |
    用能区域 | 空间位置 | 用能性质 | 备注
    * 必填。设备档案见 PROFILE_ENERGY；层级 1=总表 2=分表 3=支路

【3. 点位】一行一个采集点
    设备名称* | 标准键名* | 点位地址* | 倍率 | 单位 | 备注
    * 必填。标准键名必须是平台认可的 46 个键之一

【4. 说明】（可选，给客户看填写指引，脚本忽略）

═══════════════════════════════════════════════════════════════════
设计要点（改代码前先读）
═══════════════════════════════════════════════════════════════════
1. 幂等：所有实体按「名称」查找，存在则复用。重复导入不会产生重复数据。
2. 分项必须双挂：场站 Contains 分项 + 电能品种 Contains 分项。
   只挂一边，分项能耗页面查不到数。
3. 设备 level 写 SERVER_SCOPE；场站归属写 additionalInfo.siteId。
   这是前端既有的读数约定，写错位置页面就读不到。
4. Excel 常见坑已处理：空行跳过、表头前后空格、数字被转科学计数法、
   点位地址前导零丢失（统一按字符串读）。
"""

import argparse
import csv
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# ─────────────────────────── 契约常量 ───────────────────────────

SITE_TYPE = "场站"
GROUP_TYPE = "场站分组"
ITEM_TYPE = "分项"
AREA_TYPE = "用能区域"
SPACE_TYPE = "空间位置"
USAGE_TYPE = "用能性质"
LIB_TYPE = "energy_type_library"
CONTAINS = "Contains"

PROFILE_ENERGY = {
    "电能表": "elec", "单相电能表": "elec",
    "水表": "water", "燃气表": "gas", "蒸汽表": "steam",
}
NON_METER_PROFILES = {"温湿度变送器", "网关"}
VALID_PROFILES = set(PROFILE_ENERGY) | NON_METER_PROFILES

# 维度资产：表头列名 → 平台 Asset.type
DIMENSION_COLUMNS = {
    "用能区域": AREA_TYPE,
    "空间位置": SPACE_TYPE,
    "用能性质": USAGE_TYPE,
}

STANDARD_KEYS = {
    "energy", "energy_reading", "energy_reverse", "reactive_reading", "reactive_reverse",
    "energy_tip", "energy_peak", "energy_flat", "energy_valley",
    "energy_day", "energy_reverse_day", "energy_used_day", "energy_generation_day",
    "voltage_a", "voltage_b", "voltage_c",
    "current_a", "current_b", "current_c",
    "power_a", "power_b", "power_c", "power_total",
    "reactive_power_a", "reactive_power_b", "reactive_power_c", "reactive_power_total",
    "apparent_power_a", "apparent_power_b", "apparent_power_c", "apparent_power_total",
    "power_factor_a", "power_factor_b", "power_factor_c", "power_factor_total",
    "frequency", "demand_max", "demand_reverse_max", "load_rate", "voltage_unbalance",
    "current_thd_a", "current_thd_b", "current_thd_c",
    "voltage_thd_a", "voltage_thd_b", "voltage_thd_c",
    "power", "temperature", "humidity",
}

SINGLE_PHASE_FORBIDDEN = {
    "voltage_b", "voltage_c", "current_b", "current_c",
    "power_b", "power_c", "power_factor_b", "power_factor_c",
}


# ─────────────────────────── 读取 Excel / CSV ───────────────────────────

def norm(v):
    """单元格标准化：去空格、去全角空格、None → ''、数字去掉小数点后的 .0"""
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v).replace("\u3000", " ").strip()


def read_xlsx(path):
    try:
        import openpyxl
    except ImportError:
        sys.exit(
            "✗ 读取 .xlsx 需要 openpyxl，当前环境没有。二选一：\n"
            "    1) pip install openpyxl\n"
            "    2) 在 Excel 里把每个工作表另存为 CSV（UTF-8），"
            "三个文件放进同一目录，然后把这个目录传给脚本"
        )
    wb = openpyxl.load_workbook(path, data_only=True)
    sheets = {}
    for name in wb.sheetnames:
        ws = wb[name]
        rows = []
        for row in ws.iter_rows(values_only=True):
            vals = [norm(c) for c in row]
            if any(vals):
                rows.append(vals)
        if rows:
            sheets[name] = rows
    return sheets


def read_csv_dir(path):
    """目录下按文件名识别：场站.csv / 设备.csv / 点位.csv"""
    mapping = {"场站": "场站", "设备": "设备", "点位": "点位"}
    sheets = {}
    for stem, sheet in mapping.items():
        for candidate in (path / f"{stem}.csv", path / f"{stem}.CSV"):
            if candidate.is_file():
                # utf-8-sig 兼容 Excel 另存 CSV 时加的 BOM
                with candidate.open(encoding="utf-8-sig", newline="") as f:
                    rows = [[norm(c) for c in r] for r in csv.reader(f)]
                sheets[sheet] = [r for r in rows if any(r)]
                break
    missing = [s for s in mapping if s not in sheets]
    if missing:
        sys.exit(f"✗ 目录 {path} 缺少 CSV：{missing}（需要 场站.csv / 设备.csv / 点位.csv）")
    return sheets


def to_records(rows, sheet_name):
    """首行当表头，其余为数据行。返回 dict 列表。"""
    if not rows:
        return []
    header = rows[0]
    out = []
    for i, r in enumerate(rows[1:], start=2):
        if len(r) < len(header):
            r = r + [""] * (len(header) - len(r))
        rec = {header[j]: r[j] for j in range(len(header))}
        rec["__row__"] = i
        out.append(rec)
    return out


# ─────────────────────────── 校验 ───────────────────────────

def validate(sites, devices, points):
    """返回 (errors, warnings)。errors 非空则不写库。"""
    errors, warnings = [], []

    site_names = set()
    for s in sites:
        n = s.get("场站名称", "")
        if not n:
            errors.append(f"【场站】第 {s['__row__']} 行：场站名称不能为空")
            continue
        if n in site_names:
            errors.append(f"【场站】第 {s['__row__']} 行：场站名称重复「{n}」")
        site_names.add(n)
    if not site_names:
        errors.append("【场站】表没有任何场站")

    dev_names = set()
    for d in devices:
        row = d["__row__"]
        n = d.get("设备名称", "")
        if not n:
            errors.append(f"【设备】第 {row} 行：设备名称不能为空")
            continue
        if n in dev_names:
            errors.append(f"【设备】第 {row} 行：设备名称重复「{n}」（租户内必须唯一）")
        dev_names.add(n)

        site = d.get("所属场站", "")
        if not site:
            errors.append(f"【设备】第 {row} 行（{n}）：所属场站不能为空")
        elif site not in site_names:
            errors.append(f"【设备】第 {row} 行（{n}）：所属场站「{site}」不在【场站】表里")

        profile = d.get("设备档案", "")
        if profile not in VALID_PROFILES:
            errors.append(
                f"【设备】第 {row} 行（{n}）：设备档案「{profile}」无效，"
                f"可选 {sorted(VALID_PROFILES)}"
            )

        lvl = d.get("层级", "")
        if lvl not in ("1", "2", "3"):
            errors.append(f"【设备】第 {row} 行（{n}）：层级必须是 1 / 2 / 3，当前「{lvl}」")

        # 型号归属厂商（只在两者都填时校验）
        vendor, model = d.get("厂商", ""), d.get("型号", "")
        if model and not vendor:
            warnings.append(f"【设备】第 {row} 行（{n}）：填了型号但没填厂商，型号不会关联")

    dev_profile = {d["设备名称"]: d.get("设备档案", "") for d in devices if d.get("设备名称")}

    pts_by_dev = {}
    for p in points:
        row = p["__row__"]
        dev = p.get("设备名称", "")
        key = p.get("标准键名", "")
        addr = p.get("点位地址", "")

        if dev not in dev_profile:
            errors.append(f"【点位】第 {row} 行：设备名称「{dev}」不在【设备】表里")
            continue
        if key not in STANDARD_KEYS:
            errors.append(
                f"【点位】第 {row} 行（{dev}）：标准键名「{key}」不识别。"
                f"见手册「能源参数字典」"
            )
            continue
        if not addr:
            errors.append(f"【点位】第 {row} 行（{dev}/{key}）：点位地址不能为空")

        if dev_profile.get(dev) == "单相电能表" and key in SINGLE_PHASE_FORBIDDEN:
            warnings.append(
                f"【点位】第 {row} 行（{dev}）：单相表不该有 {key}，已跳过"
            )
            continue

        pts_by_dev.setdefault(dev, set()).add(key)

    for d in devices:
        n = d.get("设备名称", "")
        if n and n not in pts_by_dev:
            errors.append(f"【设备】{n}：没有任何点位，RTU 无法采集")

    # 关键提示：只报了表底没报用电量时，平台会自动做差，但要提醒
    for dev, keys in pts_by_dev.items():
        if "energy_reading" in keys and "energy" in keys:
            warnings.append(f"{dev}：同时上报了 energy_reading 和 energy，注意不要重复计量")

    return errors, warnings


# ─────────────────────────── HTTP ───────────────────────────

class Api:
    def __init__(self, base, token=None):
        self.base = base.rstrip("/")
        self.token = token
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def call(self, method, path, body=None, raw=False, allow_404=False):
        headers = {"Accept": "application/json"}
        if self.token:
            headers["X-Authorization"] = "Bearer " + self.token
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=120) as r:
                text = r.read().decode() or ""
                return text if raw else (json.loads(text) if text else None)
        except urllib.error.HTTPError as e:
            detail = e.read().decode()[:400]
            if allow_404 and e.code == 404:
                return None
            raise SystemExit(f"✗ {method} {path} → HTTP {e.code}\n  {detail}") from None
        except urllib.error.URLError as e:
            raise SystemExit(f"✗ 无法连接 {self.base}\n  {e.reason}") from None


def q(s):
    return urllib.parse.quote(str(s))


# ─────────────────────────── 导入主流程 ───────────────────────────

def main():
    ap = argparse.ArgumentParser(description="导入客户基础数据")
    ap.add_argument("source", help="客户数据.xlsx 或包含 3 个 CSV 的目录")
    ap.add_argument("--base", default="http://127.0.0.1:8090")
    ap.add_argument("--tenant-admin", required=True)
    ap.add_argument("--tenant-pass", required=True)
    ap.add_argument("--customer-admin")
    ap.add_argument("--customer-admin-pass")
    ap.add_argument("--customer", help="客户名（Excel 里没填「客户名称」列时用）")
    ap.add_argument("--out", default="rtu-config.csv")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    src = Path(args.source)
    if src.is_dir():
        sheets = read_csv_dir(src)
        label = f"CSV 目录 {src.name}"
    elif src.is_file() and src.suffix.lower() == ".xlsx":
        sheets = read_xlsx(src)
        label = src.name
    else:
        sys.exit(f"✗ 找不到 {src}，或格式不是 .xlsx / 目录")

    for need in ("场站", "设备", "点位"):
        if need not in sheets:
            sys.exit(f"✗ 缺少工作表「{need}」。Excel 里应有：场站 / 设备 / 点位")

    sites = to_records(sheets["场站"], "场站")
    devices = to_records(sheets["设备"], "设备")
    points = to_records(sheets["点位"], "点位")

    print(f"读取 {label}")
    print(f"  场站 {len(sites)} 个 / 设备 {len(devices)} 台 / 点位 {len(points)} 条")

    errors, warnings = validate(sites, devices, points)
    for w in warnings:
        print(f"  ! {w}")
    if errors:
        print(f"\n✗ 发现 {len(errors)} 处问题，未写入数据库：")
        for e in errors:
            print("   ·", e)
        sys.exit(1)

    # 客户名优先级：Excel 的「客户名称」列 → --customer 参数
    customer = ""
    for s in sites:
        v = s.get("客户名称", "").strip()
        if v:
            customer = v
            break
    customer = customer or (args.customer or "").strip()
    if not customer:
        sys.exit("✗ 缺少客户名。在【场站】表加一列「客户名称」并填上，或用 --customer 参数指定")
    print(f"  客户：{customer}")

    if args.dry_run:
        print("\n✓ 校验通过（--dry-run，未写入）")
        return

    api = Api(args.base)
    tok = api.call("POST", "/api/auth/login",
                   {"username": args.tenant_admin, "password": args.tenant_pass})
    api.token = tok["token"]

    def list_all(tpl, size=500):
        out, page = [], 0
        while True:
            p = api.call("GET", tpl.format(size=size, page=page))
            out.extend(p.get("data", []))
            if not p.get("hasNext"):
                return out
            page += 1

    # ---- 客户 ----
    cust_id = None
    for c in api.call("GET", "/api/tenant/customers?pageSize=100&page=0").get("data", []):
        if c.get("title") == customer:
            cust_id = c["id"]["id"]
            break
    if not cust_id:
        cust_id = api.call("POST", "/api/customer", {"title": customer})["id"]["id"]
        print(f"\n✓ 客户「{customer}」已创建")
    else:
        print(f"\n客户「{customer}」已存在")
    cust_ref = {"entityType": "CUSTOMER", "id": cust_id}

    # ---- 能源品种 ----
    libs = api.call("GET", f"/api/tenant/assets?pageSize=100&page=0&type={q(LIB_TYPE)}").get("data", [])
    if not libs:
        sys.exit("✗ 租户下没有能源参数字典，请先确认租户初始化完成")
    kinds = {}
    for r in api.call("GET", f"/api/relations?fromId={libs[0]['id']['id']}&fromType=ASSET"
                             f"&type={q(CONTAINS)}&typeGroup=COMMON") or []:
        a = api.call("GET", f"/api/asset/{r['to']['id']}")
        kinds[a["name"]] = r["to"]["id"]
    elec_kind = kinds.get("电能")

    # ---- 索引 ----
    asset_by_name = {a["name"]: a for a in
                     list_all("/api/tenant/assets?pageSize={size}&page={page}")}
    device_by_name = {d["name"]: d for d in
                      list_all("/api/tenant/devices?pageSize={size}&page={page}")}
    profile_by_name = {p["name"]: p for p in
                       list_all("/api/deviceProfiles?pageSize={size}&page={page}")}

    def ensure_asset(name, atype, info=None):
        if name in asset_by_name:
            return asset_by_name[name]["id"]["id"], False
        a = api.call("POST", "/api/asset", {
            "name": name, "type": atype, "label": name,
            "customerId": cust_ref, "additionalInfo": info or {},
        })
        asset_by_name[name] = a
        return a["id"]["id"], True

    def relate(src_id, dst_id, dst_type="ASSET"):
        api.call("POST", "/api/relation", {
            "from": {"entityType": "ASSET", "id": src_id},
            "to": {"entityType": dst_type, "id": dst_id},
            "type": CONTAINS, "typeGroup": "COMMON",
        })

    # ---- 场站 / 分组 / 维度 ----
    print("\n创建场站、分组与维度...")
    site_ids, dim_ids = {}, {}
    for s in sites:
        sname = s["场站名称"]
        group = s.get("场站分组", "")
        sid, created = ensure_asset(sname, SITE_TYPE)
        site_ids[sname] = sid
        if group:
            gid, gc = ensure_asset(group, GROUP_TYPE)
            relate(gid, sid)
            if gc:
                print(f"  ✓ 分组「{group}」")
        if created:
            print(f"  ✓ 场站「{sname}」" + (f"（分组 {group}）" if group else ""))

        # 三个维度：场站挂维度根
        for col, atype in DIMENSION_COLUMNS.items():
            val = s.get(col, "")
            if not val:
                continue
            did, dc = ensure_asset(val, atype)
            dim_ids[(atype, val)] = did
            relate(did, sid)
            if dc:
                print(f"  ✓ {col}「{val}」")

    # ---- 分项 ----
    print("\n创建分项...")
    item_ids = {}
    for d in devices:
        iname = d.get("分项", "")
        if not iname or iname in item_ids:
            continue
        iid, ic = ensure_asset(iname, ITEM_TYPE)
        item_ids[iname] = iid
        sid = site_ids.get(d.get("所属场站", ""))
        if sid:
            relate(sid, iid)          # ← 双挂 ①：场站 → 分项
        if elec_kind:
            relate(elec_kind, iid)    # ← 双挂 ②：电能品种 → 分项
        if ic:
            print(f"  ✓ 分项「{iname}」（已挂场站 + 电能品种）")

    # ---- 设备 ----
    print("\n创建设备...")
    rows = []
    for d in devices:
        dname = d["设备名称"]
        sname = d["所属场站"]
        profile = d["设备档案"]
        level = int(d["层级"])
        prow = profile_by_name.get(profile)
        if not prow:
            sys.exit(f"✗ 设备档案「{profile}」不存在，请确认租户初始化已完成")

        if dname in device_by_name:
            dev = device_by_name[dname]
            print(f"  · {dname}（已存在，复用）")
        else:
            dev = api.call("POST", "/api/device", {
                "name": dname, "type": profile, "label": dname,
                "customerId": cust_ref,
                "deviceProfileId": {"entityType": "DEVICE_PROFILE", "id": prow["id"]["id"]},
            })
            device_by_name[dname] = dev
            print(f"  ✓ {dname:<24} {profile:<10} level={level}")
        did = dev["id"]["id"]
        sid = site_ids[sname]

        # 设备归属：additionalInfo.siteId（前端按此字段归场站）
        ai = dict(dev.get("additionalInfo") or {})
        ai["siteId"] = sid
        if d.get("分项"):
            ai["itemName"] = d["分项"]
        for col in DIMENSION_COLUMNS:
            if d.get(col):
                ai[{"用能区域": "areaName", "空间位置": "spaceName",
                    "用能性质": "usageName"}[col]] = d[col]
        api.call("POST", "/api/device", {**dev, "additionalInfo": ai})

        # 结构化属性：level / item 必须 SERVER_SCOPE
        attrs = {"level": level}
        if d.get("分项"):
            attrs["item"] = item_ids[d["分项"]]
        api.call("POST", f"/api/plugins/telemetry/DEVICE/{did}/SERVER_SCOPE", attrs)

        relate(sid, did, "DEVICE")     # 场站 → 设备，形成拓扑

        # 设备自己的维度归属
        for col, atype in DIMENSION_COLUMNS.items():
            val = d.get(col, "")
            if not val:
                continue
            dim_id = dim_ids.get((atype, val))
            if dim_id:
                api.call("POST", "/api/relation", {
                    "from": {"entityType": "ASSET", "id": dim_id},
                    "to": {"entityType": "DEVICE", "id": did},
                    "type": CONTAINS, "typeGroup": "COMMON",
                })

        cred = api.call("GET", f"/api/device/{did}/credentials")
        token = cred.get("credentialsId", "")
        rows.append({"_device": dname, "_token": token, "_site": sname,
                     "_profile": profile, "_level": level})

    # ---- 点位与 RTU 清单 ----
    dev_meta = {r["_device"]: r for r in rows}
    out_rows = []
    for p in points:
        dname = p["设备名称"]
        key = p["标准键名"]
        if dev_meta[dname]["_profile"] == "单相电能表" and key in SINGLE_PHASE_FORBIDDEN:
            continue
        out_rows.append({
            "场站": dev_meta[dname]["_site"],
            "设备": dname,
            "设备档案": dev_meta[dname]["_profile"],
            "层级": dev_meta[dname]["_level"],
            "标准键名": key,
            "点位地址": p["点位地址"],
            "倍率": p.get("倍率", "") or "1",
            "单位": p.get("单位", ""),
            "accessToken": dev_meta[dname]["_token"],
        })

    out = Path(args.out)
    fields = ["场站", "设备", "设备档案", "层级", "标准键名", "点位地址", "倍率", "单位", "accessToken"]
    with out.open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(out_rows)

    print("\n设备接入信息（复制给现场配网关）：")
    width = max((len(k) for k in dev_meta), default=10)
    for name, meta in dev_meta.items():
        print(f"  {name:<{width}}  {meta['_token']}")

    print(f"\n✓ 已写入 {out}（{len(out_rows)} 条点位，{len(dev_meta)} 台设备）")
    print(f"✓ 共创建/复用：场站 {len(site_ids)} 个、分项 {len(item_ids)} 个、维度 {len(dim_ids)} 个")

    # ---- 客户管理员 ----
    if args.customer_admin and args.customer_admin_pass:
        print(f"\n创建客户管理员 {args.customer_admin}")
        try:
            u = api.call("POST", "/api/user?sendActivationMail=false", {
                "email": args.customer_admin, "authority": "CUSTOMER_USER",
                "firstName": "客户", "lastName": "管理员", "customerId": cust_ref,
            })
            uid = u["id"]["id"]
        except SystemExit as e:
            if "already" not in str(e).lower() and "present" not in str(e).lower():
                raise
            users = list_all("/api/user/users?pageSize={size}&page={page}")
            uid = next(u["id"]["id"] for u in users if u["email"] == args.customer_admin)
        link = api.call("GET", f"/api/user/{uid}/activationLink", raw=True, allow_404=True)
        if link and "activateToken=" in link:
            t = link.split("activateToken=")[-1].split("&")[0].strip()
            Api(args.base).call("POST", "/api/noauth/activate?sendActivationMail=false",
                                {"activateToken": t, "password": args.customer_admin_pass})
            print("  ✓ 客户管理员已激活")
        else:
            print("  · 账号已激活，沿用原密码")

    print("\n完成。现场按 rtu-config.csv 配好网关后，各页面自动有数据。")


if __name__ == "__main__":
    main()
