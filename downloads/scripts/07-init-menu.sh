#!/usr/bin/env bash
#
# 能源管理平台 · 初始化客户的能源管理菜单
#
# 作用：把一个客户的左侧菜单换成「能源管理主题」——
#   能耗查询 / 能耗优化 / 设备运维 / 组织 / 报表与账单
# 菜单里的看板入口会自动指向<b>该客户自己那份看板</b>，不用手工填 id。
#
# 什么时候需要它：
#   · 平台已经给新客户自动装了菜单（后端初始化），此脚本用于「补装 / 重装 / 修正」
#   · 老客户升级上来没有菜单
#   · 手工改乱了想恢复
#
# 用法（在部署目录内）：
#   bash scripts/07-init-menu.sh \
#     --tenant tenant@your.com --tenant-pass 'Tenant@123' \
#     --customer customer@your.com --customer-pass 'Customer@123'
#
#   --base URL        平台地址，默认 http://127.0.0.1:8090
#   --customer-name   客户名称（默认取客户账号所属客户）
#   --dry-run         只打印将要写入的菜单结构，不落库
#
set -euo pipefail

BASE="http://127.0.0.1:8090"
TENANT=""; TENANT_PASS=""
CUST="";   CUST_PASS=""
DRY="false"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)          BASE="$2"; shift 2 ;;
    --tenant)        TENANT="$2"; shift 2 ;;
    --tenant-pass)   TENANT_PASS="$2"; shift 2 ;;
    --customer)      CUST="$2"; shift 2 ;;
    --customer-pass) CUST_PASS="$2"; shift 2 ;;
    --dry-run)       DRY="true"; shift ;;
    -h|--help)       sed -n '2,26p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -n "$TENANT" && -n "$TENANT_PASS" ]] || die "必须提供 --tenant 与 --tenant-pass"
[[ -n "$CUST" && -n "$CUST_PASS" ]]     || die "必须提供 --customer 与 --customer-pass"

BASE="$BASE" DRY="$DRY" TENANT="$TENANT" TENANT_PASS="$TENANT_PASS" \
CUST="$CUST" CUST_PASS="$CUST_PASS" python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request

BASE   = os.environ["BASE"].rstrip("/")
DRY    = os.environ["DRY"] == "true"
TENANT = os.environ["TENANT"];      TENANT_PASS = os.environ["TENANT_PASS"]
CUST   = os.environ["CUST"];        CUST_PASS   = os.environ["CUST_PASS"]

MENU_NAME = "能源管理菜单"

def call(path, token=None, method="GET", body=None):
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if token:
        req.add_header("X-Authorization", "Bearer " + token)
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "ignore")[:300]
    except Exception as e:
        return 0, str(e)

def login(user, pwd):
    st, res = call("/api/auth/login", method="POST", body={"username": user, "password": pwd})
    if st != 200 or not isinstance(res, dict) or "token" not in res:
        sys.exit(f"  登录失败 {user}: HTTP {st} {res}")
    return res["token"]

def step(msg):
    print(f"\033[36m{msg}\033[0m")

# ---- 1. 身份 ----
step("1. 登录")
ttok = login(TENANT, TENANT_PASS)
ctok = login(CUST, CUST_PASS)

st, me = call("/api/auth/user", ctok)
if st != 200:
    sys.exit(f"  读客户身份失败：HTTP {st} {me}")
cid = me["customerId"]["id"]
print(f"  ✓ 客户 {me.get('email')} → customerId {cid}")

# ---- 2. 客户看板 ----
step("2. 读客户看板")
st, page = call(f"/api/customer/{cid}/dashboards?pageSize=100&page=0", ctok)
dash = {}
if st == 200 and isinstance(page, dict):
    for d in page.get("data", []):
        if d.get("title"):
            dash[d["title"]] = d["id"]["id"]
print(f"  ✓ 看板 {len(dash)} 个")
if not dash:
    print("  ! 客户名下没有看板 —— 菜单只会有站内页面。先跑 02-onboard.sh 或把看板复制给客户")

# ---- 3. 构造菜单 ----
def link(name, icon, url=None, dash_id=None):
    it = {"type": "CUSTOM", "name": name, "icon": icon,
          "menuItemType": "LINK", "visible": True}
    if dash_id:
        it["linkType"] = "DASHBOARD"
        it["dashboardId"] = dash_id
        it["hideDashboardToolbar"] = False
    else:
        it["linkType"] = "URL"
        it["url"] = url
    return it

def dash_link(title, icon):
    did = dash.get(title)
    return link(title, icon, dash_id=did) if did else None

def group(name, icon, pages):
    kept = [p for p in pages if p]
    return {"type": "CUSTOM", "name": name, "icon": icon,
            "menuItemType": "SECTION", "visible": True, "pages": kept}

def default_item(mid, pages=None):
    it = {"type": "DEFAULT", "id": mid, "visible": True}
    if pages is not None:
        it["pages"] = pages
    return it

