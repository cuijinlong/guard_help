# RTU 演示环境（双网关 · 全品种 · 电能质量）

> 演示现场只有一块 RTU（一台真实单相电表 + 一个温湿度 + 一路继电器），
> 但客户想看的是**整套系统**：三相电能质量、水、燃气、蒸汽、热力、可控设备。
> 这一页给你一套**可重复执行**的脚本，装完新电脑一键就能把演示环境准备好。
>
> **不碰 Java 代码** —— 全部走 REST，改一行重跑几秒。改 Java 要重新打包 + 重启，
> 一次 10 分钟起步，演示前一天晚上改错一行就完蛋了。

---

## 一、两个脚本

都在 `scripts/` 下，与平台部署脚本同目录。

| 脚本 | 干什么 | 什么时候跑 |
| --- | --- | --- |
| `30-rtu-env-init.py` | 建网关、设备档案、模拟设备、测点快照、RPC 能力 | 新电脑部署后跑**一次** |
| `31-rtu-simulate.py` | 给模拟设备持续产生新鲜数据 | 演示期间一直跑着 |

```bash
cd <部署目录>

# ① 一键初始化（幂等，反复跑无害）
python3 scripts/30-rtu-env-init.py --prune

# ② 持续模拟上报（Ctrl-C 停）
python3 scripts/31-rtu-simulate.py --interval 30
```

`--prune` 会删掉白名单以外的设备。**演示环境建议始终带上**，原因见第五节。

---

## 二、建出来的拓扑

```
单相园区·平台演示中心
└─ ED1-Gateway          真实 RTU（HaaS506-ED1 板子）
   ├─ PowerMeter-DDSU666   单相电表（正泰 DDSU666）
   ├─ Sensor-HZ8706        温湿度传感器
   └─ Relay-8CH            8 路继电器        ← 可控设备

三相园区·平台演示中心
└─ ED2-Gateway          模拟（脚本发数据）
   ├─ PowerMeter-3P-SIM    三相电表 3P4W     ← 电能质量全场景（49 个测点）
   ├─ WaterMeter-SIM       水表
   ├─ GasMeter-SIM         燃气表
   ├─ SteamMeter-SIM       蒸汽表
   ├─ HeatMeter-SIM        热力表
   ├─ AHU-SIM              新风机组          ← 可控设备
   └─ Breaker-SIM          智能空开          ← 可控设备
```

**真实设备与模拟设备分属两个网关、两个场站** —— 客户看到的两个园区都有数据，
而不是「一个满一个空」。

> 一块 RTU 板子只能当一个网关（`main.py` 里的 `GATEWAY_NAME` 写死一个）。
> 第二个网关的模拟数据由 `31-rtu-simulate.py` 在服务器侧发出，不需要第二块板子。

---

## 三、电能质量覆盖了什么

三相模拟表（`PowerMeter-3P-SIM`）的 49 个测点按国标参数布局：

| 场景 | 遥测键 | 国标限值 | 脚本生成范围 |
| --- | --- | --- | --- |
| 三相电压趋势 | `voltage_a/b/c`、`voltage_avg` | 220V ±7%（204.6~235.4） | 218~229 V |
| 电压偏差 | `voltage_deviation_a/b/c` | ±7% | −3%~+4% |
| 频率偏差 | `frequency`、`frequency_deviation` | 50 ± 0.2 Hz | 49.95~50.05 |
| 三相不平衡 | `voltage_unbalance`、`current_unbalance` | ≤ 2% | ≤ 1.2% |
| 序分量 | `voltage_seq_positive/negative/zero`、`current_seq_*` | —— | 负序 ≈ 不平衡×0.6 |
| 谐波畸变 | `voltage_thd_a/b/c`、`current_thd_a/b/c` | 电压 ≤ 5% | 1.2~3.8% |
| 分次谐波 | `voltage_harmonic_3/5/7/9/11/13`、`current_harmonic_*` | 国标分次限值 | 按次数递减 |
| 电压闪变 | `flicker_pinst`、`flicker_pst`、`flicker_plt` | Pst ≤ 1.0，Plt ≤ 0.8 | 0.15~0.95 |

**全部按国标范围内的合理值生成**，不是随机乱数 —— 电能质量看板的越限判定
（超阈值标红）不会被无意义的假数据误触发。

---

## 四、远程控制（RPC）命令

可控设备在平台上有 `rpcCommands` 属性，记着它能接受哪些指令。
真实设备由 RTU 执行，模拟设备由脚本记录（不改变实际状态）。

### Relay-8CH（真实，8 路继电器）

| 方法 | 参数 | 说明 |
| --- | --- | --- |
| `setRelay` | `{"ch": 1..8, "state": true/false}` | 单路开关 |
| `setGroupRelay` | `{"chs": [1,2,3], "state": true/false}` | 多路同开同关 |
| `setAllRelay` | `{"state": true/false}` | 全部开关 |
| `readMeterNow` | `{}` | 立即抄表（触发一次采集并上报） |

