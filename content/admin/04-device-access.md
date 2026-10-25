# 设备接入：RTU 与网关怎么上报

> 数据进不来，后面全是空的。这一页只讲一件事：**怎么让现场设备把数据送上来。**
>
> 平台一部署好，两条通道就是开的：HTTP 和 MQTT。你要做的是
> ① 拿到设备的访问令牌 ② 按对应协议配 RTU ③ 验一条数据能上来。

## 先确认两条通道是开的

**在哪执行：【部署机 · 部署目录】**

```bash
cd ~/energy-app
docker compose exec -T energy-server env | grep -E 'SERVICE_TYPE|HTTP_ENABLED|MQTT_ENABLED|MQTT_BIND_PORT'
```

**期望输出**：

```
SERVICE_TYPE=monolith
HTTP_ENABLED=true
MQTT_ENABLED=true
MQTT_BIND_PORT=1883
```

**只要 `SERVICE_TYPE` 不是 `monolith`，设备上报一定失败** —— 而且是静默失败：
平台登录、看板、设置全都正常，只有设备送不上来。原因是设备侧端点由
`service.type=monolith && transport.http.enabled=true` 这个条件装配，
条件不满足时 `/api/v1/...` 直接返回 404。

四个值缺任何一个，回去检查 `docker-compose.yml` 里 `energy-server` 的
`environment` 段，或看[故障排查](/admin/troubleshoot)。

再看端口有没有真的映射出来：

```bash
docker compose ps energy-server
```

```
energy-server   0.0.0.0:1883->1883/tcp, 8090/tcp
                  ^^^^^^^^^^ MQTT 必须在这里
```

只有 `8090/tcp` 没有 `1883->1883`，说明 `.env` 里缺 `MQTT_PORT`。
补上再重启：

```bash
echo 'MQTT_PORT=1883' >> .env
docker compose --profile split up -d energy-server
```

---

## 拿到设备的访问令牌

设备上报不用账号密码，用的是**每台设备自己的 Access Token**。

### 页面里拿

租户管理员登录 → 设备 → 点开某台表 → 复制访问令牌。

### 命令行拿（批量时更快）

**在哪执行：【任意机器 · 能访问平台】**

```bash
# 登录
TOK=$(curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"tenant@your.com","password":"Tenant@123"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

# 列出全部设备
curl -s --noproxy '*' -H "X-Authorization: Bearer $TOK" \
  'http://127.0.0.1:8090/api/tenant/devices?pageSize=200&page=0' \
  | python3 -c "
import json,sys
for d in json.load(sys.stdin)['data']:
    print(d['id']['id'], d['name'])"

# 取某一台的令牌（把 <设备ID> 换成上一步的输出）
curl -s --noproxy '*' -H "X-Authorization: Bearer $TOK" \
  'http://127.0.0.1:8090/api/device/<设备ID>/credentials' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['credentialsId'])"
```

平台已经给每个客户的新设备生成了 `rtu-config.csv`（含每台表的 token 与点位映射），
在客户数据导入目录里。见[新客户上线](/admin/init)。

---

## 通道一：MQTT（推荐给 RTU 网关）

**这是工业现场最常用的方式**：长连接、省流量、断线自动重连。

### 连接参数

| 参数 | 值 |
| --- | --- |
| 地址 | 平台 IP |
| 端口 | `1883`（`.env` 里改过就用改后的） |
| 客户端 ID | 随便填，建议用设备名 |
| 用户名 | **设备的 Access Token** |
| 密码 | 留空 |
| 保活 | 60 秒 |

### 主题与载荷

```
主题：v1/devices/me/telemetry
载荷：{"energy":2.88,"power_total":2.88,"voltage_a":220.5}
```

QoS 0 或 1 都行。QoS 2 不支持。

### 命令行验证

**在哪执行：【任意机器 · 能连到平台】**

```bash
# 有 mosquitto 客户端时
mosquitto_pub -h 平台IP -p 1883 \
  -u '设备的AccessToken' \
  -t 'v1/devices/me/telemetry' \
  -m '{"energy":2.88,"power_total":2.88,"voltage_a":220.5}'
```

没有客户端也能验 —— 用 Python 直接讲协议：

