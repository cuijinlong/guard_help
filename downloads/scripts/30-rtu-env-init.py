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
import time
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
    '智能空开': ('elec', 'smart_breaker', 35, True,
              '带计量的智能断路器：分合闸、开关次数、有功功率与电量'),
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
        # ★ 没有 flicker_pinst（2026-11-02 删）：Pinst 是 IEC 61000-4-15 的内部
        #   中间量 S(t)，主流电表（PM8000 / PAC4200 / M4M / APView500）只输出
        #   Pst 与 Plt。挂 Pinst 等于让客户去找一个不存在的寄存器。
        mp('Pst', 'flicker_pst', '短时闪变 Pst', ''),
        mp('Plt', 'flicker_plt', '长时闪变 Plt', ''),
        # 中性线电流：三相四线表（N 线有 CT 时）能采
        mp('In', 'current_n', '中性线电流', 'A'),
    ]
    # 分次谐波：3/5/7/9/11/13 次（国标最关心的几次，全量 2~31 次在字典里）
    for h in (3, 5, 7, 9, 11, 13):
        pts.append(mp('H%du' % h, 'voltage_harmonic_%d' % h, '%d次电压谐波含有率' % h, '%'))
    for h in (3, 5, 7, 9, 11, 13):
        pts.append(mp('H%di' % h, 'current_harmonic_%d' % h, '%d次电流谐波含有率' % h, '%'))
    return pts


