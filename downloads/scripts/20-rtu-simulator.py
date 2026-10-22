#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RTU 模拟器 —— 没有硬件时用它验证「上报 → 规则链 → 存储 → 报表 → 抄表」全链路。

<h3>为什么需要它</h3>
现场 RTU（HaaS506-ED1）是 MicroPython 板子，装在现场。开发和验收阶段
手上没有板子，但平台侧的 key 转换、抄表、账单、峰谷分析都要有**新鲜数据**
才跑得起来 —— 演示数据是静态的，几小时后就全部「数据陈旧」，
抄表一律判 stale，账单永远是空的。

本脚本复刻 RTU `main.py` 的 `read_meter_values()`：发出**厂家原始代号**
（U / I / P / Q / S / PF / Freq / Ep），而不是平台标准名。
这样可以顺带验证规则链「电表Key标准化」节点是否真的在工作 ——
如果库里还是 U/I/P，说明转换节点没生效（见手册 ③ 五之二）。

<h3>两种上报模式</h3>
  http    直连单设备：POST /api/v1/{deviceToken}/telemetry
          最省事，适合本机验证。
  gateway MQTT 网关：topic v1/gateway/telemetry
          payload {"<设备名>": [{"values": {...}}]}
          与真实 RTU 完全一致，需要 --mqtt-host。

<h3>Ep（表底）的语义</h3>
Ep 是**累积表底**，必须单调递增。脚本每轮把「本小时用电」累加进去，
所以两次抄表之间能算出真实用量。不要每次随机生成 —— 那样抄表会算成
「电量倒走」，被判 abnormal。

用法示例：

  # 1. 看有哪些表、拿 token
  ./20-rtu-simulator.py --base http://127.0.0.1:8090 \\
      --tenant tenant@126.com --tenant-pass 12345678 --list

  # 2. 给一块表持续上报，每 60 秒一次，共 30 次（约 30 分钟）
  ./20-rtu-simulator.py --base http://127.0.0.1:8090 \\
      --tenant tenant@126.com --tenant-pass 12345678 \\
      --device '单相园-1#进线总表·星河工业园' --interval 60 --count 30

  # 3. 一直跑（Ctrl-C 停）
  ./20-rtu-simulator.py ... --device '...' --interval 300 --count 0

  # 4. 网关模式（与真实 RTU 走同一条 MQTT 路径）
  ./20-rtu-simulator.py --base http://127.0.0.1:8090 \\
      --tenant tenant@126.com --tenant-pass 12345678 \\
      --mode gateway --gateway 'ED1-Gateway' \\
      --device '单相园-1#进线总表·星河工业园' --interval 60

