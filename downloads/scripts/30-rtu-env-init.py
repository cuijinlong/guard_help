#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RTU 演示环境一键初始化（2026-11-02）

<h3>为什么是脚本而不是 Java 初始化器</h3>
改 Java 要重新打包 + 重启，一次 10 分钟起步；而演示环境经常要调
（加一台设备、换一个测点）。所以这里**全部走 REST**，改一行重跑几秒。
字典也是：直接写「能源参数字典」资产的 `dictionaries` 属性，业务接口立刻读到，
不需要动 `energy_library.json`、不需要重新打包。

<h3>它建什么</h3>
```
两个场站                  单相园区 / 三相园区（都已存在，脚本只做校验）
├─ ED1-Gateway（真实 RTU） 单相园区
│   ├─ PowerMeter-DDSU666  真实单相电表
│   ├─ Sensor-HZ8706       真实温湿度
│   └─ Relay-8CH           真实 8 路继电器  ← 可控设备（RPC）
└─ ED2-Gateway（模拟）      三相园区
    ├─ PowerMeter-3P-SIM   三相电表 3P4W  ← 覆盖电能质量全场景
    ├─ WaterMeter-SIM      水表
    ├─ GasMeter-SIM        燃气表
    ├─ SteamMeter-SIM      蒸汽表
    ├─ HeatMeter-SIM       热力表
    ├─ AHU-SIM             新风机组（可控）  ← RPC
    └─ Breaker-SIM         智能空开（可控）  ← RPC
```

<h3>幂等</h3>
反复执行只会补缺的，不会重复建、不动已有配置。
唯一会覆盖的是**本脚本自己建的**模拟设备的测点快照（`simulated=true`），
因为那是脚本的产物，需要随脚本版本更新；客户自己配的一律不碰。

<h3>用法</h3>
```bash
python3 scripts/30-rtu-env-init.py                       # 建/补齐
python3 scripts/30-rtu-env-init.py --dry-run             # 只看会做什么
python3 scripts/30-rtu-env-init.py --base http://127.0.0.1:8090 \\
        --tenant tenant@126.com --tenant-pass 12345678
```

退出码：0 全部就绪；1 有失败项。
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

# ---------------------------------------------------------------- 常量
# 场站名由客户名推导（demo-data 建的场站就是这个命名规则）
# 「单相园区·<客户名>」「三相园区·<客户名>」
DEFAULT_CUSTOMER = '平台演示中心'


def site_names(customer):
    return ('单相园区·' + customer, '三相园区·' + customer)


def sim_name(base, customer):
    """模拟实体名 = 基础名 + ·客户名。

    <p>★ 必须带后缀（2026-11-02 实测）：TB 的设备唯一键是 (tenant_id, name)，
    **同一租户下两个客户不能有同名设备**。demo-data 建的设备名带
    `·<客户名>` 后缀，就是这个原因。

    <p>不带后缀的后果：给客户 B 跑脚本时按名字查到的是客户 A 的设备，
    走了「更新」分支却改不了 owner（TB 禁止），最后 B 名下 0 台设备、
    而 A 的设备被改乱了 —— 静默错，没有任何报错。

    <p>真实 RTU 设备（PowerMeter-DDSU666 等）例外：名字由板子 `main.py`
    的 constant 决定，改不了，所以全局只有一套，只属于主演示客户。
    """
    return '%s·%s' % (base, customer)


def gateway_names(customer):
    """网关命名。

    <p>**主演示客户**：真实 RTU 用 `ED1-Gateway`（板子上写死，改不了），
    模拟设备另用一个 `ED2-Gateway·客户名`。

    <p>**其他客户**：没有真实板子，用一个 `ED2-Gateway·客户名` 挂全部模拟设备。
    不能复用 ED1 —— 那是真实板子的身份，把别的客户的设备挂上去，
    一方面语义错（这块板子只接了三台真表），另一方面 prune 和场站归属都会乱
    （实测 2026-11-02：新客户的燃气/水表被挂到了 ED1 下）。
    两个场站的区别靠设备的 `siteId` 体现，不靠网关数量。
    """
    if customer == DEFAULT_CUSTOMER:
        return 'ED1-Gateway', sim_name('ED2-Gateway', customer)
    gw = sim_name('ED2-Gateway', customer)
    return gw, gw
# 网关名由 gateway_names() 按客户推导（真实网关固定，模拟网关带后缀）

# 品种 → 品种资产名（按名字查 id，不写死 uuid：换库/重建后 id 会变）
KIND_NAMES = {'elec': '电能', 'water': '水表', 'gas': '燃气',
              'steam': '蒸汽', 'heat': '热力', 'env': '环境系统'}

# 档案 → (品种, meterTypeCode, 排序, 是否计量, 说明)
PROFILES = {
    '热力表': ('heat', 'heat_meter', 45, True, '热量表（热力）：供回水温度、热功率、累积热量'),
    '温湿度变送器': ('env', 'th_sensor', 50, False, '温湿度采集（非计量器具，但参与环境监测与告警）'),
    '室内环境变送器': ('env', 'indoor_env', 55, False, '室内环境：温度、湿度、CO₂（非计量器具）'),
    '新风机组': ('env', 'ahu', 60, False, '组合式新风机组：送风温度、运行模式、风机频率'),
}


