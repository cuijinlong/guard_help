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
#
# 结构与生产实例的「业务导航（能源管理）」逐项对齐，只保留客户真正要用的。
# 判断过的垃圾（不要加回来）：
#   · 「验证·能源流向」     —— 与「能源流向」部件完全相同的测试副本，模板已删
#   · 「我的账单模板」      —— 「我的账单」的残缺子集（1/4 部件），模板已删
#   · 「客户能源档案」      —— 租户侧档案视图，客户看不到别人的档案
#   · 「基础配置中心」      —— 时段方案/费率/倍率，都是租户定的，客户不改
#   · 「闲时能耗配置」菜单项 —— 入口在「闲时能耗」看板右上角的配置按钮
#   · 「仪表板」列表        —— TB 的建模入口，客户只需要按用途分好的菜单

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

def dash_link(title, icon, menu_name=None):
    did = dash.get(title)
    if not did:
        print(f"  ! 看板「{title}」不存在，菜单项跳过")
        return None
    return link(menu_name or title, icon, dash_id=did)

def ai_link(name, icon, path):
    """ngx-ai 子应用：新标签页 + 带 token（前端已把 /ngxai 排除在 Angular 路由外）"""
    it = link(name, icon, url=path)
    it["openInNewTab"] = True
    it["setAccessToken"] = True
    return it

def group(name, icon, pages):
    kept = [p for p in pages if p]
    return {"type": "CUSTOM", "name": name, "icon": icon,
            "menuItemType": "SECTION", "visible": True, "pages": kept}

items = [
    # 第一项 = 落地页。客户登录直接看到能耗，不经过空门户页
    dash_link("能耗概览", "dashboard"),

    group("能耗查询", "search", [
        dash_link("实时能耗", "timeline"),
        dash_link("历史能耗", "history"),
        dash_link("抄表功能", "assignment"),
    ]),

    group("能耗分析", "analytics", [
        dash_link("峰谷分析", "stacked_line_chart"),
        dash_link("分项能耗", "donut_large"),
        dash_link("区域能耗", "map"),
        dash_link("我的账单", "receipt_long", "用能账单"),
    ]),

    group("综合报表", "description", [
        dash_link("基础报表", "table_view"),
        dash_link("手工填报", "edit_note"),
        link("参数报表", "table_chart", url="/param-report"),
    ]),

    group("能耗优化", "trending_down", [
        dash_link("闲时能耗", "nightlight"),
        ai_link("负载预测", "online_prediction", "/ngxai/biz/forecast"),
        ai_link("用能建议", "lightbulb", "/ngxai/biz/advice"),
        ai_link("用能质量", "verified", "/ngxai/biz/quality"),
    ]),

    # 告警只有「看发生了什么」这一件事，不再套一层分组（规则在场站详情页配）
    link("告警中心", "notification_important", url="/alarm-center"),

    group("设备运维", "devices", [
        link("设备管理", "devices_other", url="/device-management"),
        link("设备分组", "account_tree", url="/device-group"),
        link("设备拓扑", "hub", url="/device-topology"),
        # 报表空白 / 设备没数据时，这是第一个该点的地方
        link("平台自检", "checklist", url="/self-check"),
    ]),

    # 四张常用看板做成一级入口：每天要点，藏进分组反而多一次点击
    dash_link("综合能耗", "summarize"),
    dash_link("能源流向", "swap_horiz"),
    dash_link("电能质量", "bolt"),
    dash_link("盘查报告", "fact_check"),
    dash_link("节能记录", "energy_savings_leaf"),

    # 组织就是场站列表，不套分组
    link("组织", "corporate_fare", url="/sites"),
]
items = [x for x in items if x]

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
        # 按【名字】匹配，不按 customerId —— 菜单的 customer_id 恒为 NULL_UUID，
        # 拿它和客户 id 比永远不相等，一条都删不掉。
        if m.get("name") != MENU_NAME:
            continue
        mid = m["id"]["id"]
        code, _ = call(f"/api/customMenu/{mid}?force=true", ctok, "DELETE")
        if code in (200, 204):
            removed += 1
print(f"  ✓ 删除 {removed} 条")

# ---- 5. 新建 ----
step("4. 创建并写入配置")
# ★ customer_id 必须显式传 NULL_UUID，理由有两条：
#   1. custom_menu.customer_id 是 NOT NULL —— 留空直接
#      DataIntegrityViolationException，菜单建不出来；
#   2. 本平台绑定客户靠 customer.customMenuId 指向菜单 id（下一步写），
#      而不是靠菜单的 customer_id 指向客户。生产实例里所有菜单的
#      customer_id 都是 NULL_UUID。
NULL_UUID = "13814000-1dd2-11b2-8080-808080808080"
st, created = call("/api/customMenu", ctok, "POST", {
    "customerId": {"id": NULL_UUID, "entityType": "CUSTOMER"},
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

# ---- 6. 设首页看板 ----
#
# 客户登录后落在 /home，前端读 customer.additionalInfo.homeDashboardId
# 决定展示哪个看板。不设的话那里是一个空的仪表板门户页。
step("5. 绑定菜单并设首页看板")
#
# ★ 这一步才是「客户能看见菜单」的关键。
#
#   客户登录时 findCustomerHierarchyCustomMenu 的查找顺序：
#     1. 按 customer_id 找默认客户菜单 → 我们建的是 NULL_UUID，命不中
#     2. 读 customer.customMenuId 按 id 找 → 这一步对上才行
#     3. 都没有 → 退回「Customer default menu」（TB 原生菜单）
#
#   只建菜单不写 customMenuId，客户看到的永远是默认菜单。
home_id = dash.get("能耗概览")
st, cur = call(f"/api/customer/{cid}", ttok)
if st == 200 and isinstance(cur, dict):
    cur["customMenuId"] = {"id": mid, "entityType": "CUSTOM_MENU"}
    ai = cur.get("additionalInfo") or {}
    if home_id:
        ai["homeDashboardId"] = home_id
        ai["homeDashboardHideToolbar"] = False
    cur["additionalInfo"] = ai
    st2, _ = call("/api/customer", ttok, "POST", cur)
    if st2 == 200:
        print(f"  ✓ 客户已绑定菜单 {mid[:8]}…")
        print("  ✓ 首页看板已设为「能耗概览」" if home_id else "  ! 没有「能耗概览」看板，首页保持默认")
    else:
        print(f"  ! 绑定失败 HTTP {st2}（客户会看到默认菜单）")
else:
    print(f"  ! 读客户信息失败 HTTP {st}")

# ---- 7. 用客户身份回读 ----
step("6. 以客户身份回读")
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