items = [
    default_item("home"),
    # 兜底：全部看板仍可按名字找，客户熟悉后直接从这里进
    default_item("dashboards", [default_item("dashboard_all")]),
    group("能耗查询", "search", [
        dash_link("实时能耗", "timeline"),
        dash_link("历史能耗", "history"),
        dash_link("分项能耗", "donut_large"),
        dash_link("区域能耗", "map"),
        dash_link("峰谷分析", "stacked_line_chart"),
        dash_link("电能质量", "bolt"),
        link("参数报表", "table_chart", url="/param-report"),
    ]),
    group("能耗优化", "trending_down", [
        dash_link("能耗洞察", "insights"),
        dash_link("闲时能耗", "nightlight"),
        dash_link("节能记录", "energy_savings_leaf"),
        link("闲时能耗配置", "tune", url="/idle-config"),
    ]),
    group("设备运维", "devices", [
        link("组织与场站", "location_city", url="/sites"),
        link("设备分组", "account_tree", url="/device-group"),
        link("设备管理", "devices_other", url="/device-management"),
        link("设备拓扑", "hub", url="/device-topology"),
        link("告警中心", "notification_important", url="/alarm-center"),
        link("抄表管理", "assignment", url="/meter-reading"),
        dash_link("手工填报", "edit_note"),
    ]),
    group("组织", "corporate_fare", [
        link("组织与场站", "location_city", url="/sites"),
        dash_link("客户能源档案", "folder_shared"),
        dash_link("基础配置中心", "settings"),
    ]),
    group("报表与账单", "description", [
        dash_link("综合能耗", "summarize"),
        dash_link("盘查报告", "fact_check"),
        dash_link("我的账单", "receipt_long"),
        dash_link("我的账单模板", "article"),
        dash_link("基础报表", "table_view"),
    ]),
]

if DRY:
    step("3. 将要写入的菜单（--dry-run，不落库）")
    print(json.dumps({"items": items}, ensure_ascii=False, indent=2))
    sys.exit(0)

# ---- 4. 清旧菜单 ----
#
# ★ 这里必须用【客户账号】操作，不能用租户管理员。
#
#   /api/customMenu 的 create 会把 customerId 强制设成"当前登录用户的 customerId"：
#   租户管理员的 customerId 是 NULL_UUID，建出来的是一条「租户级客户菜单」，
#   customer_id 不是这个客户 —— 而客户菜单的查找条件是
#   findDefaultCustomMenuByScope(tenantId, customerId, CUSTOMER)，
#   即 customer_id 必须等于该客户。结果：菜单建成功了、库里也有，
#   但客户永远看不到，还会因为"已有 ALL 菜单"挡住后续重建。
#   实测 2026-10-21，踩过一次。
step("3. 清理旧菜单（以客户身份）")
st, mpage = call("/api/customMenu/infos?pageSize=100&page=0&scope=CUSTOMER", ctok)
removed = 0
if st == 200 and isinstance(mpage, dict):
    for m in mpage.get("data", []):
        owner = (m.get("customerId") or {}).get("id")
        # 只处理归属本客户的；租户/系统级菜单不碰
        if owner != cid:
            continue
        mid = m["id"]["id"]
        code, _ = call(f"/api/customMenu/{mid}?force=true", ctok, "DELETE")
        if code in (200, 204):
            removed += 1
print(f"  ✓ 删除 {removed} 条")

# ---- 5. 新建 ----
step("4. 创建并写入配置")
st, created = call("/api/customMenu", ctok, "POST", {
    "name": MENU_NAME,
    "scope": "CUSTOMER",
    "assigneeType": "ALL",
})
if st != 200:
    if isinstance(created, dict) and "already default menu" in str(created.get("message", "")):
        sys.exit("  已有默认客户菜单且删不掉（多半是 customer_id 指向 NULL 的孤儿菜单）\n"
                 "  用租户管理员删掉它，或直接执行：\n"
                 "  DELETE FROM custom_menu WHERE scope='CUSTOMER' AND customer_id='13814000-1dd2-11b2-8080-808080808080'")
    sys.exit(f"  创建菜单失败：HTTP {st} {created}")
mid = created["id"]["id"]
print(f"  ✓ 菜单已创建 {mid}")

st, res = call(f"/api/customMenu/{mid}/config", ctok, "PUT", {"items": items})
if st != 200:
    sys.exit(f"  写入配置失败：HTTP {st} {res}")
print("  ✓ 配置已写入")

# ---- 6. 用客户身份回读 ----
step("5. 以客户身份回读")
st, got = call("/api/customMenu", ctok)
if st != 200 or not isinstance(got, dict):
    sys.exit(f"  回读失败：HTTP {st} {got}")
tops = got.get("items", [])
print(f"  ✓ 客户看到的顶层菜单 {len(tops)} 项：")
for it in tops:
    name = it.get("name") or it.get("id")
    n = len(it.get("pages") or [])
    print(f"      · {name}" + (f"（{n} 项）" if n else ""))

if len(tops) < 4:
    sys.exit("  ✗ 菜单项过少 —— 检查每个 item 是否都写了 visible=true")
print("\n\033[32m完成。客户刷新页面即可看到新菜单。\033[0m")
PY
