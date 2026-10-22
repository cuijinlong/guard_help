#!/usr/bin/env bash
#
# 能源管理平台 · 开通租户与客户
#
# 用法：
#   ./02-onboard.sh --base http://127.0.0.1:8090 \
#                   --admin admin@example.com --admin-pass 'ChangeMe123!' \
#                   --tenant "某某集团" \
#                   --customer "某某厂区"
#
# 不传 --customer 就只建租户；不传 --tenant 就用唯一租户。
#
# 关键行为（都是服务端自动触发的，不是本脚本做的）：
#   建租户 → EnergyLibraryInstaller 建「能源参数字典」（4 品种 + 指标参数）
#   建客户 → EnergyBootstrapInstaller 建 4 个维度根 + 一套可清理的演示数据
# 脚本负责调用 API 并**验证这些自动初始化真的发生了** —— 少一样就报错，
# 不给「创建成功但页面空着」的假成功。
#
set -euo pipefail

BASE="http://127.0.0.1:8090"
ADMIN=""
ADMIN_PASS=""
TENANT_TITLE=""
CUSTOMER_TITLE=""
CUSTOMER_EMAIL=""
CUSTOMER_PASS=""
TENANT_EMAIL=""
TENANT_PASS=""
VERIFY_ONLY="false"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)           BASE="$2"; shift 2 ;;
    --admin)          ADMIN="$2"; shift 2 ;;
    --admin-pass)     ADMIN_PASS="$2"; shift 2 ;;
    --tenant)         TENANT_TITLE="$2"; shift 2 ;;
    --customer)       CUSTOMER_TITLE="$2"; shift 2 ;;
    --customer-email) CUSTOMER_EMAIL="$2"; shift 2 ;;
    --customer-pass)  CUSTOMER_PASS="$2"; shift 2 ;;
    --tenant-email)   TENANT_EMAIL="$2"; shift 2 ;;
    --tenant-pass)    TENANT_PASS="$2"; shift 2 ;;
    --verify-only)    VERIFY_ONLY="true"; shift ;;
    -h|--help)        sed -n '2,20p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

# 不要写成 CURL="curl ... --noproxy *"：变量展开时 * 会被 glob 成当前目录的文件名，
# 实际命令变成 `curl --noproxy 01-install.sh 02-onboard.sh ...`。用函数才安全。
ncurl() { curl -s --noproxy '*' "$@"; }

login() {
  ncurl -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$1\",\"password\":\"$2\"}" \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'
}

api() {  # method path [body]
  local m="$1" p="$2" b="${3:-}"
  if [[ -n "$b" ]]; then
    ncurl -X "$m" "$BASE$p" -H "X-Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$b"
  else
    ncurl -X "$m" "$BASE$p" -H "X-Authorization: Bearer $TOKEN"
  fi
}

user_id_by_email() {
  local path
  if [[ "$IS_SYS" == "1" ]]; then
    path="/api/tenant/$TENANT_ID/users?pageSize=100&page=0"
  else
    path="/api/user/users?pageSize=100&page=0"
  fi
  api GET "$path" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(next((u['id']['id'] for u in d.get('data',[]) if u.get('email')=='$1'),''))
" 2>/dev/null
}

# 用一次性激活链接设置密码。
# POST /api/user 建出来的用户永远是 enabled=false 且 **password 字段被忽略**
# （UserServiceImpl.doSaveUser 只存了激活 token），不走这一步账号永远登不上。
activate_user() {
  local uid="$1" pass="$2" link tok
  [[ -n "$uid" ]] || return 1
  link=$(api GET "/api/user/$uid/activationLink")
  tok=$(printf '%s' "$link" | sed -n 's/.*activateToken=\([^&"[:space:]]*\).*/\1/p')
  [[ -n "$tok" ]] || return 1
  ncurl -X POST "$BASE/api/noauth/activate?sendActivationMail=false" \
    -H 'Content-Type: application/json' \
    -d "{\"activateToken\":\"$tok\",\"password\":\"$pass\"}"
}

