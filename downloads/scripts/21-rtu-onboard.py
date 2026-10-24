#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RTU 现场演示设备安装器 —— 给真实 RTU（HaaS506-ED1）在平台上备齐 4 台设备

<h3>为什么需要它</h3>
平台重装、换客户、销户重建之后，**RTU 相关设备一个都不会自动出现**。
RTU 一上电就会：
  ① 用网关设备的访问令牌连 MQTT；
  ② 发 v1/gateway/connect 声明 ED1-Gateway，再上报三台下挂设备。
设备不存在时 TB 会「自动创建」，但建出来是 default 档案、没有场站归属、
没有 meterLevel —— 设备管理页里能看到一堆没名字归属的孤儿，抄表/台账/看板都不认。
所以必须**提前**把 4 台设备按演示结构建好。

<h3>设备清单（名字与 rtu/main.py 逐字一致，改了固件连不上）</h3>
| 设备 | 档案 | meterLevel | 说明 |
| --- | --- | --- | --- |
| ED1-Gateway | 网关 | - | MQTT 网关本体，令牌固定 |
| PowerMeter-DDSU777 | 单相电能表 | 0 | 真实单相电表；level=0 = 不计入场站汇总 |
| Sensor-HZ8706 | 温湿度变送器 | - | 温湿度 |
| Relay-8CH | default | - | 8 路继电器（RPC 控制） |

<h3>为什么电表 meterLevel = 0</h3>
演示数据（单相园 / 三相园，21 台表）的账单与「层级守恒」断言是按 meterLevel 分层算的。
真实 RTU 表接进同一个场站后，若给 1/2 级，它会被算进场站汇总与账单总量 ——
演示数字会莫名其妙地变，`08-verify-release.sh` 的守恒断言也可能挂。
level=0 的语义是「不计入汇总」，但它仍然是 isMeter=true 的表计：
设备管理能看、实时数据能看、一键抄表能抄、台账能出账 —— 演示要看的都在，
只是不参与场站级的自动汇总。

<h3>为什么令牌固定</h3>
TB 默认给每台设备随机生成令牌，重装一次就变一次，现场就得重烧固件。
这里把网关令牌固定成 rtu/main.py 里已经写好的那个值 ——
**重装多少次都不用改固件**。改这个值要同时改固件，否则连不上。

<h3>幂等</h3>
按设备名查：已存在就修（档案、归属客户、场站关系、meterLevel、令牌），
不存在才建。反复跑不会产生第二套。

用法（在部署目录内）：

  # 看当前状态（不写任何东西）
  ./scripts/21-rtu-onboard.py --base http://127.0.0.1:8090 \\
      --tenant tenant@126.com --tenant-pass 12345678 --customer 星河工业园 --check

  # 安装 / 修复
  ./scripts/21-rtu-onboard.py --base http://127.0.0.1:8090 \\
      --tenant tenant@126.com --tenant-pass 12345678 --customer 星河工业园

  # 指定场站（默认挑客户名下名字含「单相」的场站）
  ./scripts/21-rtu-onboard.py ... --site 单相园区·星河工业园