def find_profile(api, name):
    """按名字查设备档案。

    <p>用 /api/deviceProfiles（不是 /api/tenant/deviceProfiles —— 后者把
    「deviceProfiles」当成 UUID 解析，直接 400）。返回 None 表示不存在。
    """
    for p in api.paged('/api/deviceProfiles'):
        if p.get('name') == name:
            return p
    return None


def mp(dev, std, name, unit):
    """一条测点映射（结构必须与后端 writeMeasurePoints 写的一致）"""
    return {'deviceField': dev, 'standardField': std, 'standardName': name,
            'unit': unit, 'ratio': '', 'freq': ''}


# 三相电表的电能质量测点：按行业标准布局生成，避免手抄 100 多行
def _pq_points():
    pts = []
    # 三相电压电流 + 功率
    for ph, u in (('a', 'A'), ('b', 'B'), ('c', 'C')):
        pts.append(mp('U' + ph, 'voltage_' + ph, '%s相电压' % u, 'V'))
    for ph, u in (('a', 'A'), ('b', 'B'), ('c', 'C')):
        pts.append(mp('I' + ph, 'current_' + ph, '%s相电流' % u, 'A'))
    for ph, u in (('a', 'A'), ('b', 'B'), ('c', 'C')):
        pts.append(mp('P' + ph, 'power_' + ph, '%s相有功功率' % u, 'kW'))
    pts += [
        mp('P', 'power_total', '总有功功率', 'kW'),
        mp('Q', 'reactive_power_total', '总无功功率', 'kVar'),
        mp('S', 'apparent_power_total', '总视在功率', 'kVA'),
        mp('PF', 'power_factor_total', '总功率因数', ''),
        mp('Freq', 'frequency', '频率F', 'Hz'),
        mp('Ep', 'energy_reading', '累积读数', 'kW·h'),
        mp('E', 'energy', '本周期用电量', 'kW·h'),
        # 电能质量：电压偏差 / 频率偏差
        mp('UdA', 'voltage_deviation_a', 'A相电压偏差', '%'),
        mp('UdB', 'voltage_deviation_b', 'B相电压偏差', '%'),
        mp('UdC', 'voltage_deviation_c', 'C相电压偏差', '%'),
        mp('Fd', 'frequency_deviation', '频率偏差', 'Hz'),
        # 电能质量：不平衡 + 序分量
        mp('Uunb', 'voltage_unbalance', '电压不平衡率', '%'),
        mp('Iunb', 'current_unbalance', '电流不平衡率', '%'),
        mp('U1', 'voltage_seq_positive', '电压正序分量', 'V'),
        mp('U2', 'voltage_seq_negative', '电压负序分量', 'V'),
        mp('U0', 'voltage_seq_zero', '电压零序分量', 'V'),
        mp('I1', 'current_seq_positive', '电流正序分量', 'A'),
        mp('I2', 'current_seq_negative', '电流负序分量', 'A'),
        mp('I0', 'current_seq_zero', '电流零序分量', 'A'),
        # 电能质量：THD
        mp('THDua', 'voltage_thd_a', 'A相电压畸变率', '%'),
        mp('THDub', 'voltage_thd_b', 'B相电压畸变率', '%'),
        mp('THDuc', 'voltage_thd_c', 'C相电压畸变率', '%'),
        mp('THDia', 'current_thd_a', 'A相电流畸变率', '%'),
        mp('THDib', 'current_thd_b', 'B相电流畸变率', '%'),
        mp('THDic', 'current_thd_c', 'C相电流畸变率', '%'),
        # 电能质量：闪变
        mp('Pinst', 'flicker_pinst', '瞬时闪变视感度', ''),
        mp('Pst', 'flicker_pst', '短时闪变 Pst', ''),
        mp('Plt', 'flicker_plt', '长时闪变 Plt', ''),
    ]
    # 分次谐波 3/5/7/9/11/13 次（国标最关心的几次，全量 2~25 次在字典里）
    for h in (3, 5, 7, 9, 11, 13):
        pts.append(mp('H%du' % h, 'voltage_harmonic_%d' % h, '%d次电压谐波含有率' % h, '%'))
    for h in (3, 5, 7, 9, 11, 13):
        pts.append(mp('H%di' % h, 'current_harmonic_%d' % h, '%d次电流谐波含有率' % h, '%'))
    return pts