```bash
python3 - '设备的AccessToken' <<'PY'
import socket, struct, sys, json

token = sys.argv[1]

def enc_len(n):
    out = bytearray()
    while True:
        b = n % 128; n //= 128
        out.append(b | (0x80 if n > 0 else 0))
        if n == 0: return bytes(out)

def utf8(s):
    b = s.encode(); return struct.pack('!H', len(b)) + b

s = socket.create_connection(('平台IP', 1883), timeout=10)
p = utf8('MQTT') + bytes([4, 0x82]) + struct.pack('!H', 60)
p += utf8('rtu-probe') + utf8(token)
s.sendall(bytes([0x10]) + enc_len(len(p)) + p)
ack = s.recv(4)
print('CONNACK:', ack.hex(), '→', '接受' if len(ack) >= 4 and ack[3] == 0 else '拒绝')

body = json.dumps({"energy": 2.88, "voltage_a": 220.5})
pub = utf8('v1/devices/me/telemetry') + body.encode()
s.sendall(bytes([0x30]) + enc_len(len(pub)) + pub)
print('已发送:', body)
s.close()
PY
```

**看到 `CONNACK: 20020000 → 接受` 就是通了。**

### 网关下挂多台表

一台 RTU 下面挂多块表时，用网关模式：RTU 用**网关设备**的 token 连一条 MQTT，
在报文里说明这条数据属于哪台下挂设备。

**接法 A：一表一设备（推荐）**

每块表在平台上建一台设备（名字必须与固件里**逐字一致**），RTU 用网关设备连接。

```
# ① 先声明下游设备（连上后发一次即可，重连后要重发）
topic: v1/gateway/connect
{"device": "PowerMeter-DDSU777"}

# ② 再发遥测
topic: v1/gateway/telemetry
{
  "PowerMeter-DDSU777": [
    {"ts": 1792829233716, "values": {"U": 228.0, "I": 6.2, "P": 1360.0, "Ep": 8.36}}
  ],
  "Sensor-HZ8706": [
    {"ts": 1792829233716, "values": {"temp": 23.5, "humi": 57.5}}
  ]
}
```

> **`ts` 和 `values` 两个字段都不能省**（实测 2026-10-24）：
>
> | 写成 | 平台的行为 |
> | --- | --- |
> | `[{"ts":..., "values":{...}}]` | ✅ 正常入库 |
> | `[{"values":{...}}]`（无 ts） | ❌ 不报错，整个对象被存成一个名为 **`values`** 的键，值是 JSON 字符串；设备页显示"已上报"，但曲线全空 |
> | `[{"U":228}]`（键值摊平） | ❌ `ts` 会被当成遥测键一起存进去 |
>
> `ts` 是**毫秒**。板子时间不准会让数据落到 1970 年，看板按"最近 7 天"查什么都没有 ——
> 所以固件要先 NTP 对时（或用 `/api/noauth/energy/health` 返回的 `serverTime` 校准）。

**网关设备必须打 `gateway` 标记**，否则平台把消息全丢掉：

```bash
# 设备 additional_info 里要含 "gateway": true
docker compose exec -T postgres psql -U postgres -d thingsboard -tAc \
  "SELECT name, additional_info FROM device WHERE name='ED1-Gateway';"
# → ED1-Gateway | {"siteId":"...","gateway":true}
```

漏了它的症状很隐蔽：CONNECT 认证**通过**、PUBLISH 也返回成功，但每条消息都被丢弃，
日志里只有一行：

```
ERROR MqttTransportHandler - [gatewaySessionHandler] is null ... Failed to process publish msg [v1/gateway/connect][-1]
```

把设备档案设成「网关」**不能**替代这个字段 —— 平台只认 `additional_info.gateway`。

**接法 B：一表一 token（简单但不便管理）**

RTU 为每块表建一条 MQTT 连接。表多时连接数会爆，不推荐超过 20 块。

### 现场 RTU（HaaS506-ED1）：一条命令备好 4 台设备

带实体 RTU 去客户现场演示时，平台侧要先把 4 台设备备齐 —— 否则 RTU 一上电，
TB 会自动建成 default 档案的孤儿设备，抄表/台账/看板都不认。

```bash
cd ~/energy-app
python3 scripts/21-rtu-onboard.py \
  --base http://<本机局域网IP>:8090 \
  --tenant tenant@126.com --tenant-pass '12345678' \
  --customer 星河工业园
```

它会建（或修复）这 4 台，并把网关令牌固定成 `ED1GatewayDemoRig2026`：