退出码：0 = 就绪；1 = 有未修复项。
"""

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

# 与 rtu/main.py 的配置区逐字对应 —— 改这里必须同步改固件
GATEWAY_NAME = "ED1-Gateway"
METER_NAME = "PowerMeter-DDSU777"
SENSOR_NAME = "Sensor-HZ8706"
RELAY_NAME = "Relay-8CH"
GATEWAY_TOKEN = "ED1GatewayDemoRig2026"

PROFILE_GATEWAY = "网关"
PROFILE_METER = "单相电能表"
PROFILE_SENSOR = "温湿度变送器"
PROFILE_RELAY = "default"

METER_LEVEL = 0          # 0 = 不计入场站汇总（见文件头说明）


# ---------------------------------------------------------------- HTTP 基础
def api(base, path, token=None, method=None, body=None, raw=False):
    """发一个 TB REST 请求。失败抛 RuntimeError，消息里带响应体（排错靠它）。"""
    url = base.rstrip("/") + path
    data = None
    headers = {"Content-Type": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    if token:
        headers["X-Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method=method or ("POST" if data else "GET"))
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            text = r.read().decode("utf-8", "replace")
            return text if raw else (json.loads(text) if text.strip() else None)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        raise RuntimeError("HTTP %s %s → %s" % (e.code, path, detail))
    except urllib.error.URLError as e:
        raise RuntimeError("连不上平台 %s：%s" % (url, e.reason))


def paged(base, path, token, page_size=500):
    """把分页接口拉全（TB 的 pageSize 上限 500）。"""
    out, page = [], 0
    while True:
        sep = "&" if "?" in path else "?"
        d = api(base, "%s%spageSize=%d&page=%d" % (path, sep, page_size, page), token)
        out.extend(d.get("data") or [])
        if not d.get("hasNext"):
            return out
        page += 1


# ---------------------------------------------------------------- 步骤
def login(base, user, password):
    d = api(base, "/api/auth/login", method="POST",
            body={"username": user, "password": password})
    tok = (d or {}).get("token")
    if not tok:
        raise RuntimeError("登录失败：%s 没有返回 token" % user)
    return tok


def pick_customer(base, token, wanted):
    # 用 /api/customers（TENANT_ADMIN 可读全部）；/api/tenant/customers 强制要 customerTitle 参数
    rows = paged(base, "/api/customers", token)
    hit = [c for c in rows if wanted in (c.get("name"), c.get("title"),
                                         c.get("id", {}).get("id"))]
    if not hit:
        names = ", ".join(c.get("name") or c.get("title") or "?" for c in rows[:20])
        raise RuntimeError("找不到客户「%s」。现有客户：%s" % (wanted, names or "（无）"))
    return hit[0]


def pick_site(base, token, customer_id, wanted):
    assets = paged(base, "/api/customer/%s/assets" % customer_id, token)
    sites = [a for a in assets if a.get("type") == "场站"]
    if not sites:
        raise RuntimeError("客户名下没有「场站」资产 —— 先跑一键初始化（演示数据）")
    if wanted:
        hit = [s for s in sites if wanted in (s.get("name"), s.get("label"))]
        if not hit:
            names = ", ".join(s.get("name", "?") for s in sites)
            raise RuntimeError("客户名下没有场站「%s」。现有：%s" % (wanted, names))
        return hit[0]
    pref = [s for s in sites if "单相" in (s.get("name") or "")]
    return (pref or sites)[0]


def profile_map(base, token):
    rows = paged(base, "/api/deviceProfiles", token)
    return {p.get("name"): p["id"]["id"] for p in rows}


def devices_by_name(base, token):
    rows = paged(base, "/api/tenant/devices", token)
    return {d.get("name"): d for d in rows}


def ensure_device(base, token, name, profile_id, customer_id, site_id, existing,
                  is_gateway=False):
    """建或修一台设备，返回 (device_id, 动作说明)。

    ★ is_gateway 对应 additionalInfo.gateway = true。
      TB 判定「这个 MQTT 会话是不是网关」只认这一个字段（见
      MqttTransportHandler：读 device.additionalInfo.gateway）。
      漏了它的后果非常隐蔽：CONNECT 认证通过、PUBLISH 也返回成功，
      **但每条消息都被丢弃**，日志只有一行
      「[gatewaySessionHandler] is null … Failed to process publish msg」。
      设备档案设成「网关」并不能替代它（2026-10-24 实测踩过）。
    """
    ai = {"siteId": site_id, "rtuDemo": True}
    if is_gateway:
        ai["gateway"] = True
    body = {
        "name": name,
        "label": name,
        "deviceProfileId": {"entityType": "DEVICE_PROFILE", "id": profile_id},
        "customerId": {"entityType": "CUSTOMER", "id": customer_id},
        "additionalInfo": ai,
    }
    cur = existing.get(name)
    if cur is None:
        d = api(base, "/api/device", token, method="POST", body=body)
        return d["id"]["id"], "新建"
    # 已存在：档案 / 归属客户 / siteId / 网关标志不对就更新（保存接口是 upsert）
    need = False
    if (cur.get("deviceProfileId") or {}).get("id") != profile_id:
        need = True
    if (cur.get("customerId") or {}).get("id") != customer_id:
        need = True
    old_ai = cur.get("additionalInfo") or {}
    if old_ai.get("siteId") != site_id:
        need = True
    if bool(old_ai.get("gateway")) != bool(is_gateway):
        need = True
    if not need:
        return cur["id"]["id"], "已存在"
    body["id"] = {"entityType": "DEVICE", "id": cur["id"]["id"]}
    body["version"] = cur.get("version")
    body["createdTime"] = cur.get("createdTime")
    api(base, "/api/device", token, method="POST", body=body)
    return cur["id"]["id"], "已修复"


def ensure_token(base, token, device_id, wanted):
    """把网关设备的访问令牌改成固定值。返回 (实际令牌, 动作)。"""
    # 取凭证是 GET /api/device/{deviceId}/credentials（不是 ?deviceId= 查询参数）
    cur = api(base, "/api/device/%s/credentials" % device_id, token)
    if cur.get("credentialsId") == wanted:
        return wanted, "已是目标值"
    body = {
        "id": cur["id"],
        "deviceId": {"entityType": "DEVICE", "id": device_id},
        "credentialsType": "ACCESS_TOKEN",
        "credentialsId": wanted,
    }
    api(base, "/api/device/credentials", token, method="POST", body=body)
    return wanted, "已设为固定值"


def ensure_relation(base, token, site_id, device_id):
    """场站 --Contains--> 设备。已存在就跳过。"""
    # 查询是 /api/relations（复数）；/api/relation 只用于建关系。
    # 写成单数会 400，被 except 吞掉后每次都重建关系 —— 表面上「成功」，
    # 实际是在拿数据库赌幂等（2026-10-24 修正）。
    q = urllib.parse.urlencode({
        "fromId": site_id, "fromType": "ASSET",
        "relationType": "Contains", "relationTypeGroup": "COMMON"})
    try:
        rels = api(base, "/api/relations?" + q, token)
    except RuntimeError as e:
        raise RuntimeError("查场站关系失败（不敢盲建，避免重复关系）：%s" % e)
    if any(((r.get("to") or {}).get("id")) == device_id for r in (rels or [])):
        return "关系已存在"
    api(base, "/api/relation", token, method="POST", body={
        "from": {"entityType": "ASSET", "id": site_id},
        "to": {"entityType": "DEVICE", "id": device_id},
        "type": "Contains", "typeGroup": "COMMON",
    })
    return "已建关系"


def ensure_attr(base, token, device_id, attrs):
    api(base, "/api/plugins/telemetry/DEVICE/%s/attributes/SERVER_SCOPE" % device_id,
        token, method="POST", body=attrs)
    return "属性已写"


# ---------------------------------------------------------------- 主流程
def main():
    ap = argparse.ArgumentParser(
        description="为真实 RTU 在平台上准备 4 台设备（幂等）",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="http://127.0.0.1:8090", help="平台地址")
    ap.add_argument("--tenant", required=True, help="租户管理员账号")
    ap.add_argument("--tenant-pass", required=True, help="租户管理员密码")
    ap.add_argument("--customer", required=True, help="客户名称或客户 id")
    ap.add_argument("--site", help="场站名称（默认挑名字含「单相」的场站）")
    ap.add_argument("--check", action="store_true", help="只检查，不写入")
    args = ap.parse_args()

    base = args.base.rstrip("/")
    print("=" * 62)
    print(" RTU 现场演示设备安装%s" % ("（只检查）" if args.check else ""))
    print("=" * 62)

    token = login(base, args.tenant, args.tenant_pass)
    cust = pick_customer(base, token, args.customer)
    cid = cust["id"]["id"]
    print("客户：%s（%s）" % (cust.get("name") or cust.get("title"), cid[:8]))

    site = pick_site(base, token, cid, args.site)
    sid = site["id"]["id"]
    print("场站：%s（%s）" % (site.get("name"), sid[:8]))

    profiles = profile_map(base, token)
    missing = [p for p in (PROFILE_GATEWAY, PROFILE_METER, PROFILE_SENSOR, PROFILE_RELAY)
               if p not in profiles]
    if missing:
        raise RuntimeError("设备档案缺失：%s —— 先跑一键初始化" % ", ".join(missing))

    existing = devices_by_name(base, token)
    plan = [
        (GATEWAY_NAME, PROFILE_GATEWAY, None),
        (METER_NAME, PROFILE_METER, METER_LEVEL),
        (SENSOR_NAME, PROFILE_SENSOR, None),
        (RELAY_NAME, PROFILE_RELAY, None),
    ]

    print("\n设备：")
    result = []
    failed = 0
    for name, prof, level in plan:
        try:
            if args.check:
                cur = existing.get(name)
                if cur is None:
                    print("  ✗ %-20s 缺失（档案应为 %s）" % (name, prof))
                    failed += 1
                    continue
                ok_prof = (cur.get("deviceProfileId") or {}).get("id") == profiles[prof]
                ok_cust = (cur.get("customerId") or {}).get("id") == cid
                ai = cur.get("additionalInfo") or {}
                ok_gw = bool(ai.get("gateway")) == (name == GATEWAY_NAME)
                mark = "✓" if ok_prof and ok_cust and ok_gw else "!"
                notes = []
                if not ok_prof: notes.append("档案不符")
                if not ok_cust: notes.append("归属客户不符")
                if not ok_gw: notes.append("缺 gateway=true" if name == GATEWAY_NAME else "多余 gateway 标志")
                print("  %s %-20s %s%s" % (mark, name, cur["id"]["id"][:8],
                                            ("（" + "、".join(notes) + "）") if notes else ""))
                if notes:
                    failed += 1
                result.append((name, cur["id"]["id"]))
                continue

            did, action = ensure_device(base, token, name, profiles[prof], cid, sid, existing,
                                        is_gateway=(name == GATEWAY_NAME))
            notes = [action]
            notes.append(ensure_relation(base, token, sid, did))
            if level is not None:
                notes.append(ensure_attr(base, token, did, {"meterLevel": level}))
            print("  ✓ %-20s %s  %s" % (name, did[:8], " · ".join(notes)))
            result.append((name, did))
        except RuntimeError as e:
            print("  ✗ %-20s %s" % (name, e))
            failed += 1

    # 网关令牌
    gw_id = next((d for n, d in result if n == GATEWAY_NAME), None)
    if gw_id:
        try:
            got, action = ensure_token(base, token, gw_id, GATEWAY_TOKEN)
            print("\n网关令牌：%s（%s）" % (got, action))
        except RuntimeError as e:
            print("\n✗ 网关令牌设置失败：%s" % e)
            failed += 1

    print("""