# ============ 模拟设备清单 ============
SIM_DEVICES = [
    {
        'name': 'PowerMeter-3P-SIM', 'meterLevel': 1, 'site': 'three', 'gw': 'three',
        'profile': '电能表', 'model': 'DTSD341', 'brand': '威胜',
        'type1': 'elec', 'type2': 'normal', 'l1': 'elec_meter',
        'wiring': '3P4W',
        'note': '模拟三相电表（3P4W）：电压电流潮流 + 电能质量全场景',
        'points': _pq_points(),
    },
    {
        'name': 'WaterMeter-SIM', 'meterLevel': 2, 'site': 'single', 'gw': 'single',
        'profile': '水表', 'model': 'LXSY-20', 'brand': '宁波水表',
        'type1': 'water', 'type2': 'normal', 'l1': 'water_meter',
        'wiring': '',
        'note': '模拟水表：瞬时流量 + 累积读数',
        'points': [mp('F', 'power', '瞬时流量', 'm³/h'),
                   mp('Q', 'energy_reading', '累积读数', 'm³'),
                   mp('T', 'temperature', '水温', '℃')],
    },
    {
        'name': 'GasMeter-SIM', 'meterLevel': 2, 'site': 'single', 'gw': 'single',
        'profile': '燃气表', 'model': 'G2.5', 'brand': '秦川',
        'type1': 'gas', 'type2': 'normal', 'l1': 'gas_meter',
        'wiring': '',
        'note': '模拟燃气表：瞬时流量 + 累积读数 + 压力',
        'points': [mp('F', 'power', '瞬时流量', 'm³/h'),
                   mp('Q', 'energy_reading', '累积读数', 'm³'),
                   mp('P', 'gas_pressure', '燃气压力', 'kPa')],
    },
    {
        'name': 'SteamMeter-SIM', 'meterLevel': 2, 'site': 'three', 'gw': 'three',
        'profile': '蒸汽表', 'model': 'LUGB', 'brand': '横河',
        'type1': 'steam', 'type2': 'normal', 'l1': 'steam_meter',
        'wiring': '',
        'note': '模拟涡街蒸汽表：流量 + 累积 + 温度压力',
        'points': [mp('F', 'power', '瞬时流量', 't/h'),
                   mp('Q', 'energy_reading', '累积读数', 't'),
                   mp('T', 'steam_temp', '蒸汽温度', '℃'),
                   mp('P', 'steam_pressure', '蒸汽压力', 'MPa')],
    },
    {
        'name': 'HeatMeter-SIM', 'meterLevel': 2, 'site': 'three', 'gw': 'three',
        'profile': '热力表', 'model': 'CRL-G', 'brand': '天罡',
        'type1': 'heat', 'type2': 'normal', 'l1': 'heat_meter',
        'wiring': '',
        'note': '模拟热量表：热功率 + 供回水温度 + 累积热量',
        'points': [mp('Q', 'energy_reading', '累积读数', 'GJ'),
                   mp('P', 'heat_power', '热功率', 'kW'),
                   mp('F', 'heat_flow', '瞬时流量', 'm³/h'),
                   mp('Ts', 'supply_temp', '供水温度', '℃'),
                   mp('Tr', 'return_temp', '回水温度', '℃')],
    },
    {
        'name': 'AHU-SIM', 'meterLevel': 0, 'site': 'three', 'gw': 'three',
        'profile': '新风机组', 'model': 'ZK-30', 'brand': '盾安',
        'type1': 'env', 'type2': 'fresh_air_unit', 'l1': 'env_device',
        'wiring': '',
        'note': '模拟新风机组（可控）：送风温湿度、运行模式、风机频率',
        'points': [mp('Ts', 'temperature', '送风温度', '℃'),
                   mp('Hs', 'humidity', '送风湿度', '%RH'),
                   mp('Mode', 'power', '运行模式', ''),
                   mp('Freq', 'frequency', '风机频率', 'Hz')],
    },
    {
        'name': 'Breaker-SIM', 'meterLevel': 0, 'site': 'three', 'gw': 'three',
        'profile': 'default', 'model': 'TGB3-63', 'brand': '天正',
        'type1': 'elec', 'type2': 'smart_breaker', 'l1': 'smart_breaker',
        'wiring': '',
        'note': '模拟智能空开（可控）：分合闸状态、开关次数',
        'points': [mp('State', 'power', '分合闸状态', ''),
                   mp('Cnt', 'energy', '开关次数', ''),
                   mp('Ia', 'current_a', 'A相电流', 'A')],
    },
]

# 演示环境只保留这些设备；其余的由 --prune 清掉。
# 背景：`POST /api/energy/repair-init` 里的 repairHvacModule 会**无条件**为每个
# 客户重建 10 台空调/环境演示设备（A栋新风机组、锅炉、热水泵、室内环境…）。
# 那是给「一键修复」准备的演示兜底，但对 RTU 演示环境是噪音 ——
# 客户看到一堆没有数据源的设备，会以为系统坏了。实测 2026-11-02。
# 真实 RTU 设备（名字写死在板子上，全局唯一）
REAL_DEVICES = {'PowerMeter-DDSU666', 'Sensor-HZ8706', 'Relay-8CH'}


def keep_devices(customer):
    """本客户下不允许被 prune 删掉的设备名。"""
    names = {'ED1-Gateway'} | REAL_DEVICES
    names |= set(gateway_names(customer))
    names |= {sim_name(d['name'], customer) for d in SIM_DEVICES}
    return names