| 设备 | 档案 | 说明 |
| --- | --- | --- |
| `ED1-Gateway` | 网关 | 带 `gateway: true`，令牌固定 |
| `PowerMeter-DDSU777` | 单相电能表 | `meterLevel=0`（不参与场站汇总，但能抄表） |
| `Sensor-HZ8706` | 温湿度变送器 | |
| `Relay-8CH` | default | 8 路继电器，RPC 控制 |

**为什么令牌要固定**：TB 默认随机生成，重装一次变一次，现场就得重烧固件。
固定之后，**重装、重建客户、换机器都不用改固件**。

**为什么电表 meterLevel=0**：演示数据的账单与「层级守恒」断言按 meterLevel 分层算，
真实 RTU 表若给 1/2 级会混进园区汇总，演示数字会莫名变化。level=0 仍能抄表、能看实时曲线。

**验证链路**（没有硬件时用模拟器，走与真机完全相同的 MQTT 路径）：

```bash
python3 scripts/20-rtu-simulator.py \
  --base http://127.0.0.1:8090 --tenant tenant@126.com --tenant-pass '12345678' \
  --mode gateway --gateway ED1-Gateway --device Sensor-HZ8706 \
  --mqtt-host 127.0.0.1 --mqtt-port 11883 --interval 1 --count 3
```

现场把 `--mqtt-host/--mqtt-port` 换成平台地址与 `11883`。

### 演示专用客户「平台演示中心」：真机 + 模拟混跑

平台自留一个客户账号专门用于演示（不对外发放、不随客户销户清理）：

| 项 | 值 |
| --- | --- |
| 客户名 | `平台演示中心` |
| 账号 | `demo@126.com` / `demo123456` |
| 角色 | CUSTOMER_USER（与普通客户完全一致，能验证客户侧全部权限） |

**分工：谁能真机演、谁只能模拟**

| 品种 | 出数来源 | 原因 |
| --- | --- | --- |
| 单相电 | **真实 RTU**（`PowerMeter-DDSU777`） | 现场带板子，能证明"平台真能接设备" |
| 单相电（其余演示表） | 模拟器 | 一台 RTU 只能覆盖一块表 |
| 三相电 | 模拟器 | 没有三相表，测不到三相电压/电流/不平衡度 |
| 水 / 燃气 / 蒸汽 | 模拟器 | 没有水气汽表 |
| 温湿度（非 RTU 那台） | 模拟器 | 同上 |

#### 启动模拟（演示前 1 分钟执行）

```bash
cd ~/energy-app
python3 scripts/23-demo-simulator.py \
  --base http://127.0.0.1:8090 \
  --tenant tenant@126.com --tenant-pass '12345678' \
  --customer 平台演示中心 \
  --interval 60 --rebuild-totals
```

它给 **19 台**不能真机演的表持续上报（跳过 RTU 那 4 台，避免两个源同时写表底）：

```
electric 11 / gas 2 / sensor 2 / steam 2 / water 2
```

**常用开关**

| 开关 | 作用 |
| --- | --- |
| `--once` | 只跑一轮（验收/自检用） |
| `--dry-run` | 只打印会写什么，不落库 |
| `--interval 60` | 每 60 秒一批；演示节奏建议 30~60 秒 |
| `--rebuild-totals` | 每轮顺带重算资产汇总（看板"选场站"维度才跟着更新） |
| `--only 三相` | 只模拟名字含"三相"的设备 |
| `--skip 水表,燃气` | 跳过某些设备 |
| `--include-rtu` | 连 RTU 四台也模拟（**真机在跑时别开**，会打架） |

**它不会做的事（刻意留白）**

- **不模拟虚拟表**（`空调虚拟表` / `其他虚拟水表`）：那两台是"手工填报"页的载体，
  只有月首点。自动上报会让手工填报的演示自相矛盾。
- **不覆盖历史**：只往当前时间往后写。历史 62 天是初始化时生成的静态数据。
- **不改表底起点**：首次运行从库内最新 `energy_reading` 接着涨，不会倒走。

**数据模型（改错会让看板空白）**

```
电表      energy（本周期增量） energy_reading（累积表底，单调递增） power_total
          voltage_a [current_a]        三相另有 _b / _c、voltage_unbalance、power_factor_*
水/气/汽   energy  energy_reading  power
温湿度     temperature  humidity
```