------------------------------------------------------------
 RTU 侧连接参数（与 rtu/main.py 的配置区逐字对应）
------------------------------------------------------------
  TB_HOST  = "%s"          ← RTU 要从局域网访问，不能填 127.0.0.1
  TB_PORT  = 11883          （平台另有 1883；固件会自动回退）
  TB_TOKEN = "%s"
  设备名   = %s / %s / %s / %s
------------------------------------------------------------
 固件这几行正常情况下**不用改**：令牌是固定值，重装/重建客户都不变。
 上电后串口第一屏是「配置自检」，对着核一遍即可。
""" % (urllib.parse.urlparse(base).hostname or base, GATEWAY_TOKEN,
       GATEWAY_NAME, METER_NAME, SENSOR_NAME, RELAY_NAME))

    host = urllib.parse.urlparse(base).hostname or ""
    if host in ("127.0.0.1", "localhost"):
        print("  ⚠ 你用的是 %s：板子连不到这个地址。现场请把 --base 换成" % host)
        print("     本机局域网 IP（macOS: ipconfig getifaddr en0），固件的 TB_HOST 填同一个。")

    if failed:
        print("有 %d 项未就绪，按上面的 ✗ 修完再跑一次。" % failed)
        return 1
    print("RTU 演示设备已就绪。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as e:
        print("✗ %s" % e, file=sys.stderr)
        sys.exit(1)