# ============ RPC 能力（写进设备属性，供界面/脚本查）============
RPC_SPECS = {
    'Relay-8CH': {
        'note': '8 路继电器，真实 RTU 执行',
        'methods': [
            {'method': 'setRelay', 'params': {'ch': '1~8', 'state': 'true/false'},
             'desc': '单路开关'},
            {'method': 'setGroupRelay', 'params': {'chs': '[1,2,3]', 'state': 'true/false'},
             'desc': '多路同开同关'},
            {'method': 'setAllRelay', 'params': {'state': 'true/false'}, 'desc': '全部开关'},
            {'method': 'readMeterNow', 'params': {}, 'desc': '立即抄表（触发一次采集上报）'},
        ],
    },
    'AHU-SIM': {
        'note': '新风机组（模拟执行）',
        'methods': [
            {'method': 'setMode', 'params': {'mode': 'auto/manual/off'}, 'desc': '运行模式'},
            {'method': 'setFanSpeed', 'params': {'freq': '0~50'}, 'desc': '风机频率 Hz'},
        ],
    },
    'Breaker-SIM': {
        'note': '智能空开（模拟执行）',
        'methods': [
            {'method': 'setState', 'params': {'state': 'true/false'}, 'desc': '合闸/分闸'},
            {'method': 'getState', 'params': {}, 'desc': '读当前状态'},
        ],
    },
}


class Api:
    def __init__(self, base, dry=False):
        self.base = base.rstrip('/')
        self.dry = dry
        self.token = None
        self.writes = 0

    def login(self, user, password):
        _, r = self.call('POST', '/api/auth/login',
                         {'username': user, 'password': password}, auth=False)
        self.token = r['token']
        return self

    def call(self, method, path, body=None, auth=True):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method)
        if auth and self.token:
            req.add_header('X-Authorization', 'Bearer ' + self.token)
        if data:
            req.add_header('Content-Type', 'application/json')
        try:
            with urllib.request.urlopen(req, timeout=90) as resp:
                txt = resp.read().decode().strip()
                if not txt:
                    return resp.status, {}
                # JSON 才解析；activationLink 这类纯文本原样返回（否则拿不到 token）
                if txt.startswith(('{', '[')):
                    try:
                        return resp.status, json.loads(txt)
                    except ValueError:
                        return resp.status, txt
                return resp.status, txt
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()[:300]

    def get(self, path):
        return self.call('GET', path)[1]

    def post(self, path, body):
        if self.dry:
            self.writes += 1
            return 200, {}   # dry-run: 不写库
        code, r = self.call('POST', path, body)
        if code not in (200, 201, 204):
            raise RuntimeError('POST %s → %s %s' % (path, code, r))
        return code, r

    def paged(self, path):
        out, page = [], 0
        while True:
            sep = '&' if '?' in path else '?'
            d = self.get('%s%spageSize=500&page=%d' % (path, sep, page))
            if not isinstance(d, dict):
                break
            out.extend(d.get('data') or [])
            if not d.get('hasNext'):
                break
            page += 1
        return out


def find_site(api, name):
    for a in api.paged('/api/tenant/assets'):
        if a.get('name') == name:
            return a
    return None


def ensure_profile(api, name, spec, kind_ids, log):
    prof = find_profile(api, name)
    if prof is None:
        body = {
            'name': name, 'description': spec[4],
            'type': 'DEFAULT', 'transportType': 'DEFAULT', 'provisionType': 'DISABLED',
            'profileData': {'configuration': {'type': 'DEFAULT'},
                            'transportConfiguration': {'type': 'DEFAULT'},
                            'provisionConfiguration': {'type': 'DISABLED'}},
        }
        api.post('/api/deviceProfile', body)
        if api.dry:
            log('  + 档案「%s」将新建' % name)
            return {'id': {'id': 'dry-' + name}}
        prof = find_profile(api, name)
        log('  + 档案「%s」已建' % name)
    else:
        log('  · 档案「%s」已存在' % name)
    if prof is None:
        return None

    kind, code, sort, is_meter, note = spec
    api.post('/api/plugins/telemetry/DEVICE_PROFILE/%s/SERVER_SCOPE' % prof['id']['id'], {
        'energyTypeCode': kind,
        'energyTypeAssetId': kind_ids.get(kind, ''),
        'isMeter': is_meter,
        'meterTypeCode': code,
        'meterTypeSort': sort,
        'note': note,
    })
    return prof


def ensure_gateway(api, name, site, customer_id, log):
    dev = next((d for d in api.paged('/api/tenant/devices') if d.get('name') == name), None)
    prof = find_profile(api, '网关')
    ai = {'siteId': site['id']['id'], 'gateway': True,
          'simulated': not name.startswith('ED1-')}
    if dev is None:
        api.post('/api/device', {
            'name': name, 'label': name, 'type': '网关',
            'customerId': {'entityType': 'CUSTOMER', 'id': customer_id},
            'additionalInfo': ai,
        })
        if api.dry:
            log('  + 网关「%s」将新建' % name)
            return {'id': {'id': 'dry-' + name}}
        dev = next((d for d in api.paged('/api/tenant/devices') if d.get('name') == name), None)
        log('  + 网关「%s」已建' % name)
    else:
        log('  · 网关「%s」已存在' % name)
        # 更新已有设备不能带 customerId（owner 只能用专门的 owner 接口改）
        upd = {'id': dev['id'], 'name': name, 'label': name, 'type': '网关',
               'additionalInfo': ai}
        if dev.get('customerId'):
            upd['customerId'] = dev['customerId']
        api.post('/api/device', upd)
    return dev