### AHU-SIM（模拟，新风机组）

| 方法 | 参数 | 说明 |
| --- | --- | --- |
| `setMode` | `{"mode": "auto/manual/off"}` | 运行模式 |
| `setFanSpeed` | `{"freq": 0..50}` | 风机频率 Hz |

### Breaker-SIM（模拟，智能空开）

| 方法 | 参数 | 说明 |
| --- | --- | --- |
| `setState` | `{"state": true/false}` | 合闸 / 分闸 |
| `getState` | `{}` | 读当前状态 |

### 怎么从平台下发

设备详情页 → **RPC** 面板 → 选方法、填参数。或命令行：

```bash
TOKEN=<租户管理员 token>
DEVICE=<设备 id>

curl -X POST "http://127.0.0.1:8090/api/rpc/oneway/$DEVICE" \
  -H "X-Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"method":"setRelay","params":{"ch":1,"state":true},"timeout":10000}'
```

要同步拿回复用 `/api/rpc/twoway/$DEVICE`（`setRelay` / `getState` 有返回值）。

> **真实继电器的前提**：板上 `main.py` 的 `ENABLE_RELAY = True`，且 RS485 接好。
> 命令走 `v1/gateway/rpc` 到板子，由 `dispatch_rpc` 执行。

---

## 五、`repair-init` 会重建演示设备（务必知道）

`POST /api/energy/repair-init` 里的 `repairHvacModule` 会**无条件**为每个客户
重建 10 台空调/环境演示设备（A栋新风机组、锅炉、热水泵、室内环境…）。

对刚装好、要初始化字典的库这是好事；但对 RTU 演示环境是噪音 ——
客户看到一堆没有数据源的设备，会以为系统坏了。

**所以：演示前跑过一次 `--prune` 清掉它们；之后不要再点「一键修复初始化」。**

如果误点了，重跑即可：

```bash
python3 scripts/30-rtu-env-init.py --prune
```

---

## 六、验证数据真的在动

```bash
# 每台设备最近的写入时间与键数
docker exec energy-postgres psql -U postgres -d thingsboard -c "
SELECT d.name, count(*) AS keys,
       to_char(to_timestamp(max(kv.ts)/1000),'HH24:MI:SS') AS last
FROM ts_kv kv JOIN device d ON d.id=kv.entity_id
WHERE d.name LIKE '%-SIM' GROUP BY d.name ORDER BY d.name;"
```

好的输出长这样（键数固定，时间一直在走）：

```
 AHU-SIM            |    8 | 15:42:45
 Breaker-SIM        |    6 | 15:42:45
 PowerMeter-3P-SIM  |   52 | 15:42:46
 WaterMeter-SIM     |    6 | 15:42:45
```

再验一层：抄表能不能读出台底。

```bash
curl -X POST "http://127.0.0.1:8090/api/energy/meter-reading/run" \
  -H "X-Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"deviceIds":["<PowerMeter-3P-SIM 的 id>"],"period":"day"}'
```

期望 `state: normal`，`metrics` 里带着 `energy_reading` 与各项电能质量。

---

## 七、新电脑部署清单

按顺序，一步都别跳：

```bash
# ① 平台
bash scripts/02-deploy.sh

# ② 账号与字典（第一次必须跑，否则没有「能源参数字典」资产）
#    管理台 → 平台自检 → 一键修复初始化

# ③ 演示环境
python3 scripts/30-rtu-env-init.py --prune

# ④ 模拟数据（演示期间常驻）
python3 scripts/31-rtu-simulate.py --interval 30

# ⑤ RTU 烧录 main.py（真实设备接进来）
#    WiFi / 平台地址 / 网关令牌 三处按新环境改
```

**换网段时改什么**：`rtu/main.py` 顶部的 `WIFI_SSID` / `WIFI_PASS` /
`TB_HOST`。其余不用动。

---

## 八、常见问题

| 现象 | 原因 | 怎么办 |
| --- | --- | --- |
| 脚本报「找不到客户」 | 客户名不叫「平台演示中心」 | `--customer` 参数改掉 |
| 模拟设备测点是 0 条 | 属性写成字符串了（TB 存到 `str_v`，平台读 `json_v`） | 用脚本建，别手工 POST |
| 看板 `energy_total` 是 0 | 数据还不够一天，汇总窗口从昨天 00:00 起 | 让模拟器跑够一晚，或手工调 `/api/energy/asset-totals/rebuild` |
| 抄表判 `abnormal` | 表底不单调（被两个源同时写） | 确认模拟器没碰 `PowerMeter-DDSU666` |
| 又冒出一批 A栋/锅炉设备 | 跑了「一键修复初始化」 | `30-rtu-env-init.py --prune` |
| RTU 连不上 | 5GHz/2.4GHz 双频问题，或路由器防蹭网 | 关双频合一；关防蹭网；看板子串口的探活日志 |