> **表底必须单调递增，且父表增量 >= 子表之和。**
> 脚本按平台已有的 `Contains` 关系建树，父表功率 = 子表实际值之和 × 1.04（线损），
> 天然满足 `08-verify-release.sh` 的「演示用电层级守恒」断言。
> 父表功率**必须由子表实际值汇总**，不能各算各的 —— 否则抖动叠加后
> 子表之和会超过父表，验收当场失败。

#### 演示前 60 秒自检清单

```bash
# ① RTU 四台在线？（应为 active=True）
python3 scripts/22-watch-rtu.py --base http://127.0.0.1:8090 \
  --tenant tenant@126.com --tenant-pass '12345678' \
  --customer customer@126.com --customer-pass '12345678' --seconds 10

# ② 模拟器一轮能不能写进去？（应为 19/19 成功）
python3 scripts/23-demo-simulator.py \
  --base http://127.0.0.1:8090 --tenant tenant@126.com --tenant-pass '12345678' \
  --customer 平台演示中心 --once
```

两项都过 → 登录 `demo@126.com` 开始演示。

#### 设备从旧客户迁到新客户（脚本会自动处理）

`21-rtu-onboard.py` 换客户时会做三件事，缺一件就会出现"看起来串台"：

1. **改归属**：走 `POST /api/customer/{cid}/device/{did}`（owner API）。
   直接保存设备会报 `Entity owner can't be changed`。
2. **清旧关系**：删掉「旧场站 --Contains--> 这台设备」。
   不删的话，抄表树的节点名会显示**旧客户的场站名** —— 设备归属是对的，
   但客户在演示中心里看到别家公司的名字（2026-10-24 实测踩过）。
3. **重读版本号**：改归属会 `version++`，不重读就保存会报
   `409 Device was already changed by someone else`。

#### 上报周期与「实时能耗」的滚动曲线

`rtu/main.py` 的 `REPORT_INTERVAL_SECS`（默认 5 秒）决定曲线多久出现一个新折点。

| 值 | 观感 | 代价 |
| --- | --- | --- |
| `5`（默认） | 每秒滚动，折点每 5 秒新增 | 稳，规则链压力正常 |
| `1` | 折点每秒前进，最像示波器 | 规则链与写库约 5 倍压力（日志会多出 `Timeout to process`） |

**改完要同步改看板**：实时能耗看板 → 趋势部件的 `rawSecs` 必须与上报周期一致。
不一致时会出现「桶比上报密」的空折点（曲线断续）。

**这个页面为什么没有红色加载条**：实时页每 3 秒主动拉一次遥测，绑定全局请求状态的
红色进度条会跟着闪，看起来像一直在加载。该看板的 `configuration.settings`
里设了 `suppressLoadingBar: true`，其它 53 个看板行为不变。

#### 固件侧要核对的四组配置

`rtu/main.py` 顶部「配置区」逐条核对，上电后串口第一屏会原样回显（「配置自检」）：

| 组 | 项 | 现场取值 |
| --- | --- | --- |
| ① WiFi | SSID / 密码 | 客户现场网络 |
| ② 平台 | `TB_HOST` | **平台机器的局域网 IP**（不能写 127.0.0.1） |
| | `TB_PORT` | `11883`；连不上会自动回退 `1883`（平台两个端口都在听） |
| | `TB_TOKEN` | `ED1GatewayDemoRig2026`（固定值，正常不用改） |
| ③ 本机 | `RTU_IP` | 与 ① 同网段；换网络不确定时设 `None` 用 DHCP |
| ④ 设备名 | 4 个名字 | 必须与平台上**逐字一致** |

#### 现场三个静默陷阱（都不报错，只表现为"没数据"）

1. **端口不一致**：固件写 11883、平台只开 1883（或反之）→ 探活通过、MQTT 连不上
2. **缺 `ts`**：数据全落进 `values` 键（见「网关下挂多台表」）
3. **缺 `gateway: true`**：消息被丢弃，日志报 `gatewaySessionHandler is null`

新版固件对 1、2 都做了处理（端口回退、强制带 ts、时间不可信时拒发并提示）；
3 是平台侧的数据，用上面的 `21-rtu-onboard.py` 一次配好。

---

## 通道二：HTTP（适合脚本、单板机、调试）

### 请求格式

```
POST http://平台IP:8090/api/v1/{AccessToken}/telemetry
Content-Type: application/json

{"energy":2.88,"power_total":2.88,"voltage_a":220.5}
```

### 命令行验证