def ensure_device(api, spec, site, customer_id, gw_id, log):
    name = spec['name']
    dev = next((d for d in api.paged('/api/tenant/devices') if d.get('name') == name), None)
    ai = {'siteId': site['id']['id'], 'simulated': True, 'deviceVirtual': 'real'}

    if dev is None:
        api.post('/api/device', {
            'name': name, 'label': name, 'type': spec['profile'],
            'customerId': {'entityType': 'CUSTOMER', 'id': customer_id},
            'additionalInfo': ai,
        })
        if api.dry:
            log('  + 设备「%s」将新建' % name)
            return {'id': {'id': 'dry-' + name}}
        dev = next((d for d in api.paged('/api/tenant/devices') if d.get('name') == name), None)
        log('  + 设备「%s」已建' % name)
    else:
        log('  · 设备「%s」已存在' % name)
        upd = {'id': dev['id'], 'name': name, 'label': name, 'type': spec['profile'],
               'additionalInfo': ai}
        if dev.get('customerId'):
            upd['customerId'] = dev['customerId']
        api.post('/api/device', upd)
    if dev is None:
        return None

    did = dev['id']['id']
    attrs = {
        'type1': spec['type1'], 'type2': spec['type2'], 'deviceType1': spec['l1'],
        'model': spec['model'], 'brand': spec['brand'], 'active': True,
        # ★ meterLevel 是资产汇总（energy_total）的必需字段：
        #   汇总按「层级最小的那批表」取数，避免总表+分表重复计电。
        #   不写它，场站看板永远是空的 —— 而且没有任何报错（实测 2026-11-02）。
        #   1=进线总表 / 2=分项或回路 / 0=非计量设备
        'meterLevel': spec.get('meterLevel', 0),
        # ★ 必须是 list 对象，不能 json.dumps 成字符串：
        #   TB 把 string 存进 str_v，而平台读的是 json_v，写成字符串等于没写
        #   （实测 2026-11-02：属性"存在"但界面测点 0 条）。
        'measurePoints': spec['points'],
    }
    if spec.get('wiring'):
        attrs['wiring'] = spec['wiring']
    api.post('/api/plugins/telemetry/DEVICE/%s/SERVER_SCOPE' % did, attrs)

    rpc = RPC_SPECS.get(name)
    if rpc:
        api.post('/api/plugins/telemetry/DEVICE/%s/SERVER_SCOPE' % did,
                 {'rpcCommands': rpc})

    api.call('POST', '/api/relation', {
        'from': {'entityType': 'DEVICE', 'id': gw_id},
        'to': {'entityType': 'DEVICE', 'id': did},
        'type': 'Contains', 'typeGroup': 'COMMON',
    })
    return dev


def prune(api, log, dry, customer_id, customer_name):
    """删掉**本客户**名下不在白名单里的设备。

    <p>★ 必须按客户收窄（2026-11-02 实测踩过）：一个租户下可能有好几个客户，
    早期的实现是扫全租户，给客户 A 跑一次会把客户 B 的设备全删光 ——
    而且删完看不出来，直到 B 的人发现自己的设备没了。

    <p>演示设备（repair-init 的 repairHvacModule 重建的那 10 台）也在其中。
    """
    keep = keep_devices(customer_name)
    victims = []
    for d in api.paged('/api/tenant/devices'):
        cid = (d.get('customerId') or {}).get('id')
        if cid != customer_id:
            continue          # 别的客户，一概不碰
        if d.get('name') in keep:
            continue
        victims.append(d)
    if not victims:
        log('  无需清理：只剩白名单设备')
        return 0
    log('  待清理 %d 台：' % len(victims))
    ok = 0
    for d in victims:
        nm = d.get('name')
        if dry:
            log('    - %s' % nm)
            continue
        code, _ = api.call('DELETE', '/api/device/' + d['id']['id'])
        if code in (200, 204):
            ok += 1
            log('    ✓ 已删 %s' % nm)
        else:
            log('    ✗ %s 删除失败 HTTP %s' % (nm, code))
    return ok



# ================================================================
# 包干到底的三步：客户 → 维度 → 设备
# ================================================================

def ensure_customer(api, name, log):
    """客户不存在就建。返回 (customer, 是否新建)。

    <p>演示环境「包干到底」的第一环：新库只有租户管理员，没有客户。
    没有客户就建不了场站、建不了设备 —— 脚本不能指望人去后台点。
    """
    for c in api.paged('/api/customers'):
        if c.get('title') == name:
            return c, False
    if api.dry:
        log('  + 客户「%s」将新建' % name)
        return {'id': {'id': 'dry-customer'}, 'title': name}, True
    api.post('/api/customer', {'title': name, 'country': 'CN'})
    for c in api.paged('/api/customers'):
        if c.get('title') == name:
            log('  + 客户「%s」已建' % name)
            return c, True
    raise RuntimeError('客户「%s」创建后仍查不到' % name)