# ============ 模拟设备清单 ============
SIM_DEVICES = [
    {
        'name': 'PowerMeter-3P-SIM', 'label': '三相电表', 'meterLevel': 1, 'site': 'three', 'gw': 'three',
        'profile': '电能表', 'model': 'DTSD341', 'brand': '威胜',
        'type1': 'elec', 'type2': 'normal', 'l1': 'elec_meter',
        'wiring': '3P4W',
        'note': '模拟三相电表（3P4W）：电压电流潮流 + 电能质量全场景',
        'points': _pq_points(),
    },
    {
        'name': 'PowerMeter-1P-SIM', 'label': '单相电表', 'meterLevel': 2,
        'site': 'single', 'gw': 'single',
        'profile': '单相电能表', 'model': 'DDSU666', 'brand': '正泰',
        'type1': 'elec', 'type2': 'normal', 'l1': 'elec_meter',
        'wiring': '1P2W',
        'note': '模拟单相电表（1P2W）：真实 DDSU666 只报表底，'
                '这台保证单相园区有可展示的电量曲线',
        'points': [mp('U', 'voltage_a', 'A相电压', 'V'),
                   mp('I', 'current_a', 'A相电流', 'A'),
                   mp('P', 'power_total', '总有功功率', 'kW'),
                   mp('PF', 'power_factor_total', '总功率因数', ''),
                   mp('Freq', 'frequency', '频率F', 'Hz'),
                   mp('Ep', 'energy_reading', '累积读数', 'kW·h'),
                   mp('E', 'energy', '本周期用电量', 'kW·h'),
                   mp('Ud', 'voltage_deviation_a', 'A相电压偏差', '%'),
                   mp('THDu', 'voltage_thd_a', 'A相电压畸变率', '%'),
                   mp('THDi', 'current_thd_a', 'A相电流畸变率', '%')],
    },
    {
        'name': 'WaterMeter-SIM', 'label': '水表', 'meterLevel': 2, 'site': 'single', 'gw': 'single',
        'profile': '水表', 'model': 'LXSY-20', 'brand': '宁波水表',
        'type1': 'water', 'type2': 'normal', 'l1': 'water_meter',
        'wiring': '',
        'note': '模拟水表：瞬时流量 + 累积读数',
        'points': [mp('F', 'power', '瞬时流量', 'm³/h'),
                   mp('Q', 'energy_reading', '累积读数', 'm³'),
                   mp('T', 'temperature', '水温', '℃')],
    },
    {
        'name': 'GasMeter-SIM', 'label': '燃气表', 'meterLevel': 2, 'site': 'single', 'gw': 'single',
        'profile': '燃气表', 'model': 'G2.5', 'brand': '秦川',
        'type1': 'gas', 'type2': 'normal', 'l1': 'gas_meter',
        'wiring': '',
        'note': '模拟燃气表：瞬时流量 + 累积读数 + 压力',
        'points': [mp('F', 'power', '瞬时流量', 'm³/h'),
                   mp('Q', 'energy_reading', '累积读数', 'm³'),
                   mp('P', 'gas_pressure', '燃气压力', 'kPa')],
    },
    {
        'name': 'SteamMeter-SIM', 'label': '蒸汽表', 'meterLevel': 2, 'site': 'three', 'gw': 'three',
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
        'name': 'HeatMeter-SIM', 'label': '热力表', 'meterLevel': 2, 'site': 'three', 'gw': 'three',
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
        'name': 'AHU-SIM', 'label': '新风机组', 'meterLevel': 0, 'site': 'three', 'gw': 'three',
        'profile': '新风机组', 'model': 'ZK-30', 'brand': '盾安',
        'type1': 'env', 'type2': 'fresh_air_unit', 'l1': 'env_device',
        'wiring': '',
        'note': '模拟新风机组（可控）：送风温湿度、运行模式、风机频率',
        'points': [mp('Ts', 'temperature', '送风温度', '℃'),
                   mp('Hs', 'humidity', '送风湿度', '%RH'),
                   mp('Mode', 'run_mode', '运行模式', ''),
                   mp('P', 'power', '风机功率', 'kW'),
                   mp('Freq', 'frequency', '风机频率', 'Hz')],
    },
    {
        'name': 'Breaker-SIM', 'label': '智能空开', 'meterLevel': 2, 'site': 'three', 'gw': 'three',
        # ★ 档案不能写 'default'（2026-11-02 实测）：default 档案没有 energyTypeCode，
        #   汇总直接 continue 跳过 → 动力分项永远是空的，且不报错。
        'profile': '智能空开', 'model': 'TGB3-63', 'brand': '天正',
        'type1': 'elec', 'type2': 'smart_breaker', 'l1': 'smart_breaker',
        'wiring': '',
        'note': '模拟智能空开（可控且带计量）：分合闸、开关次数、有功功率与电量',
        # ★ 开关次数不能用 energy 键（2026-11-02 实测）：energy 是增量电量，
        #   动力分项曾把开关次数当电量累加成 31272 kW·h。次数走 switch_count。
        'points': [mp('State', 'switch_state', '分合闸状态', ''),
                   mp('Cnt', 'switch_count', '开关次数', ''),
                   mp('P', 'power', '有功功率', 'kW'),
                   mp('E', 'energy', '本周期用电量', 'kW·h'),
                   mp('Ep', 'energy_reading', '累积读数', 'kW·h'),
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

# ============================================================================
# RTU 下挂设备的三件套（2026-11-04 新增）
#
# <h3>为什么要有这份定义</h3>
# 原实现只对「主演示客户」处理真实 RTU 设备，而且**只查找不创建** ——
# 其它客户跑完初始化后，网关下什么都没有，客户登录只看到一堆 SIM 设备，
# 找不到「RTU 网关 + 正泰电表 + 温湿度 + 8路继电器」那套现场形态。
# 客户原话：「之前初始化数据是带真实 RTU 网关设备、下面挂着正泰单相电表、
# 温湿度传感器、8路继电器的，现在都没有了」。
#
# <h3>命名规则</h3>
#   · 主演示客户「平台演示中心」用**无后缀**的真实名 —— 板子 main.py 里写死，
#     改不了；真实 RTU 上报时 TB 按 name 匹配，名字必须逐字一致。
#   · 其它客户用 `名·客户名` —— 与 demo-data / SIM 设备同一套后缀规则。
#     同一租户下设备唯一键是 (tenant_id, name)，不带后缀会撞主客户那台，
#     而且 TB 不允许改 owner，最后两个客户互相污染（2026-11-02 实测）。
#
# <h3>为什么 meterLevel = 0</h3>
# 演示数据（单相园 / 三相园）的账单与「层级守恒」断言按 meterLevel 分层算。
# 给 1/2 级会让它进入场站汇总，演示数字莫名其妙地变。
# level=0 的语义是「不计入汇总」，但它仍是 isMeter=true 的表计：
# 设备管理能看、实时数据能看、一键抄表能抄、台账能出账。
RTU_ATTACHED = [
    {
        'base': 'PowerMeter-DDSU666', 'label': '正泰单相电表 DDSU666',
        'profile': '单相电能表', 'meterLevel': 0,
        'type1': 'elec', 'type2': 'normal', 'l1': 'elec_meter',
        'model': 'DDSU666', 'brand': '正泰', 'wiring': '1P2W',
        'points': [mp('U', 'voltage_a', 'A相电压', 'V'),
                   mp('I', 'current_a', 'A相电流', 'A'),
                   mp('P', 'power_total', '总有功功率', 'kW'),
                   mp('PF', 'power_factor_total', '总功率因数', ''),
                   mp('Freq', 'frequency', '频率F', 'Hz'),
                   mp('Ep', 'energy_reading', '累积读数', 'kW·h')],
    },
    {
        'base': 'Sensor-HZ8706', 'label': '温湿度传感器',
        'profile': '温湿度变送器', 'meterLevel': 0,
        'type1': 'env', 'type2': 'normal', 'l1': 'th_sensor',
        'model': 'HZ8706', 'brand': '华控', 'wiring': '',
        'points': [mp('T', 'temperature', '温度', '℃'),
                   mp('H', 'humidity', '湿度', '%')],
    },
    {
        # 8 路继电器没有专用档案，落 default（与 21-rtu-onboard.py 一致）
        'base': 'Relay-8CH', 'label': '8路继电器',
        'profile': 'default', 'meterLevel': 0,
        # ★ type1 不能写 'elec'（2026-11-04）：看板部件的 energyOf() 先看
        #   additionalInfo.energyTypeCode，命中 TYPE1_OF 就当成计量表。
        #   继电器是执行器，混进计量池会让「当前 N 台计量点」多算一台、
        #   而它永远没有电量，客户会怀疑数据不准。
        #   'ctrl' 不在品种白名单里 → 被正确跳过。
        'type1': 'ctrl', 'type2': 'normal', 'l1': 'relay',
        'model': '8CH', 'brand': '通用', 'wiring': '',
        'points': [],
    },
]


def rtu_attached_name(base, customer):
    """RTU 下挂设备名：主演示客户用真名（板子写死），其余带客户后缀。"""
    if customer == DEFAULT_CUSTOMER:
        return base
    return sim_name(base, customer)


def keep_devices(customer):
    """本客户下不允许被 prune 删掉的设备名。"""
    names = {'ED1-Gateway'} | REAL_DEVICES
    names |= set(gateway_names(customer))
    names |= {sim_name(d['name'], customer) for d in SIM_DEVICES}
    # RTU 下挂三件套（带后缀形态）
    names |= {rtu_attached_name(d['base'], customer) for d in RTU_ATTACHED}
    return names


def is_demo_device(dev):
    """demo-data（/api/energy/demo-data）建的演示设备。

    <p>★ 这些设备必须免于 prune（2026-11-04 客户报的 bug）：
    开户脚本 09-onboard-customer.sh 会调 demo-data 建 31 台覆盖
    「单相园 / 三相园 / A栋锅炉」的演示设备，它们与 RTU 那套是**互补**的
    两部分 —— 一个演示现场总线，一个演示分项/区域/多品种。
    原 prune 白名单只认 SIM 与真实 RTU 名，于是跑一次初始化就把这 31 台
    全删了，客户看到「模拟的三相电和各类设备类型的设备都没了」。

    <p>判据用 additionalInfo.demo，与后端 EnergyBootstrapInstaller 写的一致。
    """
    ai = dev.get('additionalInfo') or {}
    if isinstance(ai, str):
        try:
            ai = json.loads(ai)
        except Exception:
            ai = {}
    return ai.get('demo') is True


# ============ RPC 能力（写进设备属性，供界面/脚本查）============
RPC_SPECS = {
    # ── 电能质量采集会话（平台侧约定，2026-11-03）────────────────────
    #
    # ★ 这是**平台与 RTU 之间的约定命令**，不是任何国标规定的东西。
    #   固件必须先实现它们，否则平台下发后没人执行。
    #   平台侧的防御：下发前先读这份 rpcCommands，找不到命令就拒绝创建数据集，
    #   不会盲发一个固件不认识的名字然后静默超时（那种故障两边日志都对，查不出来）。
    #
    # pqRole 是解析依据：现场叫什么名字都行（beginCapture 也可以），
    # 只要标了 pqRole=start / stop，平台就认。
    'PowerMeter-DDSU666': {
        'note': '正泰单相电表（经 RTU 转发）。startPqSession/stopPqSession 为平台约定命令，需固件实现',
        'methods': [
            {'method': 'startPqSession', 'pqRole': 'start',
             'params': {'datasetId': 'uuid', 'plannedSeconds': 'int',
                        'intervalMs': 'int', 'build': 'object', 'standards': 'array'},
             'desc': '按国标节拍启动 PQ 采集（平台约定；固件需实现）'},
            {'method': 'stopPqSession', 'pqRole': 'stop',
             'params': {'datasetId': 'uuid'},
             'desc': '停止 PQ 采集（平台约定；固件需实现）'},
        ],
    },
    'PowerMeter-3P-SIM': {
        'note': '三相模拟表。声明采集命令仅用于验证平台下发链路；模拟器本身不执行 RPC',
        'methods': [
            {'method': 'startPqSession', 'pqRole': 'start',
             'params': {'datasetId': 'uuid', 'plannedSeconds': 'int', 'intervalMs': 'int'},
             'desc': '启动 PQ 采集（模拟表不真执行，仅验证平台能否下发）'},
            {'method': 'stopPqSession', 'pqRole': 'stop',
             'params': {'datasetId': 'uuid'}, 'desc': '停止 PQ 采集'},
        ],
    },
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


# ---------------------------------------------------------------- 设备归属
# ★ 看板判「设备属于哪个场站」读的是**关系**，不是 additionalInfo.siteId。
#   2026-11-02 实测：场站下只连了 3 台网关，综合能耗看板一个计量点都取不到，
#   界面只显示「当前筛选下没有可用计量点」，无任何报错。
#   场站 → 设备走干净的 SiteContains；区域/分项 → 设备走标准 Contains。
MEMBERSHIP = {
    # 设备基名（去掉 ·客户名 后缀）: (区域名前缀, 分项名前缀)
    # 总表（meterLevel=1）只挂场站、不挂分项 —— 否则分项能耗会重复计电
    'PowerMeter-1P-SIM': ('公共区域', '照明'),
    'PowerMeter-3P-SIM': ('生产车间', None),
    'PowerMeter-DDSU666': ('公共区域', '插座'),
    'WaterMeter-SIM': ('公共区域', '给排水'),
    'GasMeter-SIM': ('食堂', '炊事'),
    'SteamMeter-SIM': ('锅炉房', '蒸汽'),
    'HeatMeter-SIM': ('锅炉房', '锅炉'),
    'Breaker-SIM': ('生产车间', '动力'),
    'Relay-8CH': ('A栋办公区', None),
    'AHU-SIM': ('办公区', None),
    'Sensor-HZ8706': ('公共区域', None),
    'ED1-Gateway': ('公共区域', None),
    'ED2-Gateway': ('生产车间', None),
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

    def call(self, method, path, body=None, auth=True, timeout=90):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method)
        if auth and self.token:
            req.add_header('X-Authorization', 'Bearer ' + self.token)
        if data:
            req.add_header('Content-Type', 'application/json')
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
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
        except (TimeoutError, urllib.error.URLError, ConnectionError, OSError) as e:
            '''
            传输层失败返回 0，不抛异常。

            ★ 为什么（2026-11-02 干净库实测）：新建客户会**触发后端异步跑一整套
              演示数据初始化**（2 场站 / 12 分项 / 21 设备 + 一批遥测），
              期间 Tomcat 线程被占满，紧接着的查询排队超时（报 `timed out`）。
              旧代码只捕 HTTPError，超时会直接往上抛，于是「客户建成功了脚本却报失败」
              —— 干净环境首次部署必现。
            0 是传输层信号，调用方（paged / ensure_customer）据此重试。
            '''
            return 0, '%s: %s' % (type(e).__name__, e)

    def get(self, path):
        return self.call('GET', path)[1]

    def post(self, path, body, timeout=90):
        """发 POST；dry-run 不写库。

        <p>★ timeout 必须可调（2026-11-02 干净库实测）：`POST /api/customer` 在后端是
        **同步**跑完整套演示数据初始化的（4 个维度根 / 2 个场站 /
        12 个分项 / 21 台设备 / 一批遥测 + 费率），实测 60~120s。
        90s 不够 → 客户已经建好了脚本却报 `timed out`，
        干净环境首次部署必翻车。默认值不动，只有客户创建这类
        重请求单独放宽。
        """
        if self.dry:
            self.writes += 1
            return 200, {}   # dry-run: 不写库
        code, r = self.call('POST', path, body, timeout=timeout)
        if code not in (200, 201, 204):
            raise RuntimeError('POST %s → %s %s' % (path, code, r))
        return code, r

    def paged(self, path, retries=3, retry_wait=4):
        """翻页取全部。传输层失败（相对 0）会重试 —— 后端初始化期间会短暂排队。"""
        out, page = [], 0
        while True:
            sep = '&' if '?' in path else '?'
            url = '%s%spageSize=500&page=%d' % (path, sep, page)
            d = None
            for attempt in range(retries + 1):
                code, resp = self.call('GET', url, timeout=120)
                if code != 0:
                    d = resp
                    break
                if attempt < retries:
                    time.sleep(retry_wait)
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


def _device_base_name(name):
    """PowerMeter-1P-SIM·平台演示中心 → PowerMeter-1P-SIM"""
    return (name or '').split('·')[0]


def _existing_relations(api, cache, entity_type, entity_id):
    key = (entity_type, entity_id)
    if key not in cache:
        cache[key] = api.get(
            '/api/relations?fromId=%s&fromType=%s&relationTypeGroup=COMMON'
            % (entity_id, entity_type)) or []
    return cache[key]


def ensure_relation(api, cache, from_type, from_id, to_type, to_id, rel_type):
    """幂等建关系：已存在返回 False，新建返回 True。"""
    rels = _existing_relations(api, cache, from_type, from_id)
    for r in rels:
        t = r.get('to') or {}
        if (r.get('type') == rel_type and t.get('entityType') == to_type
                and t.get('id') == to_id):
            return False
    api.post('/api/relation', {
        'from': {'entityType': from_type, 'id': from_id},
        'to': {'entityType': to_type, 'id': to_id},
        'type': rel_type, 'typeGroup': 'COMMON',
    })
    rels.append({'type': rel_type,
                 'to': {'entityType': to_type, 'id': to_id}})
    return True


def _drop_relation(api, from_type, from_id, to_type, to_id, rel_type):
    """删单条关系（TB 用 DELETE /api/relation + 查询参数，没有 body）。"""
    path = ('/api/relation?fromId=%s&fromType=%s&relationType=%s'
            '&toId=%s&toType=%s&relationTypeGroup=COMMON'
            % (from_id, from_type, rel_type, to_id, to_type))
    code, _ = api.call('DELETE', path)
    return code in (200, 204)


def relink_devices(api, log, customer_id, customer_name, dry):
    """把设备挂到它 additionalInfo.siteId 指向的场站，并按 MEMBERSHIP 补
    区域/分项归属，同时清掉不属于当前映射的旧边。**可重复执行**。

    这一步是综合能耗 / 分项能耗 / 区域能耗三个看板能出数的前提：
    部件用 collectDevices() 沿 Contains|SiteContains 递归找设备，
    关系没有 = 场站下 0 台表，界面只说「当前筛选下没有可用计量点」。
    """
    assets = [a for a in api.paged('/api/tenant/assets')
              if (a.get('customerId') or {}).get('id') == customer_id]
    by_id = {a['id']['id']: a for a in assets}
    buckets = {}
    for a in assets:
        head = (a.get('name') or '').split('·')[0]
        buckets.setdefault((a.get('type'), head), []).append(a)

    devices = [d for d in api.paged('/api/tenant/devices')
               if (d.get('customerId') or {}).get('id') == customer_id]
    cache = {}
    kids_cache = {}
    stat = {'site': 0, 'region': 0, 'item': 0, 'pruned': 0, 'skip': 0}

    # 区域/分项 → 设备 的现有边，一次收齐（设备 id → [(资产, 关系类型)]）。
    # 逐台设备反查要把每个资产的关系都拉一遍，这里按资产拉、按设备归集，请求数一样但能复用缓存。
    incoming = {}
    for (kind, _head), group in buckets.items():
        if kind not in ('区域', '分项'):
            continue
        for asset in group:
            for r in _existing_relations(api, cache, 'ASSET', asset['id']['id']):
                to = r.get('to') or {}
                if to.get('entityType') != 'DEVICE' or not to.get('id'):
                    continue
                incoming.setdefault(to['id'], []).append((asset, r.get('type')))

    for d in devices:
        ai = d.get('additionalInfo') or {}
        if isinstance(ai, str):
            try:
                ai = json.loads(ai)
            except Exception:
                ai = {}
        sid = ai.get('siteId')
        site = by_id.get(sid)
        if not site or site.get('type') != '场站':
            stat['skip'] += 1
            continue
        did = d['id']['id']

        if ensure_relation(api, cache, 'ASSET', sid, 'DEVICE', did, 'SiteContains'):
            stat['site'] += 1

        # 同名区域/分项在别的园区也有，只认本场站下面的那个
        if sid not in kids_cache:
            kids_cache[sid] = {r['to']['id']
                               for r in _existing_relations(api, cache, 'ASSET', sid)
                               if (r.get('to') or {}).get('entityType') == 'ASSET'}
        kids = kids_cache[sid]

        base = _device_base_name(d['name'])
        spec = MEMBERSHIP.get(base) or (None, None)
        wanted = set()
        for kind, head in (('区域', spec[0]), ('分项', spec[1])):
            if not head:
                continue
            cands = buckets.get((kind, head + kind), [])
            inside = [x for x in cands if x['id']['id'] in kids]
            pick = (inside or cands)
            if not pick:
                log('  · %s 找不到%s「%s」，跳过' % (d['name'], kind, head))
                continue
            wanted.add(pick[0]['id']['id'])
            if ensure_relation(api, cache, 'ASSET', pick[0]['id']['id'],
                               'DEVICE', did, 'Contains'):
                log('  + %s → %s' % (d['name'], pick[0]['name']))
                stat['region' if kind == '区域' else 'item'] += 1

        # 清掉不是当前映射的旧边。
        #
        # ★ 为什么要删（2026-11-02 实测）：历史演示数据给同一台表挂过两个区域
        #   （燃气表同时在「公共区域」和「食堂」），区域能耗会把它算两遍。
        #   只补不删就会永远带着这些脏边。
        #   只动「区域/分项 → 设备」，不碰楼栋 / 能耗类型 / 网关下的 Contains。
        if base in MEMBERSHIP:
            for asset, rel_type in incoming.get(did, []):
                if rel_type != 'Contains' or asset['id']['id'] in wanted:
                    continue
                if dry:
                    log('  - %s 将解除「%s」' % (d['name'], asset['name']))
                    stat['pruned'] += 1
                elif _drop_relation(api, 'ASSET', asset['id']['id'],
                                    'DEVICE', did, 'Contains'):
                    log('  - %s 解除多余的「%s」' % (d['name'], asset['name']))
                    stat['pruned'] += 1

    log('  场站归属 +%d / 区域 +%d / 分项 +%d / 清理旧边 %d（%d 台无场站，已跳过）'
        % (stat['site'], stat['region'], stat['item'], stat['pruned'], stat['skip']))
    return stat


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
            'name': name, 'label': '数据网关', 'type': '网关',
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
        upd = {'id': dev['id'], 'name': name, 'label': '数据网关', 'type': '网关',
               'additionalInfo': ai}
        if dev.get('customerId'):
            upd['customerId'] = dev['customerId']
        api.post('/api/device', upd)
    return dev


def ensure_device(api, spec, site, customer_id, gw_id, log):
    name = spec['name']
    dev = next((d for d in api.paged('/api/tenant/devices') if d.get('name') == name), None)
    # ★ 不要写 deviceVirtual（除非真的是虚拟表）。
    #
    #   看板部件的 isVirtual 是**黑名单式**判断：只要这个键存在且非空
    #   （除了 false/'false'/0/'0'）就算虚拟设备，直接从计量池里剔除。
    #   曾经写 'real' 想表达「这是实表」，结果 8 台模拟设备全被判虚拟，
    #   场站看板一直是「当前范围内没有可用计量点」（实测 2026-11-02）。
    #
    #   energyTypeCode 必须写：部件优先用它判品种，
    #   否则只能靠档案名查 ENERGY_OF_TYPE 白名单 —— 新建的档案名不在表里，
    #   设备就会被当作「识别不出品种」剔除。
    ai = {'siteId': site['id']['id'], 'simulated': True,
          'energyTypeCode': spec['type1']}

    if dev is None:
        api.post('/api/device', {
            'name': name, 'label': spec.get('label') or name, 'type': spec['profile'],
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
        upd = {'id': dev['id'], 'name': name,
               'label': spec.get('label') or name, 'type': spec['profile'],
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

    # ★ 用**基名**查 RPC_SPECS（2026-11-03 修）：
    #   模拟设备的 name 是 'PowerMeter-3P-SIM·平台演示中心'（带客户名后缀），
    #   而 RPC_SPECS 的键是基名 'PowerMeter-3P-SIM'。
    #   原来直接 RPC_SPECS.get(name) 永远落空 ——
    #   实测确认：8 台模拟设备的 rpcCommands 属性全为「无」，
    #   连 AHU-SIM 的 setMode、Breaker-SIM 的 setState 也从没生效过。
    #   界面不报错，只是点了没反应，最难查。
    rpc = RPC_SPECS.get(_device_base_name(name)) or RPC_SPECS.get(name)
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
        if is_demo_device(d):
            # demo-data 建的演示设备（单相园/三相园/锅炉…）保留 —— 见 is_demo_device
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

def wait_customer_ready(api, customer_id, log, max_wait=240):
    """等后端把「新建客户」触发的异步演示数据落完。

    <p>★ 为什么必须等（2026-11-02 干净库实测，首次部署必现）：

    TB 在客户创建后会**自动**跑 createDimensionRoots + createDemoPackage ——
    2 个场站 / 12 个分项 / 21 台设备 / 一批 built-in 遥测。这段时间里 Tomcat
    线程被占满，紧接着的任何查询都会排队超时，脚本报 `timed out`，
    但客户其实已经建成功了 —— 于是后面所有步骤全部中断，而调用方
    还可能以为「跑完了」。

    <p>判据：客户名下资产数**连续两次采样不变**。没有资产的客户视为已就绪。
    """
    last, stable, waited = -1, 0, 0
    while waited < max_wait:
        code, d = api.call('GET', '/api/customer/%s/assets?pageSize=1&page=0' % customer_id,
                           timeout=120)
        total = d.get('totalElements') if isinstance(d, dict) else None
        if total is not None:
            if total == last:
                stable += 1
                if stable >= 2:
                    log('  ✓ 后端初始化已完成（%s 个资产）' % total)
                    return total
            else:
                stable = 0
                last = total
        time.sleep(4)
        waited += 4
    log('  ! 等后端初始化超时（%ss，停在 %s 个资产），继续执行' % (max_wait, last))
    return last


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
    # ★ 长超时：客户创建会同步跑整套演示数据初始化（60~120s），
    #   90s 默认值下客户已建好、脚本却报超时。
    api.post('/api/customer', {'title': name, 'country': 'CN'}, timeout=600)
    # 建完立刻查会撞上后端异步初始化（见 wait_customer_ready 的说明）
    for c in api.paged('/api/customers'):
        if c.get('title') == name:
            log('  + 客户「%s」已建' % name)
            wait_customer_ready(api, c['id']['id'], log)
            return c, True
    raise RuntimeError('客户「%s」创建后仍查不到（后端可能仍在初始化，稍后重跑即可）' % name)


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

    <p>**返回值语义**：`(email, password)`。`password` 为 `None` 表示
    「这个账号的密码不是我们设的默认值」（已存在且改过密码、或建失败），
    调用方**不得**把默认密码报给用户。
    """
    email = 'demo+%s@126.com' % customer_id.replace('-', '')[:8]

    # 已存在就只确认能登录，不重复建
    existing = None
    code, d = api.call('GET', '/api/customer/%s/users?pageSize=100&page=0' % customer_id)
    if isinstance(d, dict):
        existing = next((u for u in (d.get('data') or []) if u.get('email') == email), None)
    if existing is not None:
        log('  · 账号 %s 已存在，不重建' % email)
        # 实测密码能不能用，而不是假设它就是默认值。
        #
        # 旧写法直接 `return email, password`，于是结尾永远打印
        # 「客户账号: xxx / demo123456」—— 客户改过密码后，这条提示
        # 就是错的，人会去试一个登不进去的密码（2026-11-03 客户提问暴露）。
        #
        # 现在拿默认密码登一次：
        #   登得进 → 密码确实是默认值，可以照实报
        #   登不进 → 密码被改过或账号被禁用，不能再报默认值
        if api.dry:
            log('    （dry-run 不验证密码）')
            return email, None
        code, _ = api.call('POST', '/api/auth/login',
                           {'username': email, 'password': password}, auth=False)
        if code == 200:
            log('    ✓ 默认密码可用')
            return email, password
        log('    ! 默认密码登不进去（客户可能改过密码，或账号被禁用）')
        return email, None

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
    # ★ 维度已存在就**不要再调 demo-data**（2026-11-02 实测）：
    #   它不只建资产，还会把客户设备重新挂回「默认区域」（单相→公共区域、
    #   三相→生产车间），把本脚本 ⑩ 步建的正确区域边冲掉 ——
    #   于是每次重跑都变成「+5 正确边 / -5 旧边」，日志永远不收敛。
    want_root = '用能分项·%s' % customer_name
    if any(a.get('name') == want_root for a in api.paged('/api/tenant/assets')):
        log('  · 维度根已存在（%s），跳过 demo-data，避免设备区域被重置' % want_root)
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
    # ★ 每个客户都要有自己的网关（2026-11-04 修）。
    #
    #   原实现在「非主演示客户」分支里**只查找不创建**，查不到就把 id 塞成
    #   字符串 'no-gw' 继续往下跑。后果：
    #     ① 客户名下永远没有网关设备，客户看到「网关没了」；
    #     ② 第⑧步用它建 Contains 关系时 UUID 非法、静默失败，
    #        8 台 SIM 设备全部成了孤儿（实测：0 条 DEVICE→DEVICE 关系）。
    #
    #   非主客户用的名字是 ED2-Gateway·客户名（gateway_names 已保证），
    #   不会与真实板子的 ED1-Gateway 相撞，所以可以直接建。
    gw_single = ensure_gateway(api, gw_single_name, site_single, customer_id, log)
    if gw_three_name == gw_single_name:
        gw_three = gw_single          # 同一台网关管两个场站
    else:
        gw_three = ensure_gateway(api, gw_three_name, site_three, customer_id, log)
    if not gw_single or not gw_three:
        log('✗ 网关创建失败')
        return 1
    sites = {'single': site_single, 'three': site_three}
    gws = {'single': gw_single, 'three': gw_three}

    # ⑦ RTU 下挂设备（网关 → 正泰电表 / 温湿度 / 8 路继电器）
    #
    # ★ 2026-11-04 重写。原实现只对主演示客户「处理」真实设备，而且
    #   **只查找不创建** —— 其它客户的网关下永远是空的；
    #   即便是主客户，RTU 没上电时那三台也不存在，演示数据不完整。
    #
    #   现在改成：每个客户都保证这三台存在并挂在网关上。
    #   主客户用真实名（板子写死），其余带客户后缀（互不冲突）。
    log('\n=== ⑦ RTU 下挂设备（正泰电表 / 温湿度 / 8路继电器）===')
    # 真实设备也要有**人话 label**（2026-11-02 客户要求）：
    #   设备技术名只用于唯一性与匹配，界面上一律显示 label。
    for spec in RTU_ATTACHED:
        nm = rtu_attached_name(spec['base'], customer_name)
        try:
            named = dict(spec, name=nm)
            # 真实 RTU 设备由网关转发上报，meterLevel 走 0（不进汇总）
            dev = ensure_device(api, named, site_single, customer_id,
                                gw_single['id']['id'], log)
            if dev is None:
                log('  ✗ %s 创建失败' % nm)
                continue
            # RTU 自动建的设备 customerId 是 NULL_UUID —— 必须用 owner 接口改成该客户，
            # 否则它不出现在客户设备列表里（看板按客户过滤时整台表消失）
            cur_owner = (dev.get('customerId') or {}).get('id')
            if cur_owner and cur_owner != customer_id:
                assign_owner(api, 'DEVICE', dev['id']['id'], customer_id, log)
            if spec['base'] in RPC_SPECS:
                api.post('/api/plugins/telemetry/DEVICE/%s/SERVER_SCOPE' % dev['id']['id'],
                         {'rpcCommands': RPC_SPECS[spec['base']]})
                log('    + RPC 能力（%d 条命令）' % len(RPC_SPECS[spec['base']]['methods']))
        except Exception as e:
            log('  ✗ %s: %s' % (nm, e))

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

    # ⑩ 设备归属关系（场站 / 区域 / 分项）
    # ★ 看板判归属读关系，不读 additionalInfo.siteId —— 缺这步综合能耗恒为空。
    #   每次跑都执行（幂等），存量环境重跑本脚本即可修好。
    log('\n=== ⑩ 设备归属关系（场站 / 区域 / 分项）===')
    try:
        relink_devices(api, log, customer_id, customer_name, args.dry_run)
    except Exception as e:
        log('  ✗ 归属补建失败: %s' % e)

    # 完成
    log('\n=== 完成 ===')
    log('客户      : %s (%s)' % (customer_name, cust_short))
    if user_email:
        if user_pass:
            log('客户账号  : %s / %s' % (user_email, user_pass))
        else:
            # 密码不是我们设的默认值（改过 / 被禁 / 建失败）—— 不能报一个错的
            log('客户账号  : %s' % user_email)
            log('            密码沿用原值（本脚本没改）；忘了就去「客户与用户 → 用户」重置')
    log('场站      : %s / %s' % (site_single_name, site_three_name))
    log('模拟设备  : %d / %d' % (ok, len(SIM_DEVICES)))
    if args.dry_run:
        log('（dry-run 共计划写入 %d 次）' % api.writes)
    log('\n下一步：')
    if not user_email:
        log('  1) 给这个客户建账号并绑定（客户与用户 → 新建用户 → 客户选 %s）' % customer_name)
    log('  %s) 启动模拟上报（长期运行）：' % ('2' if not user_email else '1'))
    log('     nohup bash scripts/29-rtu-demo-up.sh --sim-only --customer "%s" \\' % customer_name)
    log('       > /tmp/rtu-sim.log 2>&1 &')
    log('  %s) 看谁在报、谁停了：' % ('3' if not user_email else '2'))
    log('     bash scripts/29-rtu-demo-up.sh --status --customer "%s"' % customer_name)
    return 0 if ok == len(SIM_DEVICES) else 1


if __name__ == '__main__':
    sys.exit(main())
