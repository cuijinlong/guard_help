#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
现场演示模拟器 —— 给"不能真机演示"的表计持续喂新鲜数据

<h3>它解决什么问题</h3>
现场演示时手上只有一台 RTU（一台真实单相电表 + 一个温湿度 + 一路继电器），
但客户想看的是**整套系统**：三相电的电能质量、水表、燃气表、蒸汽表、
分项/区域/峰谷/账单……这些没法真机演。

演示数据是一次性快照，几小时后就全部「数据陈旧」，抄表判 stale、账单空。
本脚本让这些表**持续上报**，页面上的曲线一直在走，抄表实时能抄。

<h3>分工（重要）</h3>
| 品种 | 谁来出数 |
| --- | --- |
| 单相电（RTU 那台） | **真实 RTU**，本脚本不碰 |
| 单相电（其余演示表） | 本脚本 |
| 三相电 | 本脚本（真机没三相表） |
| 水 / 燃气 / 蒸汽 | 本脚本 |
| 温湿度（非 RTU 那台） | 本脚本 |

脚本按 `--skip` 或自动识别跳过 RTU 设备（见 `--rtu-devices`），
保证同一台表不会被两个源同时写 —— 那样表底会跳变，抄表判 abnormal。

<h3>数据模型（与平台约定一致，改错会让看板空白）</h3>
```
电表     energy（本周期增量） energy_reading（累积表底，单调递增） power_total
         power_factor_total apparent_power_total
         demand_max（当天最大需量，跨天重置） load_rate（占铭牌容量 %）
         voltage_a [current_a] [power_a]     三相另有 _b / _c
水/气/汽  energy（本周期增量） energy_reading（累积表底） power
温湿度    temperature humidity
```

**表底必须单调递增**，且父表增量 >= 子表之和 —— 验收脚本
（`08-verify-release.sh` 的「演示用电层级守恒」）会查这一条。
本脚本按层级树分配功率，父表 = 子表之和 × (1 + 线损率)，天然满足。

<h3>用法</h3>
```bash
# 跑一轮（给验收/自检用），打印每台表的读数
python3 scripts/23-demo-simulator.py \
  --base http://127.0.0.1:8090 --tenant tenant@126.com --tenant-pass 12345678 \
  --customer 平台演示中心 --once

# 持续跑（每 60 秒一批，Ctrl-C 停）
python3 scripts/23-demo-simulator.py ... --interval 60

# 先看清楚会动哪些表，不写库
python3 scripts/23-demo-simulator.py ... --dry-run

# 同时刷新资产汇总（看板「选场站」读的是资产上的 energy_total）
python3 scripts/23-demo-simulator.py ... --interval 60 --rebuild-totals
```