def assign_owner(api, entity_type, entity_id, customer_id, log):
    """把实体分配给客户（TB 的 owner 只能用专门接口改）。

    <p>为什么要它：RTU 首次上报时 TB 自动建设备，`customerId` 是 NULL_UUID
    （表示「租户下、无客户」）。用 `POST /api/device` 带 customerId 改不了 ——
    返回 `Entity owner can't be changed`。必须走
    `POST /api/customer/{customerId}/{entityType}/{entityId}`。

    <p>实测 2026-11-02：不修这一步，`PowerMeter-DDSU666` 明明在跑数据，
    却不出现在客户的设备列表里，看板按客户过滤时整台表消失。
    """
    if api.dry:
        log('    · 归属将改为该客户')
        return True
    code, r = api.call('POST', '/api/customer/%s/%s/%s'
                       % (customer_id, entity_type.lower(), entity_id))
    if code not in (200, 204):
        log('    ⚠ 归属修改失败 HTTP %s' % code)
        return False
    return True


def ensure_customer_user(api, customer_id, customer_name, log, password='demo123456'):
    """给客户建演示账号并**设好密码**，建完能直接登录。

    <p>三个坑，少一个账号就用不了（全部实测过）：

    <p>**① `sendActivationMail=false` 必须带** —— 平台没配 SMTP 时，默认 true
    会让建用户直接 500「Couldn't send user activation email」。

    <p>**② 建完要拿 activationLink 换 token** —— TB 的新用户是「未激活」，
    没有密码，登录返回 `User account is not active`。激活 token 只有
    `/api/user/{id}/activationLink` 能拿（跳过发邮件那一步）。

    <p>**③ 要用 token 调 `/api/noauth/activate` 设密码** —— 这一步才真正
    把密码写进去并置为 active。跳过它，账号永远登不进去。
    """
    email = 'demo+%s@126.com' % customer_id.replace('-', '')[:8]

    # 已存在就只确认能登录，不重复建
    existing = None
    code, d = api.call('GET', '/api/customer/%s/users?pageSize=100&page=0' % customer_id)
    if isinstance(d, dict):
        existing = next((u for u in (d.get('data') or []) if u.get('email') == email), None)
    if existing is not None:
        log('  · 账号 %s 已存在' % email)
        return email, password

    if api.dry:
        log('  + 账号 %s 将新建' % email)
        return email, password

    code, r = api.call('POST', '/api/user?sendActivationMail=false', {
        'email': email,
        'authority': 'CUSTOMER_USER',
        'customerId': {'entityType': 'CUSTOMER', 'id': customer_id},
        'firstName': customer_name,
        'lastName': '演示账号',
    })
    if code not in (200, 201) or not isinstance(r, dict):
        log('  ⚠ 建账号失败 HTTP %s %s' % (code, str(r)[:120]))
        return None, None
    uid = r['id']['id']

    code, link = api.call('GET', '/api/user/%s/activationLink' % uid)
    token = None
    if isinstance(link, str):
        import re as _re
        m = _re.search(r'activateToken=([A-Za-z0-9_\-]+)', link)
        token = m.group(1) if m else None
    if not token:
        log('  ⚠ 拿不到激活 token，账号已建但登不进去（去「客户与用户 → 用户」手工设密码）')
        return email, None

    code, _ = api.call('POST', '/api/noauth/activate',
                       {'activateToken': token, 'password': password}, auth=False)
    if code not in (200, 204):
        log('  ⚠ 激活失败 HTTP %s' % code)
        return email, None
    log('  + 账号 %s 已建并激活（密码 %s）' % (email, password))
    return email, password


def ensure_dimensions(api, customer_id, customer_name, log):
    """调 demo-data 建维度根 + 场站（幂等）。

    <p>为什么不自己建：维度体系（12 个分项 / 6 个区域 / 6 个楼栋 /
    8 个场站分组 / 能耗类型）是由 `createDimensionRoots` +
    `createDemoPackage` 成套生成的，彼此有 Contains 关系与命名约定。
    在脚本里再抄一遍 = 两套实现必然分叉，改一处忘一处。

    <p>它同时会建 21 台演示设备 —— 那些随后由 `prune` 删掉，
    我们只要资产（场站/分项/区域），设备用带真实数据源的模拟设备替。
    """
    if api.dry:
        log('  · 维度根与场站：将调用 demo-data（幂等）')
        return
    code, r = api.call('POST', '/api/energy/demo-data', {'customerId': customer_id,
                                                        'customerName': customer_name})
    if code not in (200, 204):
        raise RuntimeError('建维度失败 HTTP %s %s' % (code, r))
    log('  ✓ 维度根与场站就绪（资产 %s 个 / 演示设备 %s 台，设备随后清理）'
        % (r.get('assets', '?'), r.get('devices', '?')))


def ensure_dictionary(api, log):
    """确认品种库存在。缺了就不是本脚本能修的范围，给明确指令。"""
    lib = next((a for a in api.paged('/api/tenant/assets')
                if a.get('name') == '能源参数字典'), None)
    if lib:
        log('  ✓ 能源参数字典已存在')
        return True
    log('  ✗ 能源参数字典不存在 —— 品种/标准 key/档案全都没有来源')
    log('    请先跑一次「平台自检 → 一键修复初始化」（或 POST /api/energy/repair-init）')
    return False