```bash
curl -s --noproxy '*' -w '\nHTTP %{http_code}\n' \
  -X POST 'http://127.0.0.1:8090/api/v1/设备的AccessToken/telemetry' \
  -H 'Content-Type: application/json' \
  -d '{"energy":2.88,"power_total":2.88,"voltage_a":220.5}'
```

**看到 `HTTP 200` 就是通了。**

> 注意 `--noproxy '*'`：本机或公司网络里的代理会接管 `127.0.0.1`，
> 不加这个参数会得到 `502` 或超时，很难查。

---

## 上报哪些字段

**字段名必须与「能源参数字典」完全一致**，差一个字就存不进对应的参数位，
报表展开到那一项就是空白。

> 查 key 最快的路径：租户 → **运营配置 → 品种指标**。
> 选品种 → 看到该品种的设备类型 + 全部标准 key，点一下复制。

### 电表（26 项标准参数）

最常用的十几个：

| 字段 | 含义 | 单位 | 聚合 |
| --- | --- | --- | --- |
| `energy` | 本小时用电量（**增量**） | kWh | SUM |
| `energy_reading` | 正向有功总电度（**累积表底**） | kWh | MAX |
| `energy_day` | 当日累计 | kWh | MAX |
| `power_total` | 总有功功率 | kW | AVG |
| `power_a/b/c` | 分相有功功率 | kW | AVG |
| `voltage_a/b/c` | 分相电压 | V | AVG |
| `voltage_avg` | 平均相电压（三相汇总） | V | AVG |
| `current_a/b/c` | 分相电流 | A | AVG |
| `current_avg` | 平均相电流（三相汇总） | A | AVG |
| `power_factor_total` | 总功率因数 | — | AVG |
| `energy_peak` / `energy_flat` / `energy_valley` / `energy_deep` | 分时电量 | kWh | SUM |
| `frequency` | 频率 | Hz | AVG |
| `demand_max` | 最大需量 | kW | MAX |
| `load_rate` | 负载率 | % | AVG |
| `voltage_unbalance` | 电压不平衡度 | % | AVG |

完整 26 项在**运营配置 → 品种指标**页面里看（可点 key 复制）。

### 水 / 燃气 / 蒸汽（各 3 个）

| 字段 | 含义 | 聚合 |
| --- | --- | --- |
| `energy` | 本小时用量（增量） | SUM |
| `power` | 瞬时流量 | AVG |
| `energy_reading` | 累积表底 | MAX |

### 温湿度

| 字段 | 含义 |
| --- | --- |
| `temperature` | 温度（℃） |
| `humidity` | 湿度（%） |

---

## ⚠ 增量与表底：最容易写错的地方

**这是现场接入 90% 数据错误的来源，务必看清。**

```
energy          本小时用了多少    1.20  1.35  0.98   ← 每分钟/每小时都给一个新的小数值
energy_reading  表上显示的总数    33705.42  33706.77  33707.75   ← 只增不减
```

三条铁律：

1. **`energy` 必须是增量**，不是表底。写成表底，任何「求和」的报表都会得到天文数字。
2. **`energy_reading` 必须单调递增**。换表、清零、回退都会破坏它，要在平台上登记换表事件。
3. **相邻两点的 `energy_reading` 之差，必须等于后一点的 `energy`**：
   ```
   energy_reading[n] − energy_reading[n−1] == energy[n]
   ```

第三条是平台自检的核心断言。`04-verify-data.sh` 就是逐点验它。

### 正确的写法

```json
{"energy": 1.20, "energy_reading": 33706.62}
```

下一分钟：

```json
{"energy": 1.35, "energy_reading": 33707.97}
```

`33707.97 − 33706.62 = 1.35` ✓

### 错误的写法

```json
{"energy": 33706.62, "energy_reading": 33706.62}
```

把表底当成了增量 —— 月报表会算成几十万度。

### 单相表不要写 B/C 相

单相表只有 A 相。写了 `voltage_b: 0` 会让「相电压」报表把 0 当成真实读数，
最小值永远贴着零。

**只写 A 相和汇总项：**

```json
{"energy":1.2,"energy_reading":33706.6,"power_a":1.2,"power_total":1.2,
 "voltage_a":220.5,"voltage_avg":220.5,
 "current_a":5.9,"current_avg":5.9,
 "power_factor_a":0.92,"power_factor_total":0.92}
```

> 单相表的 `voltage_avg` / `current_avg` 就等于 A 相的值 —— 写上，
> 三相汇总口径的报表才能把单相表一起算进去。