退出码：0 全部成功；1 有失败（每条失败原因都打印）。
"""

import argparse
import json
import math
import random
import sys
import time
import urllib.error
import urllib.request

# DDSU666 手册表 8 的原始参数代号 —— 与 rtu/main.py 的 read_meter_values() 一一对应。
# 刻意不发标准名：转换由规则链负责，这样脚本能顺带验证转换节点。
RAW_KEYS = ["U", "I", "P", "Q", "S", "PF", "Freq", "Ep"]


def http_json(url, data=None, token=None, method=None, timeout=60):
    """发一个 JSON 请求，返回 (status, body_text)。不抛异常，由调用方判断。"""
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("X-Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:                                  # 连接被拒 / DNS / 超时
        return 0, str(e)


def login(base, user, password):
    status, body = http_json(base + "/api/auth/login",
                             {"username": user, "password": password})
    if status != 200:
        raise SystemExit(f"登录失败（HTTP {status}）：{body[:300]}")
    return json.loads(body)["token"]


def list_devices(base, token):
    """租户下所有设备 → [(id, name, profileName)]"""
    out = []
    page = 0
    while True:
        status, body = http_json(
            f"{base}/api/tenant/devices?pageSize=100&page={page}", token=token)
        if status != 200:
            raise SystemExit(f"读取设备列表失败（HTTP {status}）：{body[:300]}")
        d = json.loads(body)
        for dev in d.get("data") or []:
            out.append((dev["id"]["id"], dev["name"], dev.get("type") or ""))
        if not d.get("hasNext"):
            break
        page += 1
    return out


def device_token(base, token, device_id):
    """设备的访问令牌（就是现场 RTU 配置里的 TB_TOKEN）"""
    status, body = http_json(f"{base}/api/device/{device_id}/credentials", token=token)
    if status != 200:
        raise SystemExit(f"读取设备令牌失败（HTTP {status}）：{body[:300]}")
    return json.loads(body)["credentialsId"]


class Meter:
    """一块表的模拟状态：表底单调递增，瞬时量围绕额定值小幅波动。"""

    def __init__(self, seed_reading=None, seed_usage=None, rated_kw=3.8):
        self.rated_kw = rated_kw
        # 表底初值：给的种子优先；否则用一个「像运行了很久」的随机值
        self.reading = seed_reading if seed_reading is not None else random.uniform(1200, 3600)
        # 上一轮的电量增量（抄表算的就是相邻两次表底差）
        self.last_usage = seed_usage if seed_usage is not None else random.uniform(0.4, 1.6)

    def sample(self, hours):
        """
        生成一轮读数。hours = 距上次上报经过的小时数，
        用来决定这一轮电量增加多少 —— 让「表底差」与「真实时长」成正比，
        抄表算出来的用量才有物理意义。
        """
        # 负载率随机游走：白天高、夜里低，幅度 ±15%
        load = random.uniform(0.85, 1.15)
        power = round(self.rated_kw * load, 2)          # kW
        usage = round(power * hours, 4)                 # kWh，与时长成正比

        # 表底只增不减 —— 倒走会被抄表判 abnormal
        self.reading = round(self.reading + usage, 3)
        self.last_usage = usage

        voltage = round(random.uniform(228.0, 238.0), 1)
        current = round(power * 1000 / (voltage * 0.99 * 3 ** 0.5), 2)   # 三相估算
        reactive = round(power * random.uniform(0.10, 0.16), 2)
        apparent = round(math.hypot(power, reactive), 2)
        pf = round(power / apparent, 3) if apparent else 1.0

        return {
            "U": voltage,
            "I": current,
            "P": power,
            "Q": reactive,
            "S": apparent,
            "PF": pf,
            "Freq": round(random.uniform(49.95, 50.05), 2),
            "Ep": self.reading,
        }


def post_http(base, token, values):
    status, body = http_json(f"{base}/api/v1/{token}/telemetry", values)
    return status, body


def post_gateway(mqtt_host, mqtt_port, gateway_token, device_name, values):
    """
    网关模式：走与真实 RTU 完全相同的 MQTT 路径。
    这里用标准库手写最小 MQTT 3.1.1 PUBLISH（QoS 0），
    避免给现场脚本引入 paho-mqtt 依赖。
    """
    payload = json.dumps({device_name: [{"values": values}]})
    try:
        import socket, struct

        def enc_str(s):
            b = s.encode()
            return struct.pack("!H", len(b)) + b

        client_id = "rtu-sim-" + str(random.randint(1000, 9999))
        # CONNECT
        var = enc_str("MQTT") + bytes([4, 0x02]) + struct.pack("!H", 60)
        # 用户名 = 网关 access token（ThingsBoard 网关约定）
        var += enc_str(gateway_token) + enc_str(client_id)
        pkt = bytes([0x10]) + bytes([len(var)]) + var

        s = socket.create_connection((mqtt_host, mqtt_port), timeout=15)
        s.sendall(pkt)
        ack = s.recv(4)
        if len(ack) < 4 or ack[0] != 0x20:
            return 0, f"CONNACK 异常: {ack.hex() if ack else '无响应'}"
        if ack[3] != 0:
            return 0, f"MQTT 认证失败，CONNACK 返回码 {ack[3]}（令牌不对？）"

        topic = b"v1/gateway/telemetry"
        # PUBLISH，QoS0
        rem = struct.pack("!H", len(topic)) + topic + payload.encode()
        s.sendall(bytes([0x30]) + bytes([len(rem) if len(rem) < 128 else 0x80 | (len(rem) & 0x7F)]) + rem)
        time.sleep(0.15)
        s.close()
        return 200, "ok"
    except Exception as e:
        return 0, str(e)


def pick_device(devices, wanted):
    """按名字精确匹配，退而求其次做包含匹配 —— 现场设备名常带后缀。"""
    for d in devices:
        if d[1] == wanted:
            return d
    hits = [d for d in devices if wanted in d[1]]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        raise SystemExit(
            f"找不到设备「{wanted}」。可用 --list 查看全部设备名。")
    raise SystemExit(
        "设备名有歧义，匹配到多个：\n  " + "\n  ".join(h[1] for h in hits) +
        "\n请写完整名字。")


def main():
    ap = argparse.ArgumentParser(
        description="RTU 模拟器：按厂家原始代号上报，验证平台全链路",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="http://127.0.0.1:8090", help="平台地址")
    ap.add_argument("--tenant", required=True, help="租户管理员账号")
    ap.add_argument("--tenant-pass", required=True, help="租户管理员密码")
    ap.add_argument("--device", help="设备名（精确或唯一包含匹配）")
    ap.add_argument("--list", action="store_true", help="只列出设备，不上报")
    ap.add_argument("--mode", choices=["http", "gateway"], default="http",
                    help="http=直连单设备；gateway=MQTT 网关（与真实 RTU 一致）")
    ap.add_argument("--gateway", help="网关模式下的网关设备名，如 ED1-Gateway")
    ap.add_argument("--mqtt-host", default="127.0.0.1", help="网关模式的 MQTT 主机")
    ap.add_argument("--mqtt-port", type=int, default=1883, help="网关模式的 MQTT 端口")
    ap.add_argument("--interval", type=float, default=60, help="上报间隔秒数")
    ap.add_argument("--count", type=int, default=1, help="上报次数，0=一直跑")
    ap.add_argument("--seed-reading", type=float, help="表底初值（默认随机 1200~3600）")
    ap.add_argument("--seed-usage", type=float, help="首轮电量增量 kWh")
    ap.add_argument("--rated-kw", type=float, default=3.8, help="额定有功功率 kW")
    args = ap.parse_args()

    base = args.base.rstrip("/")
    token = login(base, args.tenant, args.tenant_pass)

    devices = list_devices(base, token)
    if args.list:
        print(f"共 {len(devices)} 台设备：")
        for _, name, prof in devices:
            print(f"  {name:<44} {prof}")
        return 0

    if not args.device:
        raise SystemExit("必须指定 --device（或用 --list 先看设备名）")

    device_id, device_name, _ = pick_device(devices, args.device)
    dtok = device_token(base, token, device_id)
    print(f"设备：{device_name}")
    print(f"模式：{args.mode}"
          + (f"（网关 {args.gateway}）" if args.mode == "gateway" else "（直连）"))

    gw_token = None
    if args.mode == "gateway":
        if not args.gateway:
            raise SystemExit("网关模式必须指定 --gateway（网关设备名）")
        gw_id, gw_name, _ = pick_device(devices, args.gateway)
        gw_token = device_token(base, token, gw_id)
        print(f"网关：{gw_name}")

    meter = Meter(seed_reading=args.seed_reading,
                  seed_usage=args.seed_usage,
                  rated_kw=args.rated_kw)
    print(f"表底起点：{meter.reading:.3f} kWh")

    ok = fail = 0
    n = 0
    last = time.time()
    try:
        while True:
            n += 1
            now = time.time()
            hours = max((now - last) / 3600.0, 1 / 60.0)     # 至少按 1 分钟计
            last = now

            values = meter.sample(hours)
            if args.mode == "gateway":
                status, body = post_gateway(args.mqtt_host, args.mqtt_port,
                                            gw_token, device_name, values)
            else:
                status, body = post_http(base, dtok, values)

            ts = time.strftime("%H:%M:%S")
            if status == 200:
                ok += 1
                print(f"[{ts}] #{n} ✓ Ep={values['Ep']:.3f} "
                      f"P={values['P']:.2f}kW U={values['U']:.1f}V "
                      f"PF={values['PF']:.3f}")
            else:
                fail += 1
                print(f"[{ts}] #{n} ✗ HTTP {status}: {body[:200]}")

            if args.count and n >= args.count:
                break
            time.sleep(max(args.interval, 0))
    except KeyboardInterrupt:
        print("\n已停止（Ctrl-C）")

    print(f"\n成功 {ok} 次，失败 {fail} 次")
    if fail:
        print("失败常见原因：")
        print("  · HTTP 401 → 设备访问令牌不对（重建设备后令牌会变）")
        print("  · HTTP 404 → 平台地址/端口不对，或设备不属于该租户")
        print("  · 网关模式认证失败 → 网关设备名不对，或它的令牌不是网关令牌")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