def main():
    ap = argparse.ArgumentParser(
        description='RTU 演示环境一键初始化（幂等，包干到底）',
        epilog='空库：先 repair-init 建品种库，再跑本脚本；新客户：直接 --customer 新名字')
    ap.add_argument('--base', default='http://127.0.0.1:8090')
    ap.add_argument('--tenant', default='tenant@126.com')
    ap.add_argument('--tenant-pass', default='12345678')
    ap.add_argument('--customer', default=DEFAULT_CUSTOMER,
                    help='客户名（默认「%s」）；不存在会自动创建' % DEFAULT_CUSTOMER)
    ap.add_argument('--no-demo', action='store_true',
                    help='不调 demo-data 建维度（客户已有场站时用）')
    ap.add_argument('--dry-run', action='store_true', help='只打印计划，不写入')
    ap.add_argument('--prune', action='store_true', default=True,
                    help='删掉白名单以外的设备（默认开；--no-prune 关）')
    ap.add_argument('--no-prune', dest='prune', action='store_false')
    args = ap.parse_args()

    def log(msg):
        print(msg)

    customer_name = args.customer
    site_single_name, site_three_name = site_names(customer_name)

    api = Api(args.base, dry=args.dry_run)
    api.login(args.tenant, args.tenant_pass)
    log('登录成功: %s' % args.tenant)
    log('目标客户: %s' % customer_name)
    if args.dry_run:
        log('【dry-run】不会写入任何数据')

    # ① 品种库
    log('\n=== ① 品种库 ===')
    if not ensure_dictionary(api, log):
        return 1

    # ② 客户
    log('\n=== ② 客户 ===')
    try:
        cust, created = ensure_customer(api, customer_name, log)
    except Exception as e:
        log('  ✗ %s' % e)
        return 1
    if not created:
        log('  · 客户「%s」已存在' % customer_name)
    customer_id = cust['id']['id']
    cust_short = customer_id[:8] if 'dry' not in customer_id else 'dry'

    # ③ 维度（场站 / 分项 / 区域 / 楼栋）
    log('\n=== ③ 场站与维度 ===')
    if args.no_demo:
        log('  · 跳过 demo-data（--no-demo）')
    else:
        try:
            ensure_dimensions(api, customer_id, customer_name, log)
        except Exception as e:
            log('  ✗ 建维度失败: %s' % e)
            return 1

    site_single = find_site(api, site_single_name)
    site_three = find_site(api, site_three_name)
    for nm, s in ((site_single_name, site_single), (site_three_name, site_three)):
        log('  %s %s' % ('✓' if s else '✗', nm))
    if not site_single or not site_three:
        if api.dry:
            site_single = {'id': {'id': 'dry-site-1'}, 'name': site_single_name}
            site_three = {'id': {'id': 'dry-site-2'}, 'name': site_three_name}
        else:
            log('  ✗ 两个场站建不出来，后续无法继续')
            return 1

    # ③b 客户账号（让客户能登进来看）
    log('\n=== ③b 客户账号 ===')
    try:
        user_email, user_pass = ensure_customer_user(api, customer_id, customer_name, log)
    except Exception as e:
        log('  ⚠ %s' % e)
        user_email, user_pass = None, None

    # ④ 品种 id（按名字查，换库不失效）
    log('\n=== ④ 品种 ===')
    kinds = {}
    for a in api.paged('/api/tenant/assets'):
        code = next((k for k, v in KIND_NAMES.items() if v == a.get('name')), None)
        if code:
            kinds[code] = a['id']['id']
    log('  已识别品种: %s' % ', '.join(sorted(kinds)))
    if set(KIND_NAMES) - set(kinds):
        log('  ⚠ 缺品种资产: %s' % ', '.join(sorted(set(KIND_NAMES) - set(kinds))))

    # ⑤ 档案
    log('\n=== ⑤ 设备档案 ===')
    for nm, spec in PROFILES.items():
        try:
            ensure_profile(api, nm, spec, kinds, log)
        except Exception as e:
            log('  ✗ 档案「%s」: %s' % (nm, e))

    # ⑥ 网关
    log('\n=== ⑥ 网关 ===')
    gw_single_name, gw_three_name = gateway_names(customer_name)
    # ★ ED1-Gateway 是**真实板子**，全局只有一套，只属于主演示客户。
    #   非主客户跑脚本时必须跳过它 —— 否则会把它的场站改成这个客户的场站，
    #   主演示客户的真实设备就从这个场站里消失了（实测 2026-11-02）。
    if customer_name == DEFAULT_CUSTOMER:
        gw_single = ensure_gateway(api, gw_single_name, site_single, customer_id, log)
    else:
        gw_single = next((d for d in api.paged('/api/tenant/devices')
                          if d.get('name') == gw_single_name), None)
        if gw_single is None:
            if api.dry:
                gw_single = {'id': {'id': 'dry-gw-1'}}
            else:
                log('  ⚠ 真实网关 %s 不存在（主演示客户尚未初始化）' % gw_single_name)
                gw_single = {'id': {'id': 'no-gw'}}
    if gw_three_name == gw_single_name:
        gw_three = gw_single          # 同一台网关管两个场站
    else:
        gw_three = ensure_gateway(api, gw_three_name, site_three, customer_id, log)
    if not gw_single or not gw_three:
        log('✗ 网关创建失败')
        return 1
    sites = {'single': site_single, 'three': site_three}
    gws = {'single': gw_single, 'three': gw_three}

    # ⑦ 真实设备补场站 + RPC 能力（只在这个客户的场站下有意义）
    log('\n=== ⑦ 真实设备（RTU 实际接入）===')
    if customer_name != DEFAULT_CUSTOMER:
        log('  · 跳过：真实 RTU 设备只属于主演示客户「%s」' % DEFAULT_CUSTOMER)
        real_targets = []
    else:
        real_targets = ['PowerMeter-DDSU666', 'Sensor-HZ8706', 'Relay-8CH']
    for nm in real_targets:
        d = next((x for x in api.paged('/api/tenant/devices') if x.get('name') == nm), None)
        if d is None:
            log('  · %s 尚未接入（RTU 上电后会自动出现，届时重跑本脚本）' % nm)
            continue
        ai = d.get('additionalInfo') or {}
        if isinstance(ai, str):
            try:
                ai = json.loads(ai)
            except Exception:
                ai = {}
        ai['siteId'] = site_single['id']['id']
        # RTU 自动建的设备 customerId 是 NULL_UUID —— 必须用 owner 接口改成该客户，
        # 否则它不出现在客户设备列表里（看板按客户过滤时整台表消失）
        cur_owner = (d.get('customerId') or {}).get('id')
        if cur_owner != customer_id:
            assign_owner(api, 'DEVICE', d['id']['id'], customer_id, log)
        upd = {'id': d['id'], 'name': nm, 'label': d.get('label') or nm,
               'type': d.get('type'), 'additionalInfo': ai}
        upd['customerId'] = {'entityType': 'CUSTOMER', 'id': customer_id}
        api.post('/api/device', upd)
        log('  ✓ %s 场站 → %s' % (nm, site_single_name))
        api.call('POST', '/api/relation', {
            'from': {'entityType': 'DEVICE', 'id': gw_single['id']['id']},
            'to': {'entityType': 'DEVICE', 'id': d['id']['id']},
            'type': 'Contains', 'typeGroup': 'COMMON',
        })
        # meterLevel：真实表计是 RTU 上报时自动建的，没有这个属性；
        # 缺了资产汇总就取不到它（看板空）。2 = 分项/回路级
        real_attrs = {'meterLevel': 2 if nm == 'PowerMeter-DDSU666' else 0}
        rpc = RPC_SPECS.get(nm)
        if rpc:
            real_attrs['rpcCommands'] = rpc
            log('    + RPC 能力（%d 条命令）' % len(rpc['methods']))
        api.post('/api/plugins/telemetry/DEVICE/%s/SERVER_SCOPE' % d['id']['id'], real_attrs)

    # ⑧ 模拟设备
    log('\n=== ⑧ 模拟设备 ===')
    ok = 0
    for spec in SIM_DEVICES:
        try:
            named = dict(spec, name=sim_name(spec['name'], customer_name))
            if ensure_device(api, named, sites[spec['site']], customer_id,
                             gws[spec['gw']]['id']['id'], log):
                ok += 1
        except Exception as e:
            log('  ✗ %s: %s' % (spec['name'], e))

    # ⑨ 清理演示设备（保留资产）
    if args.prune:
        log('\n=== ⑨ 清理演示设备（保留场站/分项/区域资产）===')
        try:
            prune(api, log, args.dry_run, customer_id, customer_name)
        except Exception as e:
            log('  ✗ 清理失败: %s' % e)
    else:
        keep = keep_devices(customer_name)
        extra = [d.get('name') for d in api.paged('/api/tenant/devices')
                 if (d.get('customerId') or {}).get('id') == customer_id
                 and d.get('name') not in keep]
        if extra:
            log('\n⚠ 还有 %d 台非白名单设备（演示设备）。加 --prune 清掉。' % len(extra))

    # 完成
    log('\n=== 完成 ===')
    log('客户      : %s (%s)' % (customer_name, cust_short))
    if user_email:
        log('客户账号  : %s / %s' % (user_email, user_pass))
    log('场站      : %s / %s' % (site_single_name, site_three_name))
    log('模拟设备  : %d / %d' % (ok, len(SIM_DEVICES)))
    if args.dry_run:
        log('（dry-run 共计划写入 %d 次）' % api.writes)
    log('\n下一步：')
    log('  1) 给这个客户建账号并绑定（客户与用户 → 新建用户 → 客户选 %s）' % customer_name)
    log('  2) python3 scripts/31-rtu-simulate.py --customer "%s" --interval 30' % customer_name)
    return 0 if ok == len(SIM_DEVICES) else 1


if __name__ == '__main__':
    sys.exit(main())