# ---------------- 认证 ----------------
[[ -n "$ADMIN" && -n "$ADMIN_PASS" ]] || die "需要 --admin 与 --admin-pass"
TOKEN=$(login "$ADMIN" "$ADMIN_PASS")
[[ -n "$TOKEN" ]] || die "管理员登录失败，检查邮箱/密码"

ME=$(api GET /api/auth/user)
IS_SYS=$(echo "$ME" | grep -c '"authority":"SYS_ADMIN"' || true)
if [[ "$IS_SYS" == "1" ]]; then
  ok "以系统管理员身份操作"
  TENANT_ID=""
else
  TENANT_ID=$(echo "$ME" | sed -n 's/.*"tenantId":{"entityType":"TENANT","id":"\([^"]*\)".*/\1/p')
  [[ -n "$TENANT_ID" ]] || die "无法从登录信息解析 tenantId"
  ok "以租户管理员身份操作（tenant=${TENANT_ID}）"
fi

# ---------------- 建租户 ----------------
if [[ "$IS_SYS" == "1" && "$VERIFY_ONLY" != "true" && -n "$TENANT_TITLE" ]]; then
  log "创建租户「${TENANT_TITLE}」"
  EXIST=$(api GET "/api/tenants?pageSize=100&page=0&textSearch=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$TENANT_TITLE")")
  if echo "$EXIST" | grep -q "\"title\":\"$TENANT_TITLE\""; then
    warn "租户已存在，跳过创建"
    TENANT_ID=$(echo "$EXIST" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(next((t['id']['id'] for t in d.get('data',[]) if t.get('title')=='$TENANT_TITLE'),''))
")
  else
    CREATED=$(api POST /api/tenant "{\"title\":\"$TENANT_TITLE\",\"region\":\"Global\"}")
    echo "$CREATED" | grep -q '"id"' || { echo "$CREATED"; die "创建租户失败"; }
    TENANT_ID=$(echo "$CREATED" | sed -n 's/.*"id":{"entityType":"TENANT","id":"\([^"]*\)".*/\1/p' | head -1)
    ok "租户已创建（id=${TENANT_ID}）"
  fi
fi

# ---------------- 建租户管理员，并切换身份 ----------------
# 为什么要多这一步：CustomerController 的 @PreAuthorize 只允许
# TENANT_ADMIN / CUSTOMER_USER，SYS_ADMIN 直接建客户会 403。
# 真实 SaaS 的入驻分权也正是这样：系统管理员只开通租户并交出管理员，
# 租户内的客户、账号由租户管理员自己维护。
if [[ "$IS_SYS" == "1" && "$VERIFY_ONLY" != "true" && -n "$TENANT_ID" ]]; then
  [[ -n "$TENANT_EMAIL" && -n "$TENANT_PASS" ]] \
    || die "以系统管理员开通租户时，需要 --tenant-email 与 --tenant-pass（租户管理员账号）
      也可以改用租户管理员直接登录：--admin <租户管理员邮箱> --admin-pass <密码>
      系统管理员不属于任何租户，直接建客户会被 403 拒绝（TB 的设计，不是本脚本的限制）。"
  log "创建租户管理员 $TENANT_EMAIL"
  BODY=$(printf '{"email":"%s","authority":"TENANT_ADMIN","firstName":"租户","lastName":"管理员","tenantId":{"entityType":"TENANT","id":"%s"}}' \
          "$TENANT_EMAIL" "$TENANT_ID")
  R=$(api POST '/api/user?sendActivationMail=false' "$BODY")
  T_ADMIN_ID=""
  if echo "$R" | grep -q '"id"'; then
    T_ADMIN_ID=$(echo "$R" | sed -n 's/.*"id":{"entityType":"USER","id":"\([^"]*\)".*/\1/p' | head -1)
    ok "租户管理员已创建（待激活）"
  elif echo "$R" | grep -qiE 'already exists|already present'; then
    warn "租户管理员已存在，复用该账号"
    T_ADMIN_ID=$(user_id_by_email "$TENANT_EMAIL")
  else
    echo "$R"; die "创建租户管理员失败"
  fi
  ACT=$(activate_user "$T_ADMIN_ID" "$TENANT_PASS" || true)
  if echo "$ACT" | grep -q '"token"'; then
    TOKEN=$(echo "$ACT" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    ok "租户管理员已激活并取得会话"
  else
    TOKEN=$(login "$TENANT_EMAIL" "$TENANT_PASS")
    [[ -n "$TOKEN" ]] || die "租户管理员既无法激活也无法登录（账号可能已激活且密码不同）"
    ok "租户管理员已存在且可登录"
  fi
  ok "已切换为租户管理员身份，后续客户操作由它完成"
fi

# ---------------- 已有租户内加客户：系统管理员也要先切身份 ----------------
#
# ★ 这是实测踩到的真实缺陷（2026-10-22）：
#   「给现有租户再加一个客户」是最常见的运维动作，此时不会传 --tenant。
#   上面的租户块整段被跳过 → TENANT_ID 为空 → 身份切换也不执行 →
#   仍然拿 SYS_ADMIN 的 token 去 POST /api/customer → **403**，
#   而报错只说「创建客户失败」，看不出是身份问题。
#
#   修法：系统管理员 + 要建客户 + 没有 TENANT_ID 时，
#   用 --tenant-email/--tenant-pass 直接登录成租户管理员（不建号，只换会话）。
if [[ "$IS_SYS" == "1" && "$VERIFY_ONLY" != "true" && -n "$CUSTOMER_TITLE" && -z "$TENANT_ID" ]]; then
  if [[ -n "$TENANT_EMAIL" && -n "$TENANT_PASS" ]]; then
    log "系统管理员不直接建客户，切换为租户管理员 $TENANT_EMAIL"
    TOKEN=$(login "$TENANT_EMAIL" "$TENANT_PASS")
    [[ -n "$TOKEN" ]] || die "租户管理员登录失败：${TENANT_EMAIL}（检查 --tenant-pass）"
    TENANT_ID=$(api GET /api/auth/user \
      | sed -n 's/.*"tenantId":{"entityType":"TENANT","id":"\([^"]*\)".*/\1/p')
    [[ -n "$TENANT_ID" ]] || die "无法从登录信息解析 tenantId"
    ok "已切换为租户管理员（tenant=${TENANT_ID}）"
  else
    die "系统管理员不能直接建客户（TB 会返回 403）。
      往已有租户里加客户时，请补两个参数：
        --tenant-email <该租户的管理员邮箱>  --tenant-pass <密码>
      或者直接用租户管理员登录：--admin <租户管理员邮箱> --admin-pass <密码>"
  fi
fi

# ---------------- 建客户 ----------------
CUSTOMER_ID=""
if [[ "$VERIFY_ONLY" != "true" && -n "$CUSTOMER_TITLE" ]]; then
  log "创建客户「${CUSTOMER_TITLE}」"
  BASE_PATH="/api/customers?pageSize=100&page=0&textSearch=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$CUSTOMER_TITLE")"
  EXIST=$(api GET "$BASE_PATH")
  if echo "$EXIST" | grep -q "\"title\":\"$CUSTOMER_TITLE\""; then
    warn "客户已存在，跳过创建"
    CUSTOMER_ID=$(echo "$EXIST" | sed -n "s/.*\"id\":{\"entityType\":\"CUSTOMER\",\"id\":\"\([^\"]*\)\"}.*\"title\":\"$CUSTOMER_TITLE\".*/\1/p" | head -1)
  else
    CREATED=$(api POST /api/customer "{\"title\":\"$CUSTOMER_TITLE\"}")
    echo "$CREATED" | grep -q '"id"' || { echo "$CREATED"; die "创建客户失败"; }
    CUSTOMER_ID=$(echo "$CREATED" | sed -n 's/.*"id":{"entityType":"CUSTOMER","id":"\([^"]*\)".*/\1/p')
    ok "客户已创建（id=${CUSTOMER_ID}）"
    sleep 3   # 等异步初始化（演示数据）落库
  fi
fi

# ---------------- 建客户管理员 ----------------
if [[ "$VERIFY_ONLY" != "true" && -n "$CUSTOMER_EMAIL" && -n "$CUSTOMER_PASS" ]]; then
  log "创建客户管理员 $CUSTOMER_EMAIL"
  [[ -n "$CUSTOMER_ID" ]] || die "创建客户管理员需要先确定客户（--customer）"
  BODY=$(printf '{"email":"%s","authority":"CUSTOMER_USER","firstName":"客户","lastName":"管理员","customerId":{"entityType":"CUSTOMER","id":"%s"}}' \
          "$CUSTOMER_EMAIL" "$CUSTOMER_ID")
  R=$(api POST '/api/user?sendActivationMail=false' "$BODY")
  C_ADMIN_ID=""
  if echo "$R" | grep -q '"id"'; then
    C_ADMIN_ID=$(echo "$R" | sed -n 's/.*"id":{"entityType":"USER","id":"\([^"]*\)".*/\1/p' | head -1)
  elif echo "$R" | grep -qiE 'already exists|already present'; then
    warn "客户管理员已存在，复用该账号"
    C_ADMIN_ID=$(user_id_by_email "$CUSTOMER_EMAIL")
  else
    echo "$R"; die "创建客户管理员失败"
  fi
  ACT=$(activate_user "$C_ADMIN_ID" "$CUSTOMER_PASS" || true)
  if echo "$ACT" | grep -q '"token"'; then
    ok "客户管理员已创建并激活（可用该邮箱登录）"
  elif [[ -n "$(login "$CUSTOMER_EMAIL" "$CUSTOMER_PASS")" ]]; then
    ok "客户管理员已存在且可登录"
  else
    warn "客户管理员已存在，但密码不是本次传入的值 —— 请用原密码登录"
  fi
fi

# ---------------- 验证自动初始化 ----------------
log "验证自动初始化的业务资源"

FAIL=0

# 1. 能源参数字典（租户级，建租户时自动创建）
LIB_COUNT=$(api GET '/api/tenant/assets?pageSize=500&page=0' \
  | grep -o '"type":"energy_type_library"' | wc -l | tr -d ' ')
if [[ "$LIB_COUNT" -ge 1 ]]; then ok "能源参数字典：$LIB_COUNT 个"
else warn "能源参数字典缺失 —— 查询设置里的品种下拉会是空的"; FAIL=1; fi

# 2. 四个维度根（客户级）
if [[ -n "$CUSTOMER_ID" ]]; then
  ROOTS=$(api GET "/api/customer/$CUSTOMER_ID/assets?pageSize=500&page=0" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
rows=d.get('data',d) if isinstance(d,dict) else d
want={'energy_item_library','energy_area_library','energy_usage_library','energy_space_library'}
got={a.get('type') for a in rows if a.get('type') in want}
print(len(got), ','.join(sorted(got)))
" 2>/dev/null || echo "0 ,")
  ROOT_N=$(echo "$ROOTS" | cut -d' ' -f1)
  if [[ "$ROOT_N" -ge 4 ]]; then ok "四个维度根齐全"
  else warn "维度根不完整（$ROOT_N/4）：$(echo "$ROOTS" | cut -d' ' -f2-)"; FAIL=1; fi
fi

# 3. 系统部件与 bundle（全局，install 时装载）
WIDGET_N=$(api GET '/api/widgetTypes?pageSize=1&page=0' | sed -n 's/.*"totalElements":\([0-9]*\).*/\1/p')
[[ -n "$WIDGET_N" && "$WIDGET_N" -ge 700 ]] && ok "系统部件：$WIDGET_N 个" || { warn "部件数异常：${WIDGET_N:-未知}"; FAIL=1; }

# 4. 我方部件是否在库（按 fqn 前缀数：textSearch 只匹配 name，不匹配 fqn）
ENERGY_N=$(api GET '/api/widgetTypes?pageSize=1000&page=0' | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(sum(1 for w in d.get('data',[]) if str(w.get('fqn','')).startswith('energy_management.')))
" 2>/dev/null || echo 0)
[[ -n "$ENERGY_N" && "$ENERGY_N" -ge 30 ]] && ok "能耗管理部件：$ENERGY_N 个" || { warn "能耗管理部件缺失：${ENERGY_N:-0}"; FAIL=1; }

# 5. 客户演示数据 / 拓扑 / 看板 / 菜单（客户级，建客户时自动创建）
#
# 手册承诺「一次到位」，所以这四项必须实测 —— 否则会出现
# 「脚本说成功、用户登录后页面是空的」这种最坏的假成功。
if [[ -n "$CUSTOMER_ID" ]]; then
  CUST_ASSETS=$(api GET "/api/customer/$CUSTOMER_ID/assets?pageSize=500&page=0")
  CUST_DEVICES=$(api GET "/api/customer/$CUSTOMER_ID/devices?pageSize=500&page=0")

  SITE_N=$(echo "$CUST_ASSETS" | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',[])
print(sum(1 for a in rows if a.get('type')=='场站'))" 2>/dev/null || echo 0)
  ITEM_N=$(echo "$CUST_ASSETS" | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',[])
print(sum(1 for a in rows if a.get('type')=='分项'))" 2>/dev/null || echo 0)
  DEV_N=$(echo "$CUST_DEVICES" | python3 -c "
import json,sys
d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null || echo 0)
  TOPO_N=$(echo "$CUST_ASSETS" | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',[])
print(sum(1 for a in rows if a.get('type')=='topology'))" 2>/dev/null || echo 0)
  MENU_N=$(api GET "/api/customer/$CUSTOMER_ID" | python3 -c "
import json,sys
d=json.load(sys.stdin)
mid=(d.get('customMenuId') or {}).get('id','')
# 归属走 customer.custom_menu_id；空值哨兵（13814000-…）视为未安装
print(0 if (not mid or mid.startswith('13814000')) else 1)" 2>/dev/null || echo 0)

  if [[ "$SITE_N" -ge 2 ]]; then ok "演示数据：$SITE_N 个场站 / $ITEM_N 个分项"
  else warn "场站不足（$SITE_N 个）—— 演示数据可能未生成"; FAIL=1; fi

  if [[ "$DEV_N" -ge 10 ]]; then ok "演示设备：$DEV_N 台"
  else warn "设备不足（$DEV_N 台）—— 拓扑与看板会没数据"; FAIL=1; fi

  # 拓扑按场站组织：每个场站都应有一张
  if [[ "$TOPO_N" -ge "$SITE_N" ]]; then ok "演示拓扑：$TOPO_N 张（每个场站一张）"
  elif [[ "$TOPO_N" -ge 1 ]]; then
    warn "拓扑只有 $TOPO_N 张，但场站有 $SITE_N 个 —— 部分场站打开是空的（跑 /api/energy/repair-init 可补）"; FAIL=1
  else warn "没有生成拓扑图"; FAIL=1; fi

  if [[ "$MENU_N" == "1" ]]; then ok "客户菜单已安装"
  else warn "客户菜单未安装 —— 客户登录后侧边栏是空的"; FAIL=1; fi

  DASH_N=$(api GET "/api/customer/$CUSTOMER_ID/dashboards?pageSize=100&page=0" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null || echo 0)
  if [[ "$DASH_N" -ge 10 ]]; then ok "仪表板已分配给客户：$DASH_N 个"
  else warn "客户名下仪表板只有 $DASH_N 个 —— 「仪表板」页会是空的"; FAIL=1; fi
fi

echo
if [[ "$FAIL" == "0" ]]; then
  ok "全部验证通过"
else
  die "存在验证失败项，请按上面提示排查"
fi

echo "   客户入口：$BASE/"
echo "   若为客户创建了账号，请用 --customer-email 的邮箱登录验证数据可见性"