**判断哪些键要配**：租户 → 运营配置 → **品种指标** →
选「单相电能表」，灰显并标「单相不适用」的那些就是不用配的（B 相、C 相全部）。

---

## 验一条数据真的上来了

发完数据等 2 秒，然后查最新遥测：

```bash
TOK=$(curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"tenant@your.com","password":"Tenant@123"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

curl -s --noproxy '*' -H "X-Authorization: Bearer $TOK" \
  "http://127.0.0.1:8090/api/plugins/telemetry/DEVICE/<设备ID>/values/timeseries?keys=energy,voltage_a" \
  | python3 -m json.tool
```

**看到你刚发的值和时间戳，就说明全链路通了。**

---

## 上报不通，按这个顺序查

| 现象 | 原因 | 怎么办 |
| --- | --- | --- |
| HTTP 404 | 设备端点未装配 | 查 `SERVICE_TYPE=monolith` |
| HTTP 401 / 403 | token 不对 | 重新复制令牌，注意别带空格 |
| HTTP 200 但读不到 | 键名不在字典里 | 对照上面的字段表 |
| MQTT 连不上 | 端口没映射 | `docker compose ps` 看 1883 |
| MQTT CONNACK 拒绝 | token 错或设备被禁用 | 换 token 试 |
| 数据上来了但报表空 | 设备未挂分项/场站 | 见下面的「挂到哪里」 |
| 值是 0 | 上报真的发了 0 | 看 RTU 侧 |

### 设备要挂到场站和分项

数据上来了，但报表里看不到 —— 十有八九是设备没挂到分项。

平台要靠两条关系才能把数据算进报表：

```
场站 --Contains--> 分项 --Contains--> 设备
```

命令行挂：

```bash
# 设备挂分项
curl -s --noproxy '*' -X POST -H "X-Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' \
  -d '{"from":{"entityType":"ASSET","id":"<分项ID>"},
       "to":{"entityType":"DEVICE","id":"<设备ID>"},
       "type":"Contains","typeGroup":"COMMON"}' \
  'http://127.0.0.1:8090/api/relation'
```

页面里挂：设备 → 编辑 → 所属分项。

### 设备要标计量层级

分项汇总、总分差、待机识别都靠 `meterLevel` 这个属性：

| 值 | 含义 | 例子 |
| --- | --- | --- |
| 1 | 一级（进线总表） | 厂区总表 |
| 2 | 二级（分项总表） | 车间总表 |
| 3 | 三级（末端表） | 单台设备 |

页面里：设备 → 属性 → `meterLevel`。
命令行：

```bash
curl -s --noproxy '*' -X POST -H "X-Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' \
  -d '{"meterLevel":2}' \
  "http://127.0.0.1:8090/api/plugins/telemetry/DEVICE/<设备ID>/SERVER_SCOPE"
```

## 装完 RTU 之后：四条链路逐条验

「RTU 装上就能用」这句话要拆成四段验证。每段都能在页面上看到结果，
不用翻日志 —— 哪一段断了自己就露出来。

| 环节 | 依赖什么 | 在哪看结果 | 断了会怎样 |
| --- | --- | --- | --- |
| 采集 | RTU + Access Token + 通道端口 | 客户 → 设备管理 → 选设备 → 最新遥测 | 页面一行数据都没有 |
| 分析 | 遥测键名匹配字典 | 能耗查询 / 峰谷分析 / 分项能耗 | 有数据但报表空白或全算「平」 |
| 评估 | 设备档案上的 4 条告警规则 | 告警中心 | 数据正常但从不产生告警 |
| 预测 | AI 服务（`ngx-ai`） | 能耗优化 → 负载预测 | 页面打不开或提示服务不可用 |

### 1. 采集：先让一台表出数

```bash
# 换成你自己的设备令牌
curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/v1/DEVICE_TOKEN/telemetry \
  -H 'Content-Type: application/json' \
  -d '{"energy":1234.5,"energy_reading":1234.5,"power_total":12.3,"voltage_a":220.1}'
```

返回 `200`。然后看页面：客户 → 设备管理 → 该设备 → 最新遥测，
应出现这 4 个键。

**键名必须和字典一致**（`energy` / `energy_reading` / `power_total` / `voltage_a` …），
字典全表见上一节。键名写错不会报错，数据也存进去了，只是所有报表都不认它。

### 2. 分析：三张报表都能出数

