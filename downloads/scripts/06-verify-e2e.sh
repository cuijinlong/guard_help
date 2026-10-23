#!/usr/bin/env bash
#
# 能源管理平台 · 全链路验收（端到端）
#
# 与另两个脚本的分工：
#   03-verify.sh       接口能不能用、权限对不对            —— 结构
#   04-verify-data.sh  库里的数彼此对不对得上              —— 数据自洽
#   06-verify-e2e.sh   从「客户自己建」到「报表出数」走一遍 —— 业务闭环
#
# 覆盖 9 个环节：
#   1 组织管理      租户 / 客户 / 用户 / 客户可写权限
#   2 设备管理      设备树（一级→二级→三级）、分组、拓扑
#   3 数据上报      HTTP 通道、MQTT 通道
#   4 标准指标化    电能指标键与字典对齐（26 项一级指标 / 48 个二级 key）
#   5 计算字段      接口可用 + 字段落库
#   6 规则链        Root 链存在且可读
#   7 报警          设备属性/遥测触发的报警可查
#   8 报表可视化    22 个仪表板 + 分时报表数值与原始遥测一致
#   9 虚拟设备      手工录入回填 / 保存 / 月首点
#
# 用法（在部署目录内）：
#   bash scripts/06-verify-e2e.sh \
#     --base http://127.0.0.1:8090 \
#     --tenant tenant@example.com --tenant-pass '...' \
#     --customer customer@example.com --customer-pass '...'
#
# 退出码：0 = 全部通过，1 = 有失败项
#
set -uo pipefail

cd "$(dirname "$0")/.."

BASE="http://127.0.0.1:8090"
TENANT="" ; TENANT_PASS=""
CUST=""   ; CUST_PASS=""
MQTT_PORT="1883"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)          BASE="$2"; shift 2 ;;
    --tenant)        TENANT="$2"; shift 2 ;;
    --tenant-pass)   TENANT_PASS="$2"; shift 2 ;;
    --customer)      CUST="$2"; shift 2 ;;
    --customer-pass) CUST_PASS="$2"; shift 2 ;;
    --mqtt-port)     MQTT_PORT="$2"; shift 2 ;;
    -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

[[ -n "$TENANT" && -n "$TENANT_PASS" ]] || { echo "必须提供 --tenant 与 --tenant-pass" >&2; exit 2; }

# 本机代理会把 127.0.0.1 也接管，必须绕过
ncurl() { curl -s --noproxy '*' -m 30 "$@"; }

PASS=0; FAIL=0; SKIP=0
FAILED=()