退出码：0 全部成功；1 有失败。
"""

import argparse
import json
import os
import math
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# 演示环境是否 24 小时运行（2026-11-26）。
#
# 原来的判据是 `working = 6 <= hour < 23` —— 深夜机组停机、风扇不转。
# 那是**仿真工厂作息**的合理设定，但对「演示大屏」是反效果：
# 2026-11-26 凌晨客户打开天骄大屏，9 台机组全部停转，以为模型坏了。
#
# 演示数据的目的是展示大屏效果，不是复刻作息。所以默认 24 小时运行；
# 需要仿真作息时设 `TB_ALWAYS_ON=0`。
ALWAYS_ON = os.environ.get("TB_ALWAYS_ON", "1").strip().lower() not in ("0", "false", "no", "off")

# 与 21-rtu-onboard.py / 30-rtu-env-init.py / 31-rtu-simulate.py 保持一致：
# 这几台由真实 RTU 出数，模拟器不能碰。
#
# ★ 表名必须逐字一致（2026-11-07 修）：原先这里写的是 PowerMeter-DDSU777，
#   而真机设备名是 PowerMeter-DDSU666。一个字母的差别导致这台**真实电表**
#   被当成模拟设备写入 —— 真机在线时两个源同时写，表底会跳变，
#   抄表直接判 abnormal。而脚本自己注释里还写着「与 21 保持一致」，
#   看上去像是核对过了。
#
#   为什么很久没发作：DDSU666 从 11-03 起就没上报（RTU 离线），
#   没有第二个源在写，冲突是隐性的。RTU 一上线就会撞上 ——
#   而那时排查方向会指向「抄表算法有问题」，不会有人怀疑到这里。
RTU_DEFAULT = {"ED1-Gateway", "PowerMeter-DDSU666", "Sensor-HZ8706", "Relay-8CH"}

ELECTRIC_PROFILES = {"单相电能表", "电能表"}
# 热力表也是表计，之前漏了 —— 表现为「13 台表计里永远有 1 台是 stale」，
# 而它并不属于 RTU 真机（真机只有单相电表 + 温湿度 + 继电器）。
UTILITY_PROFILES = {"水表": "water", "燃气表": "gas", "蒸汽表": "steam",
                    "热力表": "heat"}
SENSOR_PROFILES = {"温湿度变送器"}

# ── 暖通（环境系统）设备档案 ─────────────────────────────────
#
# 2026-11-25 之前这里**没有**这一组，于是暖通设备在 discover 里走到
# `continue` —— 永远不产生任何遥测。
#
# 现场表现（客户报障原话）：「冷热机组模块、立式管道离心泵都没有获取到」。
# 设备在查询设置里能勾选（2026-11-25 已修好品种过滤），勾上点查询却是
# 「暂无实时数据」—— 因为它们从安装快照之后就没有新数据了。
# 实测：9 台模块机、2 台离心泵、2 台 PLC 柜停在 11-21 02:00，
# 而电表数据是实时的，客户一眼就看出暖通这块是死的。
#
# 档案名 → 设备角色。角色决定写哪些遥测键（见 build_hvac_payload）。
# 键名必须与「环境系统」品种的指标字典一致，否则查询设置里
# 选得到设备、选不到指标：
#   环境参数 temperature/humidity      运行状态 running/spin/led/door
#   调节参数 opening                   热泵运行 sys_run_state/sys_mode/
#   机组水温 water_in_temp/water_out_temp/ambient_temp   compressor_state
#   水泵频率 pump_freq                 报警代码 alarm_code
HVAC_PROFILES = {
    "风冷冷水机": "chiller",        # 生产园区的「模块机」就是这个档案
    "立式管道离心泵": "pump",
    "热水泵": "pump",
    "锅炉": "boiler",
    "新风机组": "ahu",
    "PLC控制柜": "plc",
    "网关": "gateway",
    "室内环境变送器": "env_sensor",
    "智能空开": "breaker",
    "换热站控制器": "heat_exchanger",
}


# ---------------------------------------------------------------- HTTP
#
# 会话状态（2026-11-25 加）。
#
# <h3>为什么必须自己管 token 续期</h3>
#
# TB 的 access token 默认 2.5 小时过期，而本脚本是**常驻**进程
# （launchd KeepAlive，跑几天不重启）。原实现只在启动时登录一次，
# 把 token 存进局部变量后一直用它 —— 过期之后**每一轮都 401**，
# 但进程还活着，KeepAlive 认为一切正常。
#
# 实测后果（2026-11-25 09:51）：进程 PID 46882 在跑，日志里
# 「第 371 轮：0/49 成功」，全站数据停在 06:09 —— 停了 3 小时 42 分。
# 而看板上没有任何提示，客户以为系统坏了。
#
# 修法：token 放进模块级容器，api() 遇到 401 自动用记住的账号重登一次
# 再重试。调用方不用改，因为它们现在读的是 `_AUTH["token"]`。
# `pass_` 带下划线：避免和内置名 pass（将来若有）混淆，也和 update(pass_=...) 对齐
_AUTH = {"base": None, "user": None, "pass_": None, "token": None, "relogins": 0}


def login(base, user, pw):
    """登录并把账号记下来（供 401 时自动续期）。"""
    _AUTH.update(base=base.rstrip("/"), user=user, pass_=pw)
    body = api(base, "/api/auth/login", method="POST",
               body={"username": user, "password": pw}, _no_retry=True)
    _AUTH["token"] = body["token"]
    return _AUTH["token"]


def _relogin():
    """用记住的账号重新登录。成功返回新 token，失败返回 None。"""
    if not (_AUTH["user"] and _AUTH.get("pass_")):
        return None
    try:
        body = api(_AUTH["base"], "/api/auth/login", method="POST",
                   body={"username": _AUTH["user"], "password": _AUTH["pass_"]},
                   _no_retry=True)
        _AUTH["token"] = body["token"]
        _AUTH["relogins"] += 1
        print("  ↻ 登录已过期，已自动重新登录（第 %d 次）" % _AUTH["relogins"])
        return _AUTH["token"]
    except Exception as e:
        print("  ✗ 重新登录失败：%s" % e)
        return None


def api(base, path, token=None, method=None, body=None, _no_retry=False):
    """一次 HTTP 调用。401 时自动续期并重试一次。

    ★ `token=None` 表示「用当前会话的 token」—— 新增调用点一律省略它，
      这样续期后自动生效，不会拿着一份过期的字符串死磕。
    """
    def once(tok):
        req = urllib.request.Request(base + path, method=method or ("POST" if body else "GET"))
        if body is not None:
            req.data = json.dumps(body).encode()
            req.add_header("Content-Type", "application/json")
        if tok:
            req.add_header("X-Authorization", "Bearer " + tok)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                t = r.read().decode()
                return json.loads(t) if t.strip() else None
        except urllib.error.HTTPError as e:
            raise RuntimeError("HTTP %s %s → %s" % (
                e.code, path, e.read().decode("utf-8", "replace")[:200]))
        except urllib.error.URLError as e:
            raise RuntimeError("连不上平台：%s" % e.reason)

    use = token if token is not None else _AUTH.get("token")
    try:
        return once(use)
    except RuntimeError as e:
        msg = str(e)
        expired = "HTTP 401" in msg or "Token has expired" in msg
        if not expired or _no_retry:
            raise
        newtok = _relogin()
        if not newtok:
            raise
        return once(newtok)


def paged(base, path, token=None):
    """分页取全量。token 参数保留只为兼容旧调用点 —— 实际用会话 token（可续期）。"""
    out, page = [], 0
    while True:
        sep = "&" if "?" in path else "?"
        d = api(base, "%s%spageSize=500&page=%d" % (path, sep, page))
        out.extend(d.get("data") or [])
        if not d.get("hasNext"):
            return out
        page += 1


# ---------------------------------------------------------------- 负载曲线
def load_factor(hour, kind):
    """一天之内的负载系数。让曲线有形，不是一条直线。

    数值取「工业/商业典型日」：凌晨低谷、上午爬坡、午休回落、傍晚再起。
    只影响功率大小，不影响表底单调性。
    """
    if kind == "electric":
        curve = [0.35, 0.32, 0.30, 0.30, 0.33, 0.40, 0.55, 0.72, 0.88, 0.95,
                 0.92, 0.85, 0.78, 0.86, 0.94, 0.96, 0.90, 0.80, 0.70, 0.62,
                 0.55, 0.48, 0.42, 0.38]
    elif kind == "steam":
        # 蒸汽跟着生产班走，午休明显掉
        curve = [0.20, 0.18, 0.18, 0.18, 0.20, 0.30, 0.55, 0.80, 0.95, 0.98,
                 0.92, 0.60, 0.45, 0.85, 0.96, 0.94, 0.85, 0.70, 0.50, 0.35,
                 0.28, 0.25, 0.22, 0.20]
    elif kind == "gas":
        # 燃气：早中晚三餐高峰
        curve = [0.15, 0.12, 0.12, 0.12, 0.15, 0.35, 0.75, 0.85, 0.55, 0.35,
                 0.30, 0.65, 0.85, 0.50, 0.30, 0.28, 0.45, 0.70, 0.80, 0.55,
                 0.35, 0.25, 0.20, 0.17]
    elif kind == "heat":
        # 热力与电/水相反：夜间与清晨供暖负荷高，午后气温上来就回落。
        # 照抄 water 曲线（白天高）会让「热力」这一页看着不像供热，
        # 客户第一眼就会觉得数据是编的 —— 而它确实是编的，更该编得像。
        curve = [0.92, 0.94, 0.95, 0.94, 0.90, 0.82, 0.70, 0.58, 0.46, 0.38,
                 0.34, 0.32, 0.33, 0.36, 0.42, 0.52, 0.64, 0.74, 0.82, 0.88,
                 0.90, 0.91, 0.92, 0.93]
    else:  # water
        curve = [0.25, 0.22, 0.20, 0.20, 0.22, 0.35, 0.62, 0.80, 0.88, 0.85,
                 0.75, 0.70, 0.72, 0.80, 0.86, 0.84, 0.78, 0.70, 0.62, 0.55,
                 0.46, 0.38, 0.32, 0.28]
    return curve[int(hour) % 24]


# ---------------------------------------------------------------- 表计模型
class Meter:
    """一台表的状态机。只保留「表底」和「额定功率」两个关键量。"""

    def __init__(self, name, profile, level, reading, nominal_kw, kind, device_id,
                 phases=1, site_id=""):
        self.name = name
        self.profile = profile
        self.level = level              # 1 进线 / 2 分项 / 3 回路 / 0 不计入
        self.reading = float(reading)   # 累积表底，单调递增
        self.nominal_kw = float(nominal_kw)
        self.kind = kind                # electric / water / gas / steam / heat / sensor
        self.device_id = device_id
        self.phases = phases            # 1 单相 / 3 三相
        self.site_id = site_id
        self.children = []
        self.this_power = 0.0           # 本轮实际功率（compute_power 填）
        self.is_virtual = False         # 虚拟表（手工填报用）不参与自动上报
        self.temp = 24.0
        self.humi = 55.0
        self.temp_drift = 0.0
        # ── 暖通设备的角色与内部状态（kind == "hvac" 时才用）──────────
        # 冷水机组的水温要**缓慢漂移**，不能每轮随机重抽：
        # 查询设置的曲线是按小时聚合的，随机重抽会得到一条锯齿噪声，
        # 而真实机组的水温是一条平滑曲线。这里用上一轮的值做起点。
        self.hvac_type = ""             # chiller / pump / boiler / ahu …
        self.water_in = None            # 回水温度 ℃
        self.water_out = None           # 供水温度 ℃
        # 当天累积最大需量（kW）与它所属的日期。
        #
        # 语义与电能表一致：**当天为周期的最大值，跨天重置**。
        # 2026-11-25 之前本脚本不产出 demand_max，而「用电容量负荷需量监控」
        # 部件读的正是它 —— 于是需量曲线在安装快照用完后整段变空，
        # 页面上只剩开头两天的点。
        self.day_peak = 0.0
        self.day_key = None

    def compute_power(self, hour):
        """算出本周期实际功率，缓存到 self.this_power。**先算子表，再算父表**。

        ★ 为什么必须这样做（2026-10-24 踩过）：
          旧写法让父表按「子表名义值之和 × 1.04」算，而子表自己上报时又各自
          抖动了 ±6%。于是子表之和最大能到 1.06 倍，父表只有 1.04 倍 ——
          验收脚本「父表 >= Σ 子表」当场失败，看起来像演示数据算错了。
          改成先定子表的实际值，父表再由实际值汇总，恒定满足。
        """
        if self.children:
            for c in self.children:
                c.compute_power(hour)
            child_sum = sum(c.this_power for c in self.children)
            # 4% 线损 + 未装表负荷：父表一定 >= 子表之和
            self.this_power = child_sum * 1.04
        else:
            p = self.nominal_kw * load_factor(hour, self.kind)
            self.this_power = p * random.uniform(0.94, 1.06)   # 抖动让折线有毛刺
        return self.this_power


def build_hvac_payload(meter):
    """暖通设备的遥测（kind == "hvac"）。

    <h3>为什么单独一个函数，不复用表计分支</h3>

    暖通设备**不是表计**：没有 `energy_reading`。硬塞一个会让抄表把
    空调算成一台电表（表底从 0 开始、月月不动），账单里凭空多一行。

    <h3>键名与「环境系统」品种的指标字典严格对齐</h3>

    字典的 7 组参数各对应一组键（见 HVAC_PROFILES 上方注释）。
    只写字典里有的键 —— 写别的键，查询设置里指标下拉选了也没数据，
    客户会以为部件坏了。

    <h3>「空调运行监控」页的专属键也一并写</h3>

    那个页面读的是 `ahu_freq` / `ahu_mode` / `boiler_water_temp` /
    `pump_freq_big|small` / `boiler_run_count` / `indoor_temp` / `indoor_co2`，
    与字典口径不同名。两边都写，两个入口才都有数。
    """
    t = meter.hvac_type

    def jitter(v, d, lo=None, hi=None):
        """在 v 附近抖动 ±d，可选上下限。lo/hi 为 None 时不裁剪。

        ★ 不能写成 `min(hi, max(lo, x))` 的一行 lambda：boiler / chiller
          的水温调用只给两个参数，lo/hi 是 None，min(None) 直接抛
          TypeError（'">" not supported between float and NoneType'）。
        """
        x = v + random.uniform(-d, d)
        if lo is not None:
            x = max(lo, x)
        if hi is not None:
            x = min(hi, x)
        return round(x, 2)

    # 设备在不在运行。
    #
    # 默认（ALWAYS_ON）24 小时运行 —— 演示大屏任何时刻打开都要有观感。
    # 设 TB_ALWAYS_ON=0 时按作息仿真：6~23 点运行，深夜停机。
    hour = time.localtime().tm_hour
    working = True if ALWAYS_ON else (6 <= hour < 23)

    if t == "chiller":
        # 冷水机组 / 模块机：供水 7~12℃、回水比供水高 4~6℃
        if meter.water_in is None:
            meter.water_in = random.uniform(11.0, 15.0)
            meter.water_out = random.uniform(6.5, 9.5)
        target_out = 7.0 if working else 10.0
        meter.water_out = jitter(meter.water_out + (target_out - meter.water_out) * 0.25, 0.12, 5.0, 14.0)
        meter.water_in = jitter(meter.water_out + random.uniform(3.6, 5.4), 0.10)
        return {
            "running": 1 if working else 0,
            "sys_run_state": 2 if working else 0,
            "sys_mode": 1,                       # 1=制冷
            "compressor_state": 1 if working else 0,
            "water_in_temp": meter.water_in,
            "water_out_temp": meter.water_out,
            "ambient_temp": round(random.uniform(18.0, 32.0), 1),
            "opening": jitter(75.0, 8.0, 20.0, 100.0),
            "alarm_code": 0,
        }

    if t == "pump":
        # 停机就是 0Hz。抖动幅度按状态区分：运行中 ±6，停机只 ±0.3 ——
        # 原来停机也用 ±6，实测给出 5.24Hz，等于「停着的泵在转」，
        # 客户一眼就看出数据是编的。
        freq = jitter(42.0, 6.0, 0.0, 50.0) if working else jitter(0.0, 0.3, 0.0, 1.0)
        out = {
            "running": 1 if working else 0,
            "pump_freq": freq,
            "opening": jitter(65.0, 10.0, 0.0, 100.0),
            "alarm_code": 0,
        }
        # 「空调运行监控」按名字区分大/小泵
        nm = meter.name or ""
        if "大" in nm:
            out["pump_freq_big"] = freq
            out["pump_run_big"] = 1 if working else 0
        elif "小" in nm:
            out["pump_freq_small"] = freq
            out["pump_run_small"] = 1 if working else 0
        return out

    if t == "boiler":
        if meter.water_out is None:
            meter.water_in = random.uniform(48.0, 55.0)
            meter.water_out = random.uniform(58.0, 65.0)
        meter.water_out = jitter(meter.water_out + ((62.0 if working else 55.0) - meter.water_out) * 0.2, 0.15, 45.0, 75.0)
        meter.water_in = jitter(meter.water_out - random.uniform(6.0, 10.0), 0.12)
        return {
            "running": 1 if working else 0,
            "sys_run_state": 1 if working else 0,
            "sys_mode": 2,                       # 2=制热
            "water_in_temp": meter.water_in,
            "water_out_temp": meter.water_out,
            "opening": jitter(70.0, 8.0, 20.0, 100.0),
            "alarm_code": 0,
            # 「空调运行监控」专属
            "boiler_water_temp": meter.water_out,
            "boiler_run_count": 1 if working else 0,
        }

    if t == "ahu":
        meter.temp = round(meter.temp + random.uniform(-0.2, 0.2), 1)
        meter.humi = round(min(85, max(30, meter.humi + random.uniform(-1.0, 1.0))), 1)
        return {
            "running": 1 if working else 0,
            "spin": 1 if working else 0,
            "opening": jitter(55.0, 12.0, 0.0, 100.0),
            "temperature": meter.temp,
            "humidity": meter.humi,
            "alarm_code": 0,
            # 「空调运行监控」专属
            "ahu_freq": jitter(38.0 if working else 0.0, 5.0, 0.0, 50.0),
            "ahu_mode": 1,
        }

    if t == "plc":
        return {
            "running": 1,
            "led": 1,
            "door": 0,
            "alarm_code": 0,
        }

    if t == "gateway":
        # 网关只报在线状态：它不产业务指标，写别的会污染「环境参数」曲线
        return {"running": 1}

    if t == "env_sensor":
        meter.temp = round(meter.temp + random.uniform(-0.2, 0.2), 1)
        meter.humi = round(min(85, max(30, meter.humi + random.uniform(-1.0, 1.0))), 1)
        return {
            "temperature": meter.temp,
            "humidity": meter.humi,
            "indoor_temp": meter.temp,
            "indoor_co2": round(random.uniform(450.0, 900.0), 0),
        }

    if t == "breaker":
        return {"running": 1, "opening": 100.0}

    if t == "heat_exchanger":
        if meter.water_out is None:
            meter.water_in = random.uniform(50.0, 58.0)
            meter.water_out = random.uniform(44.0, 50.0)
        meter.water_out = jitter(meter.water_out, 0.15)
        meter.water_in = jitter(meter.water_out + random.uniform(5.0, 9.0), 0.12)
        return {
            "running": 1 if working else 0,
            "water_in_temp": meter.water_in,
            "water_out_temp": meter.water_out,
            "opening": jitter(60.0, 10.0, 0.0, 100.0),
        }

    return {"running": 1}


def build_payload(meter, hours):
    """按品种生成遥测字典。键名必须与平台/看板约定一致。"""
    hour = time.localtime().tm_hour
    if meter.kind == "hvac":
        return build_hvac_payload(meter)
    if meter.kind == "sensor":
        meter.temp = round(meter.temp + random.uniform(-0.25, 0.25), 1)
        meter.humi = round(min(90, max(25, meter.humi + random.uniform(-1.2, 1.2))), 1)
        return {"temperature": meter.temp, "humidity": meter.humi}

    power = meter.this_power or meter.compute_power(hour)
    energy = round(power * hours, 4)          # 本周期电量 kWh（水/气/汽按 m³/t 同义）
    if energy <= 0:
        energy = round(abs(random.uniform(0.001, 0.004)), 4)
    meter.reading = round(meter.reading + energy, 4)

    if meter.kind == "electric":
        pf = round(random.uniform(0.88, 0.97), 3)
        # 当天峰值：与安装快照同口径（单调不减，跨天归零）
        today = time.strftime("%Y-%m-%d")
        if meter.day_key != today:
            meter.day_key = today
            meter.day_peak = 0.0
        meter.day_peak = max(meter.day_peak, power)
        out = {
            "energy": energy,
            "energy_reading": round(meter.reading, 3),
            "power_total": round(power, 2),
            "power_factor_total": pf,
            # 需量：表计自报的当天最大需量。缺了它，「用电容量负荷需量监控」
            # 就没有数可画 —— 页面显示「—」，另配的额定容量也算不出负载率。
            "demand_max": round(meter.day_peak, 2),
            # 负载率 = 当前功率 / 铭牌容量，与部件里的口径一致（%）
            "load_rate": round(power / meter.nominal_kw * 100, 2) if meter.nominal_kw > 0 else 0.0,
            "frequency": round(random.uniform(49.92, 50.06), 2),
        }
        if meter.phases == 3:
            # 三相：略不平衡，但必须落在两条国标线内 ——
            #   GB/T 12325 相电压 220V ±7%  → 204.6 ~ 235.4 V
            #   GB/T 15543 不平衡度 ≤ 2%
            #
            # 原来的 base 226~233 + skew ±1.2% 是贴着上限生成的：
            # 最高相能到 235.80 V，不平衡度能到 2.4%。
            # 实测 2026-10-25 就写出了一个 235.43 V、2.13% 的点，
            # 04-verify-data.sh 判失败（差 0.03 V / 0.13%）。
            # 留 2.5% 以上余量：均值 216~230（±3%），单相偏移 ±0.8%
            #   → 最高相 ≤ 231.8 V，最低相 ≥ 214.3 V，不平衡度 ≤ 1.6%
            base_v = random.uniform(216.0, 230.0)
            skew = [random.uniform(-0.008, 0.008) for _ in range(3)]
            v = [round(base_v * (1 + s), 2) for s in skew]
            p_each = power / 3.0
            i_each = [round(p_each * 1000 / x / pf, 2) if x else 0 for x in v]
            out.update({
                "voltage_a": v[0], "voltage_b": v[1], "voltage_c": v[2],
                "voltage_avg": round(sum(v) / 3, 2),
                "current_a": i_each[0], "current_b": i_each[1], "current_c": i_each[2],
                "current_avg": round(sum(i_each) / 3, 2),
                "power_a": round(p_each, 2), "power_b": round(p_each, 2), "power_c": round(p_each, 2),
                "power_factor_a": pf, "power_factor_b": pf, "power_factor_c": pf,
                "reactive_power_total": round(power * math.tan(math.acos(pf)), 2),
                "apparent_power_total": round(power / pf, 2),
                "voltage_unbalance": round(abs(max(v) - min(v)) / (sum(v) / 3) * 100, 2),
            })
        else:
            v = round(random.uniform(222.0, 234.0), 1)
            out.update({
                "voltage_a": v,
                "current_a": round(power * 1000 / v / pf, 3) if v else 0,
            })
        # 视在/无功：单相表也必须有。
        #
        # 原来只在三相分支里写，结果单相表（办公园区的进线总表就是单相）
        # 没有 apparent_power_total —— 「功率因数与负荷需量」的多表加权
        # 会因为缺 S 退化成算术平均，标注也跟着变，看起来像算错了。
        out["apparent_power_total"] = round(power / pf, 2)
        out["reactive_power_total"] = round(power * math.tan(math.acos(pf)), 2)
        return out

    # 水 / 燃气 / 蒸汽
    return {
        "energy": energy,
        "energy_reading": round(meter.reading, 3),
        "power": round(power, 3),
    }


# ---------------------------------------------------------------- 发现设备
def discover(base, token, customer_id):
    """读客户名下全部设备 + 档案 + meterLevel，构建表计模型。"""
    profiles = {p["id"]["id"]: p["name"] for p in paged(base, "/api/deviceProfiles", token)}
    devices = paged(base, "/api/customer/%s/deviceInfos" % customer_id, token)

    meters = []
    for d in devices:
        did = d["id"]["id"]
        name = d.get("name") or ""
        prof_name = profiles.get((d.get("deviceProfileId") or {}).get("id"), "")
        ai = d.get("additionalInfo") or {}
        level = 0
        try:
            attrs = api(base, "/api/plugins/telemetry/DEVICE/%s/values/attributes/SERVER_SCOPE" % did)
            m = {x["key"]: x["value"] for x in (attrs or [])}
            level = int(m.get("meterLevel") or 0)
        except Exception:
            pass

        if prof_name in ELECTRIC_PROFILES:
            kind = "electric"
            # 相数按**档案**判断，不能按名字：演示数据里「三相园-办公区总表」
            # 挂的是「单相电能表」档案（办公照明本来就是单相负荷）。
            # 按名字会给单相表写 B/C 相键，而验收要求「单相表不写 B/C 相」。
            phases = 3 if prof_name == "电能表" else 1
            nominal = 60.0 if level == 1 else (20.0 if level == 2 else 8.0)
        elif prof_name in UTILITY_PROFILES:
            kind = UTILITY_PROFILES[prof_name]
            phases = 1
            nominal = {"gas": 0.35, "water": 0.25, "steam": 0.18,
                       "heat": 0.30}.get(kind, 0.18)
        elif prof_name in SENSOR_PROFILES:
            kind, phases, nominal = "sensor", 1, 0.0
        elif prof_name in HVAC_PROFILES:
            # 暖通设备：不是表计，不写 energy_reading（见 build_hvac_payload）
            kind, phases, nominal = "hvac", 1, 0.0
        else:
            continue

        # 当前表底：接着历史往下走，不能从 0 开始（否则抄表算出「电量倒走」）
        reading = 0.0
        try:
            d2 = api(base, "/api/plugins/telemetry/DEVICE/%s/values/timeseries?keys=energy_reading&limit=1&orderBy=DESC" % did)
            pts = d2.get("energy_reading") or []
            if pts and pts[0].get("value") is not None:
                reading = float(pts[0]["value"])
        except Exception:
            pass

        m = Meter(name, prof_name, level, reading, nominal, kind, did,
                  phases=phases, site_id=ai.get("siteId") or "")
        if kind == "hvac":
            m.hvac_type = HVAC_PROFILES[prof_name]
            # 水温从历史接上：查询设置的曲线按小时聚合，每轮重抽会得到锯齿
            if m.hvac_type in ("chiller", "boiler", "heat_exchanger"):
                try:
                    d4 = api(base, "/api/plugins/telemetry/DEVICE/%s/values/timeseries"
                                    "?keys=water_in_temp,water_out_temp&limit=1&orderBy=DESC" % did)
                    wi = (d4.get("water_in_temp") or [{}])[0].get("value")
                    wo = (d4.get("water_out_temp") or [{}])[0].get("value")
                    if wi is not None:
                        m.water_in = float(wi)
                    if wo is not None:
                        m.water_out = float(wo)
                except Exception:
                    pass
        # 虚拟表（additionalInfo.deviceVirtual == "virtual"）是「手工填报」页的载体，
        # 只有月首点、不写 energy_reading。给它自动上报等于自己演示的两种口径打架，
        # 还会让手工填报页的月值被小时数据淹没 —— 一律跳过。
        m.is_virtual = str(ai.get("deviceVirtual") or "").lower() == "virtual"
        meters.append(m)

        # 温度从历史接上，避免曲线从 24℃ 突然开始
        if kind == "sensor":
            try:
                d3 = api(base, "/api/plugins/telemetry/DEVICE/%s/values/timeseries?keys=temperature,humidity&limit=1&orderBy=DESC" % did)
                if d3.get("temperature"):
                    meters[-1].temp = float(d3["temperature"][0]["value"])
                if d3.get("humidity"):
                    meters[-1].humi = float(d3["humidity"][0]["value"])
            except Exception:
                pass

    # 建层级：**直接读平台已有的 Contains 关系**，不按名字猜。
    #
    # ★ 为什么不能自己猜（2026-10-24 实测）：
    #   第一版按「level 3 轮流挂到各 level 2」分配，结果把「空压机组」挂到了
    #   「办公区总表」下、「办公照明回路」挂到了「车间动力总表」下 ——
    #   数字仍然守恒，但演示时点开办公区会看到空压机，一眼就是错的。
    #   演示数据的层级关系本来就建好了（账单、验收都按它算），照着用即可。
    by_id = {m.device_id: m for m in meters}
    for m in meters:
        if m.kind != "electric":
            continue
        try:
            rels = api(base, "/api/relations?fromId=%s&fromType=DEVICE&relationType=Contains"
                       "&relationTypeGroup=COMMON" % m.device_id)
        except Exception:
            rels = []
        for r in (rels or []):
            to = r.get("to") or {}
            if to.get("entityType") != "DEVICE":
                continue
            child = by_id.get(to.get("id"))
            if child and child is not m and child.kind == "electric":
                m.children.append(child)

    return meters


# ---------------------------------------------------------------- 上报
def device_token(base, token, device_id):
    cred = api(base, "/api/device/%s/credentials" % device_id)
    return cred.get("credentialsId")


def push(base, token, meter, hours, dry=False):
    payload = build_payload(meter, hours)
    # 必须带 ts：不带时平台会把整包存成一个 "values" 键（2026-10-24 实测）
    body = {"ts": int(time.time() * 1000), "values": payload}
    if dry:
        return payload
    dtok = device_token(base, token, meter.device_id)
    api(base, "/api/v1/%s/telemetry" % dtok, method="POST", body=body)
    return payload


# ---------------------------------------------------------------- 主流程
def main():
    ap = argparse.ArgumentParser(description="现场演示模拟器（多能源持续上报）")
    ap.add_argument("--base", default="http://127.0.0.1:8090")
    ap.add_argument("--tenant", required=True)
    ap.add_argument("--tenant-pass", required=True)
    ap.add_argument("--customer", required=True, help="客户名称")
    ap.add_argument("--interval", type=float, default=60, help="上报间隔秒（默认 60）")
    ap.add_argument("--count", type=int, default=0, help="跑几轮，0=一直跑")
    ap.add_argument("--once", action="store_true", help="等价于 --count 1")
    ap.add_argument("--dry-run", action="store_true", help="只打印，不写库")
    ap.add_argument("--rebuild-totals", action="store_true",
                    help="每轮结束后重算资产汇总（看板「选场站」维度才更新）")
    ap.add_argument("--include-rtu", action="store_true",
                    help="连 RTU 的四台也模拟（默认跳过，真机在跑时别开）")
    ap.add_argument("--only", help="只模拟名字含该关键字的设备")
    ap.add_argument("--skip", default="", help="跳过名字含该关键字的设备（逗号分隔）")
    args = ap.parse_args()
    if args.once:
        args.count = 1

    base = args.base.rstrip("/")
    login(base, args.tenant, args.tenant_pass)
    token = _AUTH["token"]

    custs = paged(base, "/api/customers", token)
    hit = [c for c in custs if args.customer in (c.get("title"), c.get("name"), c["id"]["id"])]
    if not hit:
        raise SystemExit("找不到客户「%s」。现有：%s" % (
            args.customer, ", ".join(c.get("title") or "?" for c in custs)))
    cid = hit[0]["id"]["id"]
    print("客户：%s（%s）" % (hit[0].get("title"), cid[:8]))

    meters = discover(base, token, cid)

    skips = [s.strip() for s in args.skip.split(",") if s.strip()]
    chosen = []
    for m in meters:
        if not args.include_rtu and m.name in RTU_DEFAULT:
            continue
        if args.only and args.only not in m.name:
            continue
        if any(s in m.name for s in skips):
            continue
        if m.is_virtual:
            continue
        chosen.append(m)

    by_kind = {}
    for m in chosen:
        by_kind[m.kind] = by_kind.get(m.kind, 0) + 1
    print("模拟设备：%d 台  (%s)" % (len(chosen),
          " / ".join("%s %d" % (k, v) for k, v in sorted(by_kind.items()))))
    if not chosen:
        raise SystemExit("没有可模拟的设备：客户名下没有表计，或全被 --skip/--only 排除了")
    if not args.include_rtu:
        print("已跳过 RTU 设备：%s（真机在跑，避免两个源同时写表底）" % ", ".join(sorted(RTU_DEFAULT)))

    hours = args.interval / 3600.0
    rounds = 0
    fail = 0
    zero_streak = 0
    print("-" * 96)
    try:
        while True:
            rounds += 1
            t0 = time.time()
            n_ok = 0
            for m in chosen:
                try:
                    p = push(base, token, m, hours, dry=args.dry_run)
                    n_ok += 1
                    if rounds == 1 or args.count == 1:
                        # 首轮逐台打印，之后只打汇总（否则日志太长）
                        main_key = ("power_total" if m.kind == "electric"
                                    else "temperature" if m.kind == "sensor"
                                    # 暖通没有 power 键，按角色挑一个最有代表性的
                                    else "water_out_temp" if m.hvac_type in ("chiller", "boiler")
                                    else "pump_freq" if m.hvac_type == "pump"
                                    else "temperature" if m.hvac_type == "env_sensor"
                                    else "running" if m.kind == "hvac"
                                    else "power")
                        print("  %-36s %-18s %s" % (m.name[:34], main_key, p.get(main_key)))
                except Exception as e:
                    fail += 1
                    print("  ✗ %-34s %s" % (m.name[:34], e))

            if args.rebuild_totals and not args.dry_run:
                try:
                    r = api(base, "/api/energy/asset-totals/rebuild", method="POST",
                            body={"customerId": cid, "days": 2})
                    print("  ↻ 资产汇总已刷新（%s 个资产）" % (r or {}).get("assetsWritten", "?"))
                except Exception as e:
                    print("  ! 资产汇总刷新失败：%s" % e)

            print("[%s] 第 %d 轮：%d/%d 成功，耗时 %.1fs%s" % (
                time.strftime("%H:%M:%S"), rounds, n_ok, len(chosen),
                time.time() - t0, "（dry-run，未写库）" if args.dry_run else ""))

            # ── 连续全失败要吼出来 ──────────────────────────────
            #
            # 为什么（2026-11-25 真事故）：
            #   token 过期后本脚本不会续期，于是**每一轮都是 0/49**，
            #   而进程还活着、KeepAlive 认为一切正常。实测从 06:09 到 09:51
            #   连跑 371 轮全失败，日志每分钟一行 0/49 —— 混在正常输出里
            #   完全不显眼，客户只看到「看板数据不动了」。
            #
            # 现在：
            #   1. 401 会自动续期（见 _relogin），兜住最常见的原因；
            #   2. 连续 3 轮一台都没写进去就打一条一眼能看见的告警，
            #      之后每 10 轮重复一次（不刷屏但不会沉底）。
            if n_ok == 0 and len(chosen) > 0:
                zero_streak += 1
            else:
                zero_streak = 0
            if zero_streak >= 3 and (zero_streak == 3 or zero_streak % 10 == 0):
                print("!" * 96)
                print("!! 已连续 %d 轮未写入任何设备（第 %d 轮）。看板数据此刻正在停更！" % (
                    zero_streak, rounds))
                print("!! 排查顺序：① 平台是否可达  ② 账号密码是否改过（续期会失败）")
                print("!!           ③ 设备 token 是否被重置  ④ 后端日志有无 5xx")
                print("!" * 96)
            if args.count and rounds >= args.count:
                break
            time.sleep(max(1.0, args.interval - (time.time() - t0)))
    except KeyboardInterrupt:
        print("\n已停止（Ctrl-C）")

    print("-" * 96)
    print("完成 %d 轮，失败 %d 次" % (rounds, fail))
    if fail:
        print("有失败项，按上面的 ✗ 查（常见：设备 token 取不到 / 平台不可达）")
    return 1 if fail else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as e:
        print("✗ %s" % e, file=sys.stderr)
        sys.exit(1)