依次打开：历史能耗 → 峰谷分析 → 分项能耗。

- **历史能耗**：曲线有数 = 数据进了时序库
- **峰谷分析**：峰/平/谷都有值 = 分时方案生效（全算「平」说明租户缺 `tou_scheme`）
- **分项能耗**：能看到这台表 = 设备已挂到分项，且档案标了 `isMeter`

### 3. 评估：告警规则是「继承来的」

电表档案上预装了 4 条告警（电压越限 / 功率因数偏低 / 三相不平衡度超限 / 闲时能耗超标），
**新接入的设备只要选了该档案就自动带**，不需要逐台配。

验证：发一条越限数据

```bash
curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/v1/DEVICE_TOKEN/telemetry \
  -H 'Content-Type: application/json' \
  -d '{"voltage_a":180,"power_factor_total":0.75}'
```

等 10–30 秒，告警中心应出现「电压越限」「功率因数偏低」。
再发一条正常值（`220` / `0.95`），告警应自动清除。

**闲时能耗超标**这一条不靠遥测阈值，而是读服务端的日结算结果：

```bash
# 模拟"今天超标"（真实场景由闲时能耗模块每天自动写）
curl -s --noproxy '*' -X POST \
  -H "X-Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"idle_exceed":1}' \
  "http://127.0.0.1:8090/api/plugins/telemetry/DEVICE/$DEV/timeseries/SERVER_SCOPE"
```

等 10 秒出现「闲时能耗超标」MINOR；发 `0` 转「已清除」。
阈值在「组织与场站 → 场站 → 闲时能耗」里配。

> 告警没出现，先看设备档案是不是「单相电能表 / 电能表」——
> 选成「默认」档案就没有这套规则。租户 → 设备档案 → 计算字段可核对。

### 4. 预测：这一环**不是** RTU 带来的

负载预测、用能建议、用能质量跑在 AI 服务（`ngx-ai`）里，和 RTU 是两条独立链路：

- RTU 负责**产生数据**
- AI 服务负责**基于历史数据做预测**

所以「只装 RTU」能拿到采集 + 分析 + 评估；预测还需要 AI 服务在跑，
并且该场站已有足够历史数据（建议 ≥ 14 天）。

判断方法：客户 → 能耗优化 → 负载预测。打不开说明 AI 服务没起，
见[常见问题](/admin/troubleshoot)的 AI 服务一节；能打开但没有曲线，
说明历史数据不够，先让 RTU 稳定上报几天。

### 一把过：用自检页确认

客户 → 设备运维 → **平台自检**。
「遥测数据」项显示有值 = 采集通了；其余项逐条对着看，
缺什么、怎么补、看手册哪一页，页面上直接写着。

---

## 换成自己的真实数据（清掉演示数据）

演示数据只用于快速验收，接入真实设备后建议清掉，免得报表里真假混在一起。

**页面上**：客户 → 设备运维 → 平台自检 → 「清除演示数据」。
只删带 `demo` 标记的场站、分项、设备与遥测；你自己新建的资产和设备不受影响。

**命令行**：

```bash
# 登录拿 token
TOK=$(curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"customer@126.com","password":"12345678"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

# 看看现在有多少演示数据
curl -s --noproxy '*' -H "X-Authorization: Bearer $TOK" \
  http://127.0.0.1:8090/api/energy/demo-data

# 清除
curl -s --noproxy '*' -X DELETE -H "X-Authorization: Bearer $TOK" \
  http://127.0.0.1:8090/api/energy/demo-data
```

清除后按上面的「四条链路」重新验一遍 —— 这次数据全部来自你自己的 RTU。

---

## 现场上线前的一张检查表

- [ ] `SERVICE_TYPE=monolith`，`HTTP_ENABLED=true`，`MQTT_ENABLED=true`
- [ ] `docker compose ps` 里能看到 `1883->1883/tcp`
- [ ] 防火墙放行 1883（MQTT）和 8090（HTTP）
- [ ] 每台表都有 Access Token，记在 `rtu-config.csv` 里
- [ ] 设备档案选对（单相表选「单相电能表」，三相选「电能表」）
- [ ] 设备挂到了正确的分项，分项挂到了场站
- [ ] `meterLevel` 标了 1/2/3
- [ ] 发一条测试数据，读回来值和时间都对
- [ ] 跑 `bash scripts/04-verify-data.sh`，`energy` 与 `energy_reading` 守恒