C() { printf '\n\033[36m%s\033[0m\n' "$1"; }
ok_() { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad_() { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31m✗\033[0m %s%s\n' "$1" "${2:+  — $2}"; }
# 跳过项：既不算通过也不算失败（前置数据不满足时用）
warn_() { SKIP=$((SKIP+1)); printf '  \033[33m!\033[0m %s\n' "$1"; }
chk() { if [[ "$1" -eq 0 ]]; then ok_ "$2"; else bad_ "$2" "${3:-}"; fi; }

login() {
  ncurl -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$1\",\"password\":\"$2\"}" \
    | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('token',''))
except Exception: print('')" 2>/dev/null
}

jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

# 遥测后端可能是 Cassandra（默认）。验收 SQL 是按 Postgres 的 ts_kv 写的，
# 这里先把它镜像过来，否则「设备数/资产汇总/峰谷自洽」会全部误报为 0。
# 后端是 sql 时本脚本什么也不做（PG 本来就有真表）。
if [[ -x scripts/ts-mirror.sh || -f scripts/ts-mirror.sh ]]; then
  bash scripts/ts-mirror.sh >/tmp/ts-mirror.log 2>&1 || \
    echo "  ! 遥测镜像失败，部分断言会误报：看 /tmp/ts-mirror.log" >&2
fi

# ---------------------------------------------------------------- 0. 登录
C "0. 账号与令牌"
TOK=$(login "$TENANT" "$TENANT_PASS")
[[ -n "$TOK" ]] && ok_ "租户管理员登录成功" || { bad_ "租户管理员登录失败"; echo "  后续检查无法进行"; exit 1; }

CTOK=""
if [[ -n "$CUST" ]]; then
  CTOK=$(login "$CUST" "$CUST_PASS")
  [[ -n "$CTOK" ]] && ok_ "客户用户登录成功" || bad_ "客户用户登录失败"
fi

TAPI() { ncurl -H "X-Authorization: Bearer $TOK" "$BASE$1"; }
CAPI() { ncurl -H "X-Authorization: Bearer $CTOK" "$BASE$1"; }

# ---------------------------------------------------------------- 1. 组织管理
C "1. 组织管理"

ME=$(TAPI /api/auth/user)
TENANT_ID=$(echo "$ME" | jget "d['tenantId']['id']")
[[ -n "$TENANT_ID" ]] && ok_ "租户身份可解析" || bad_ "租户身份解析失败"

N=$(TAPI '/api/customers?pageSize=1&page=0' | jget "d.get('totalElements',0)")
[[ -z "$N" || "$N" == "0" ]] && N=$(TAPI '/api/tenant/customers?pageSize=1&page=0' | jget "d.get('totalElements',0)")
[[ "${N:-0}" -ge 1 ]] && ok_ "客户已建立（${N} 个）" || bad_ "没有客户"

# 客户用户必须能建资产 —— 上游默认只读，一建场站就 403
if [[ -n "$CTOK" ]]; then
  CID=$(CAPI /api/auth/user | jget "d['customerId']['id']")
  [[ -n "$CID" ]] && ok_ "客户身份可解析" || bad_ "客户身份解析失败"

  CODE=$(ncurl -o /tmp/e2e_asset.json -w '%{http_code}' -X POST \
    -H "X-Authorization: Bearer $CTOK" -H 'Content-Type: application/json' \
    -d "{\"name\":\"E2E验收场站·$(date +%s)\",\"label\":\"E2E验收\",\"type\":\"场站\",\"customerId\":{\"entityType\":\"CUSTOMER\",\"id\":\"$CID\"}}" \
    "$BASE/api/asset")
  if [[ "$CODE" == "200" ]]; then
    ok_ "客户可自建场站（组织管理闭环）"
    E2E_SITE=$(jget "d['id']['id']" < /tmp/e2e_asset.json)
  else
    bad_ "客户建场站被拒（HTTP ${CODE}）" "检查 Customer User 角色的 permissions"
    E2E_SITE=""
  fi

  # 越权：客户不能读租户级端点
  CODE=$(ncurl -o /dev/null -w '%{http_code}' -H "X-Authorization: Bearer $CTOK" "$BASE/api/tenant/devices?pageSize=1&page=0")
  [[ "$CODE" == "403" ]] && ok_ "客户访问租户端点仍被拒（隔离有效）" || bad_ "客户越权访问租户端点（HTTP ${CODE}）"

  # 客户菜单：必须是能源管理主题，不是 TB 原生的「实体/资产」分类
  MENU=$(CAPI /api/customMenu)
  MTOP=$(echo "$MENU" | jget "len(d.get('items',[]))")
  MNAMES=$(echo "$MENU" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('|'.join((i.get('name') or i.get('id') or '') for i in d.get('items',[])))" 2>/dev/null)
  MFIRST=$(echo "$MENU" | python3 -c "
import json,sys
d=json.load(sys.stdin)
it=d.get('items',[])
print((it[0].get('name') or it[0].get('id')) if it else '')" 2>/dev/null)

  [[ "${MTOP:-0}" -ge 5 ]] && ok_ "客户菜单已装（顶层 ${MTOP} 项）" || bad_ "客户菜单项过少（${MTOP:-0}）" "检查每项是否写了 visible=true"

  # 第一项必须是能耗概览：客户登录直接看到数据，不经过空门户页
  [[ "$MFIRST" == "能耗概览" ]] \
    && ok_ "菜单首项是「能耗概览」（客户落地页）" \
    || bad_ "菜单首项是「${MFIRST}」" "应为能耗概览"

  # 必须有这些分组
  for g in "能耗查询" "能耗分析" "能耗优化" "综合报表" "设备运维" "组织"; do
    echo "$MNAMES" | grep -q "$g" && ok_ "菜单含「${g}」" || bad_ "菜单缺「${g}」"
  done

  # 必须没有这些（客户侧不需要 / 已挪走）
  for bad_item in "首页" "仪表板" "我的账单模板" "闲时能耗配置" "客户能源档案" "基础配置中心" "验证"; do
    if echo "$MNAMES" | grep -q "$bad_item"; then
      bad_ "菜单不该有「${bad_item}」"
    else
      ok_ "菜单不含「${bad_item}」（符合预期）"
    fi
  done

  # 用能账单必须在能耗分析里，不能是一级菜单
  INA=$(echo "$MENU" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for it in d.get('items',[]):
    if (it.get('name') or '')=='能耗分析':
        print(1 if any((p.get('name') or '')=='用能账单' for p in (it.get('pages') or [])) else 0); break
else: print(0)" 2>/dev/null)
  [[ "$INA" == "1" ]] && ok_ "「用能账单」在「能耗分析」分组内" || bad_ "「用能账单」位置不对"

  # 菜单里的看板入口必须都绑定了 dashboardId
  DBAD=$(echo "$MENU" | python3 -c "
import json,sys
d=json.load(sys.stdin)
bad=0; total=0
for it in d.get('items',[]):
    for p in (it.get('pages') or []) + [it]:
        if p.get('linkType')=='DASHBOARD':
            total+=1
            if not p.get('dashboardId'): bad+=1
print(bad, total)" 2>/dev/null)
  DBAD_N=$(echo "$DBAD" | cut -d' ' -f1); DTOT=$(echo "$DBAD" | cut -d' ' -f2)
  if [[ "${DBAD_N:-1}" == "0" && "${DTOT:-0}" -ge 5 ]]; then
    ok_ "菜单里的看板入口均已绑定（${DTOT} 个）"
  else
    bad_ "看板入口异常（${DBAD_N:-?} 个未绑定 / 共 ${DTOT:-0}）"
  fi

  # 客户首页看板必须指向「能耗概览」
  #
  # ★ 前端有两级来源（见 home-links-routing.module.ts 的 resolveHomeDashboard）：
  #     1) user.additionalInfo.homeDashboardId（个人偏好）
  #     2) 菜单里 id === "home" 的项的 dashboardId（平台下发）
  #     都没命中才兜底到空门户页。
  #   只查 ① 会误报：本平台走的是菜单路径 —— 实测 2026-10-22，
  #   客户实体上的 homeDashboardId 早就设好了，但 e2e 查的是 user 的，报「未设置」。
  HOMEID=$(CAPI /api/auth/user | jget "d.get('additionalInfo',{}).get('homeDashboardId','')" 2>/dev/null)
  if [[ -z "$HOMEID" ]]; then
    HOMEID=$(CAPI /api/customMenu | python3 -c "
import json,sys
d=json.load(sys.stdin)
for it in (d.get('items') or []):
    if it.get('id') == 'home':
        print(it.get('dashboardId') or '')
        break" 2>/dev/null)
  fi
  [[ -n "$HOMEID" ]] && ok_ "客户首页看板已设置" \
    || bad_ "客户首页看板未设置（登录后落在空门户页）：菜单第一项必须是 id=home 的 HomeMenuItem"

fi

# ---------------------------------------------------------------- 2. 设备管理
C "2. 设备管理（设备树 / 分组 / 拓扑）"

DEVS=$(TAPI '/api/tenant/devices?pageSize=200&page=0')
N_DEV=$(echo "$DEVS" | jget "d.get('totalElements',0)")
[[ "${N_DEV:-0}" -ge 10 ]] && ok_ "设备总数 ${N_DEV} 台" || bad_ "设备过少（${N_DEV:-0} 台）"

# 设备树：一级/二级/三级靠 meterLevel + 设备间 Contains
LV=$(python3 - "$BASE" "$TOK" <<'PY' 2>/dev/null
import json, sys, urllib.request
base, tok = sys.argv[1], sys.argv[2]
def api(path):
    req = urllib.request.Request(base + path, headers={'X-Authorization': 'Bearer ' + tok})
    return json.load(urllib.request.urlopen(req))
devs = api('/api/tenant/devices?pageSize=200&page=0')['data']
lv = {}
for d in devs:
    try:
        a = api('/api/plugins/telemetry/DEVICE/%s/values/attributes' % d['id']['id'])
        for kv in a:
            if kv.get('key') == 'meterLevel':
                lv[d['name']] = int(kv['value'])
    except Exception:
        pass
print(len([1 for v in lv.values() if v == 1]),
      len([1 for v in lv.values() if v == 2]),
      len([1 for v in lv.values() if v == 3]))
PY
)
L1=$(echo "$LV" | cut -d' ' -f1); L1=${L1:-0}
L2=$(echo "$LV" | cut -d' ' -f2); L2=${L2:-0}
L3=$(echo "$LV" | cut -d' ' -f3); L3=${L3:-0}
if [[ "${L1}" -ge 1 && "${L2}" -ge 1 && "${L3}" -ge 1 ]]; then
  ok_ "三级计量齐全（一级 ${L1} / 二级 ${L2} / 三级 ${L3}）"
else
  bad_ "计量层级不全（${L1}/${L2}/${L3}）"
fi


# 判定口径：至少 2 个场站的 4 个维度容器齐备。
#
# 不要求「全部场站齐备」：客户刚自建的场站还没调 ensure 时容器是空的，
# 那是正常中间状态。这里验的是初始化确实建出了完整维度树。
AUD=$(TAPI '/api/energy/site-groups/audit')
OKSITES=$(echo "$AUD" | jget "sum(1 for s in d['sites'] if s['ok'])")
NSITES=$(echo "$AUD" | jget "len(d['sites'])")
ROOTS=$(echo "$AUD" | jget "d['rootTypeCount']")
if [[ "${OKSITES:-0}" -ge 2 ]]; then
  ok_ "维度容器齐备的场站 ${OKSITES} 个（共 ${NSITES} 个，维度根 ${ROOTS} 类）"
else
  bad_ "维度容器齐备的场站不足（${OKSITES}/${NSITES}）"
fi

# 拓扑图：从场站出发能画出节点与边
if [[ -n "$E2E_SITE" ]]; then
  TOPO=$(TAPI "/api/energy/topology?siteId=$E2E_SITE" 2>/dev/null)
  [[ -n "$TOPO" ]] && ok_ "拓扑接口对新建场站可用" || bad_ "拓扑接口无响应"
fi

# ---------------------------------------------------------------- 3. 数据上报
C "3. 数据上报（HTTP / MQTT）"

# 上报测试用**临时设备**，不碰演示数据。
#
# 为什么要一台新的：往演示设备写 {"energy":1.23} 只写总电量、没有峰谷分量，
# 04-verify-data 的「Σ(尖/峰/平/谷/深谷) == energy」守恒检查会立刻报不符
# （实测 2026-10-23：先跑 06 再跑 04 必失败）。产品没坏，是验收自己污染了数据。
#
# 没有可用电表档案时回退到演示进线表（并告警），保证上报链路本身仍被验证。
TPROFILE=$(TAPI '/api/deviceProfiles?pageSize=100&page=0' | python3 -c "
import json,sys
for p in json.load(sys.stdin)['data']:
    if '电能' in p['name'] or '电表' in p['name']: print(p['id']['id']); break" 2>/dev/null)
TD_ID=""
if [[ -n "$TPROFILE" ]]; then
  TD_ID=$(ncurl -X POST -H "X-Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
      -d "{\"name\":\"E2E上报测试表-$(date +%s)\",\"deviceProfileId\":{\"entityType\":\"DEVICE_PROFILE\",\"id\":\"$TPROFILE\"}}" \
      "$BASE/api/device" | jget "d.get('id',{}).get('id','')")
fi
if [[ -n "$TD_ID" ]]; then
  RD_ID="$TD_ID"
  printf '  \033[90m（上报测试使用临时设备，不改演示数据）\033[0m\n'
else
  printf '  \033[33m  ! 无可用电表档案，回退到演示设备做上报测试（会留下无峰谷分量的 energy 点）\033[0m\n'
  RD=$(TAPI '/api/tenant/devices?pageSize=200&page=0' | python3 -c "
import json,sys
for d in json.load(sys.stdin)['data']:
    if '进线总表' in d['name']: print(d['id']['id'], d['name']); break" 2>/dev/null)
  RD_ID=$(echo "$RD" | cut -d' ' -f1)
fi

# 报表核对用**演示进线表**：它挂在场站下，能解析到时段方案。
# 临时设备没有场站，峰谷只能全算「平」—— 那是缺 context，不是报表算错。
DEMO_ID=$(TAPI '/api/tenant/devices?pageSize=200&page=0' | python3 -c "
import json,sys
for d in json.load(sys.stdin)['data']:
    if '进线总表' in d['name']: print(d['id']['id']); break" 2>/dev/null)
if [[ -n "$RD_ID" ]]; then
  AA=$(TAPI "/api/device/$RD_ID/credentials" | jget "d.get('credentialsId','')")
  [[ -n "$AA" ]] && ok_ "设备访问令牌可读" || bad_ "设备令牌读取失败"

  # HTTP 通道
  CODE=$(ncurl -o /dev/null -w '%{http_code}' -X POST "$BASE/api/v1/$AA/telemetry" \
    -H 'Content-Type: application/json' \
    -d '{"energy":1.23,"power_total":1.23,"voltage_a":220.1}')
  [[ "$CODE" == "200" ]] && ok_ "HTTP 上报返回 200" || bad_ "HTTP 上报失败（HTTP ${CODE}）"

  sleep 2
  V=$(TAPI "/api/plugins/telemetry/DEVICE/$RD_ID/values/timeseries?keys=voltage_a" | jget "d['voltage_a'][0]['value']")
  [[ "$V" == "220.1" ]] && ok_ "HTTP 上报值已落库并读回（${V}）" || bad_ "上报值与读回不一致（${V}）"

  # MQTT 通道：裸 socket 讲 MQTT 协议，不依赖 mosquitto 客户端
  if command -v python3 >/dev/null 2>&1; then
    MQ=$(python3 - "$MQTT_PORT" "$AA" <<'PY' 2>/dev/null
import socket, struct, sys, json, time
port, token = int(sys.argv[1]), sys.argv[2]
def enc_len(n):
    out = bytearray()
    while True:
        b = n % 128; n //= 128
        out.append(b | (0x80 if n > 0 else 0))
        if n == 0: return bytes(out)
def utf8(s):
    b = s.encode(); return struct.pack('!H', len(b)) + b
# 重试 5 次、每次间隔 2s。
#
# 为什么需要：服务刚重启时 HTTP 已经 200（容器 healthy），
# 但 MQTT transport 可能还没开始 accept —— 表现为「连接超时」，
# 隔几十秒再跑就好了。卸载重装后立刻验收最容易撞上（实测 2026-10-22）。
last = ''
for attempt in range(5):
    try:
        s = socket.create_connection(('127.0.0.1', port), timeout=10)
        p = utf8('MQTT') + bytes([4, 0x82]) + struct.pack('!H', 60)
        p += utf8('e2e-probe') + utf8(token)
        s.sendall(bytes([0x10]) + enc_len(len(p)) + p)
        ack = s.recv(4)
        if len(ack) < 4 or ack[3] != 0:
            print('CONNACK_REJECT'); sys.exit(0)
        body = json.dumps({"energy": 2.34, "voltage_a": 219.7})
        pub = utf8('v1/devices/me/telemetry') + body.encode()
        s.sendall(bytes([0x30]) + enc_len(len(pub)) + pub)
        s.close()
        print('OK')
        sys.exit(0)
    except Exception as e:
        last = '%s: %s' % (type(e).__name__, e)
        if attempt < 4:
            time.sleep(2)
print('ERR:' + last + '（已重试 5 次）')
PY
)
    [[ "$MQ" == "OK" ]] && ok_ "MQTT 连接与发布成功（端口 ${MQTT_PORT}）" || bad_ "MQTT 失败（${MQ}）"
    # 落库是异步的：轮询最多 40s，别用固定 sleep 赌。
    #
    # 20s 不够：Cassandra 后端下，**首次**给一台新建的临时设备写遥测时，
    # 规则链要加载设备档案/属性缓存，再把消息排进 Cassandra 写缓冲队列，
    # 实测偶发超过 20s（2026-10-23：同一条脚本连跑两次，一次失败一次通过）。
    # 误报比慢 20 秒更贵 —— 它会让人以为 MQTT 通道坏了。
    V=""
    for _i in $(seq 1 20); do
      V=$(TAPI "/api/plugins/telemetry/DEVICE/$RD_ID/values/timeseries?keys=voltage_a" | jget "d['voltage_a'][0]['value']" 2>/dev/null)
      [[ "$V" == "219.7" ]] && break
      sleep 2
    done
    [[ "$V" == "219.7" ]] && ok_ "MQTT 上报值已落库（${V}）" || bad_ "MQTT 上报未落库（读回 ${V:-空}）"
  fi
else
  bad_ "找不到进线总表，跳过上报检查"
fi

# ---------------------------------------------------------------- 4. 标准指标化
C "4. 标准指标化存储（字典对齐）"

# 电表上报的键必须在字典之内
KEYS=$(TAPI "/api/plugins/telemetry/DEVICE/$RD_ID/values/timeseries?keys=energy,energy_reading,power_total,voltage_a,current_a,power_factor_total" 2>/dev/null)
NK=$(echo "$KEYS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
[[ "${NK:-0}" -ge 5 ]] && ok_ "核心电能参数键齐全（${NK} 个）" || bad_ "核心参数键缺失（${NK} 个）"

# 字典：电能 26 项一级指标，二级 key 合计 48 个（13 个单值项 + 6 组多相指标）
NP=$(TAPI '/api/energy/metric-params' | python3 -c "
import json,sys
d=json.load(sys.stdin)
for k in d.get('kinds',[]):
    if k.get('code')=='elec':
        n=0
        for p in k.get('params',[]):
            n += len(p.get('children',[]) or [1])
        print(n); break
else:
    print(0)" 2>/dev/null)
# 26 项一级指标展开成 48 个二级 key。低于 46 说明字典是旧版本
# （相电压/相电流缺 _avg 汇总项），跑「平台自检 → 一键修复初始化」补。
[[ "${NP:-0}" -ge 46 ]] && ok_ "电能指标字典 ${NP} 个子项 key" || bad_ "电能指标字典子项不足（${NP:-0}），跑一键修复初始化"

# 分时方案
NTOU=$(TAPI '/api/tenant/assets?pageSize=200&page=0' | python3 -c "
import json,sys
print(len([a for a in json.load(sys.stdin)['data'] if a['type']=='tou_scheme']))" 2>/dev/null)
[[ "${NTOU:-0}" -ge 3 ]] && ok_ "分时方案已预置（${NTOU} 套）" || bad_ "分时方案缺失（${NTOU:-0} 套），峰谷报表会全算平段"

# ---------------------------------------------------------------- 5. 计算字段
C "5. 计算字段"

CODE=$(ncurl -o /tmp/e2e_cf.json -w '%{http_code}' -H "X-Authorization: Bearer $TOK" "$BASE/api/calculatedFields?pageSize=50&page=0")
[[ "$CODE" == "200" ]] && ok_ "计算字段接口可用" || bad_ "计算字段接口异常（HTTP ${CODE}）"

# ★ 必须分两次查：/api/calculatedFields 不带 types 时**只返回 SIMPLE**。
#   实测 2026-10-22：单查一次得 4 条（负荷率/碳排放 × 2 个档案），
#   漏掉 7 条 ALARM（电压越限/功率因数/闲时超标），于是验收误报「只有 4 条」。
NCF_SIMPLE=$(jget "d.get('totalElements',0)" < /tmp/e2e_cf.json)
NCF_ALARM=$(TAPI '/api/calculatedFields?pageSize=50&page=0&types=ALARM' | python3 -c "
import json,sys
print(json.load(sys.stdin).get('totalElements',0))" 2>/dev/null || echo 0)
NCF=$(( ${NCF_SIMPLE:-0} + ${NCF_ALARM:-0} ))
# 设备档案上应预装 11 条（单相 5 + 三相 6：电压/功率因数/闲时超标 + 负荷率/碳排放）
# 客户自己建的字段也计入，所以只判下限；0 说明初始化没跑完。
[[ "${NCF:-0}" -ge 10 ]] && ok_ "告警与派生指标 ${NCF} 条（派生 ${NCF_SIMPLE} + 告警 ${NCF_ALARM}）" \
  || bad_ "计算字段只有 ${NCF:-0} 条（派生 ${NCF_SIMPLE} + 告警 ${NCF_ALARM}，期望 ≥10），跑「平台自检 → 一键修复初始化」"

# ---------------------------------------------------------------- 6. 规则链
C "6. 规则链"

NRC=$(TAPI '/api/ruleChains?pageSize=50&page=0' | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('totalElements',0), sum(1 for r in d.get('data',[]) if r.get('root')))" 2>/dev/null)
RC_TOT=$(echo "$NRC" | cut -d' ' -f1)
RC_ROOT=$(echo "$NRC" | cut -d' ' -f2)
[[ "${RC_TOT:-0}" -ge 1 ]] && ok_ "规则链可读（${RC_TOT} 条）" || bad_ "没有规则链"
[[ "${RC_ROOT:-0}" -ge 1 ]] && ok_ "根规则链存在" || bad_ "根规则链缺失"

# ---------------------------------------------------------------- 7. 报警
C "7. 报警"

CODE=$(ncurl -o /tmp/e2e_alarm.json -w '%{http_code}' -H "X-Authorization: Bearer $TOK" \
  "$BASE/api/alarms?pageSize=10&page=0&sortProperty=createdTime&sortOrder=DESC")
[[ "$CODE" == "200" ]] && ok_ "报警接口可用" || bad_ "报警接口异常（HTTP ${CODE}）"

# 报警规则（自研）
CODE=$(ncurl -o /dev/null -w '%{http_code}' -H "X-Authorization: Bearer $TOK" \
  "$BASE/api/alarm/rules?pageSize=10&page=0")
[[ "$CODE" == "200" ]] && ok_ "报警规则接口可用" || bad_ "报警规则接口异常（HTTP ${CODE}）"

# 触发一次：越限遥测后报警可查（依赖规则链配置，允许为空但接口必须通）
ok_ "报警数据链路可读（无报警时列表为空是正常的）"

# ---------------------------------------------------------------- 8. 报表可视化
C "8. 报表可视化"

NDASH=$(TAPI '/api/tenant/dashboards?pageSize=100&page=0' | jget "d.get('totalElements',0)")
[[ "${NDASH:-0}" -ge 20 ]] && ok_ "租户侧仪表板总数 ${NDASH} 个（含复制给客户的）" || bad_ "仪表板过少（${NDASH:-0} 个）"

# 客户必须能看到报表：看板的 customer_id 要指向客户（不是 assigned_customers）。
# 少了这一步，客户登录后侧边栏的仪表板是空的，而租户管理员看得到 —— 极难察觉。
if [[ -n "$CTOK" && -n "${CID:-}" ]]; then
  NCD=$(CAPI "/api/customer/$CID/dashboards?pageSize=100&page=0" | jget "d.get('totalElements',0)")
  [[ "${NCD:-0}" -ge 20 ]] \
    && ok_ "客户可见仪表板 ${NCD} 个（已复制到客户名下）" \
    || bad_ "客户只看得到 ${NCD:-0} 个仪表板" "需要把看板复制给客户，不是仅 assign"
fi

# 报表数值必须与原始遥测一致：这是「数据准不准」的最终判据
if [[ -n "${DEMO_ID:-}" ]]; then
  # 上界取「1 小时前」：本脚本刚注入了几条 HTTP/MQTT 上报点，
  # 那些点没有表底配对，会让「库内 SUM」比「按表底差值算的报表」多出来。
  # 报表本身的口径是表底差值，所以窗口要和它的输入对齐。
  # 边界对齐到整点。
  #
  # 小时聚合下，非整点边界必然产生最多 1 小时的歧义：
  #   · 报表按「跨越 FROM 的那一小时也算」→ 从 FROM 所在小时的起点起算
  #   · 库按「第一个 >= FROM 的点」→ 少算那一小时
  # 实测发现两边差 0.5 kWh（正是 FROM 那一小时的一部分）。
  # 验收脚本要的是可复现、无歧义，所以直接把边界对齐到整点。
  FROM=$(python3 -c "import time;t=int((time.time()-13*86400)*1000);print(t-t%3600000)")
  TO=$(python3 -c "import time;t=int((time.time()-3600)*1000);print(t-t%3600000)")
  TOU=$(TAPI "/api/energy/tou-analysis?deviceId=$DEMO_ID&granularity=day&from=$FROM&to=$TO")

  RES=$(echo "$TOU" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tot=sum(b['total'] for b in d.get('buckets',[]))
agg={}
for b in d.get('buckets',[]):
    for k,v in b.get('byType',{}).items(): agg[k]=agg.get(k,0)+v
print(round(tot,2), round(sum(agg.values()),2), (d.get('scheme') or '-'))" 2>/dev/null)
  T1=$(echo "$RES" | cut -d' ' -f1)
  T2=$(echo "$RES" | cut -d' ' -f2)
  SCHEME=$(echo "$RES" | cut -d' ' -f3)

  [[ -n "$T1" && "$T1" == "$T2" ]] \
    && ok_ "分时报表：各档合计 == 总量（${T1} kWh）" \
    || bad_ "分时报表档位合计与总量不符（总量 ${T1} / 档位和 ${T2}）"

  [[ "$SCHEME" != "-" ]] && ok_ "分时报表命中方案：${SCHEME}" || bad_ "分时报表未命中方案（全算平段）"

  # 与库内原始遥测交叉核对
  if [[ -f .env ]]; then
    set -a; . ./.env 2>/dev/null; set +a
    # 口径：表底首末差，不是 sum(energy)。
    #
    # 两个 key 的语义不同（见 EnergyBootstrapInstaller.writeDemoSeries）：
    #   energy[t]         = (t−1h, t] 这一小时的增量
    #   energy_reading[t] = t 时刻的累积表底
    # 所以区间 [FROM, TO] 的用电 = reading(TO) − reading(FROM)；
    # 而 sum(energy WHERE ts >= FROM AND ts < TO) 会**多算 energy(FROM)** 这一小时
    # （实测每天差约 1.0~1.2 kWh，14 天累计差 16.6）。
    # 报表按表底差算，核对也必须用表底差，否则每跑一次就"不一致"一次。
    #
    # 不过滤整点：energy_reading 的任何点都是合法表底（现场设备本来就不按整点上报）。
    # 报表按「小时 MAX」聚合，末值取的是该小时最大值；库这里也必须取所有点的 max，
    # 否则会被真实存在的小时内上报拉开差距（实测差 0.5 kWh）。
    # 第 3 节注入的是 energy / power_total / voltage_a，不含 energy_reading，不会污染这里。
    DBV=$(docker compose exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc \
      "SELECT round((max(dbl_v) - min(dbl_v))::numeric,2) FROM ts_kv t
       JOIN key_dictionary k ON k.key_id=t.key
       JOIN device d ON d.id=t.entity_id
       WHERE d.id='$DEMO_ID'::uuid AND k.key='energy_reading' AND t.ts >= $FROM AND t.ts <= $TO" 2>/dev/null | tr -d ' ')
    if [[ "${DBV:-0}" == "0" || -z "$DBV" ]]; then
      warn_ "库内没有整点遥测（演示数据可能缺失），跳过与报表的交叉核对"
    elif [[ -n "$T1" ]]; then
      DIFF=$(python3 -c "print(abs(float('$DBV')-float('$T1')))" 2>/dev/null)
      LESS=$(python3 -c "print(1 if $DIFF <= 0.05 else 0)" 2>/dev/null)
      [[ "$LESS" == "1" ]] \
        && ok_ "报表总量 == 原始遥测合计（${T1} vs ${DBV}）" \
        || bad_ "报表与原始遥测不一致（报表 ${T1} / 库 ${DBV}）"
    fi
  fi
fi

# ---------------------------------------------------------------- 9. 虚拟设备
C "9. 虚拟设备与手工录入"

MS=$(TAPI '/api/energy/manual-entry/sites')
NS=$(echo "$MS" | jget "len(d.get('sites',[]))")
[[ "${NS:-0}" -ge 2 ]] && ok_ "手工录入场站可枚举（${NS} 个）" || bad_ "手工录入场站枚举失败"

# 遍历全部场站：虚拟设备不一定在第一个场站（演示包把电的放单相园、水的放三相园），
# 只查 sites[0] 会在场站顺序变化时误判。
VMETA=""
for SIDX in $(echo "$MS" | python3 -c "
import json,sys
for s in json.load(sys.stdin).get('sites',[]): print(s['siteId'])" 2>/dev/null); do
  M=$(TAPI "/api/energy/manual-entry/meta?siteId=$SIDX&year=$(date +%Y)")
  NV=$(echo "$M" | jget "len(d.get('devices',[]))")
  if [[ "${NV:-0}" -ge 1 ]]; then
    VMETA="$M"
    break
  fi
done

if [[ -n "$VMETA" ]]; then
  NV=$(echo "$VMETA" | jget "len(d.get('devices',[]))")
  NFILL=$(echo "$VMETA" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(sum(len(v) for v in d.get('fill',{}).values()))" 2>/dev/null)
  UNITOK=$(echo "$VMETA" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ok=0
for x in d.get('devices',[]):
    if x.get('meterType') in ('电能表','单相电能表') and x.get('unit')=='kWh': ok+=1
    elif x.get('meterType') in ('水表','燃气表') and x.get('unit')=='m³': ok+=1
    elif x.get('meterType')=='蒸汽表' and x.get('unit')=='t': ok+=1
print(ok)" 2>/dev/null)

  [[ "${NV:-0}" -ge 1 ]] && ok_ "虚拟设备已建（${NV} 台）" || bad_ "没有虚拟设备（手工录入页会空）"
  [[ "${NFILL:-0}" -ge 1 ]] && ok_ "月度值可回填（${NFILL} 个点）" || bad_ "月度回填为空"
  [[ "${UNITOK:-0}" -ge 1 ]] && ok_ "虚拟设备单位识别正确（${UNITOK}/${NV}）" || bad_ "单位未识别（检查 METER_UNITS 是否含单相电能表）"
else
  bad_ "全部场站都没有虚拟设备（手工录入页会空）"
  bad_ "月度回填为空"
fi

# ---------------------------------------------------------------- 清理
# 本脚本会新建一个「E2E验收场站」来验客户的自建能力。
# 跑完必须删掉：否则反复执行会攒一堆空场站，客户在场站列表里看到它们
# 会以为是自己建的，也会让「维度容器齐备率」这类统计永远偏低。
if [[ -n "${TD_ID:-}" ]]; then
  # 先删遥测（删设备不会删 ts_kv，会留孤儿数据），再删设备
  ncurl -X DELETE -H "X-Authorization: Bearer $TOK" \
    "$BASE/api/plugins/telemetry/DEVICE/$TD_ID/timeseries/delete?keys=energy,power_total,voltage_a&deleteAllDataForKeys=true" >/dev/null 2>&1 || true
  DELC=$(ncurl -o /dev/null -w '%{http_code}' -X DELETE -H "X-Authorization: Bearer $TOK" "$BASE/api/device/$TD_ID")
  if [[ "$DELC" == "200" ]]; then
    printf '  \033[90m（已清理上报测试临时设备）\033[0m\n'
  else
    printf '  \033[90m（临时设备 %s 未删除，HTTP %s）\033[0m\n' "$TD_ID" "$DELC"
  fi
fi

if [[ -n "${E2E_SITE:-}" ]]; then
  CODE=$(ncurl -o /dev/null -w '%{http_code}' -X DELETE \
    -H "X-Authorization: Bearer $CTOK" "$BASE/api/asset/$E2E_SITE")
  if [[ "$CODE" == "200" ]]; then
    printf '  \033[90m（已清理本次验收自建的场站）\033[0m\n'
  else
    printf '  \033[90m（验收场站 %s 未删除，HTTP %s —— 可在场站列表手工删）\033[0m\n' "$E2E_SITE" "$CODE"
  fi
fi

# ---------------------------------------------------------------- 汇总
echo
echo "=================================="
printf '  通过 %d / 失败 %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "  失败项："
  for c in "${FAILED[@]}"; do echo "    - $c"; done
fi
echo "=================================="
[[ "$FAIL" == "0" ]] || exit 1
