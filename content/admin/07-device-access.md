# ⑦ 设备接入（RTU 与演示环境）

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
在客户数据导入目录里。见[新客户上线](/admin/onboard)。

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

---

## 上报哪些字段

**唯一真相源是字典**（见 [④ 数据模型 · 标准 key](/admin/data-model#标准-key-的能力分级tier)）。
这里只讲最容易写错的三处。

### 1. 单相表不要写 B/C 相

键名以 `_b` / `_c` 结尾的，单相表（1P2W）**根本没有**。
配了不会报错，但那些线永远是空的 —— 会让人以为表坏了。

判据：`wiring=1P2W` 的设备，`keysByWiring` 只有 22 项，全都不含 `_b`/`_c`。

### 2. 增量与表底：两个都要报

| 键 | 语义 | 是否必须 |
| --- | --- | --- |
| `energy_reading` | 累积表底（表盘上的数） | **强烈建议**，这是对账与差分的唯一依据 |
| `energy` | 本周期增量 | 可选，但丢了就永久丢 |

平台用量一律走「表底差」：`energy_reading(本期) − energy_reading(上期)`。
所以**只报表底也能算用量**（后端会自动差分），但只报 `energy` 一旦漏点就无法恢复。

详见 [⑤ 数据流 · 表底 vs 增量](/admin/data-flow#六表底-vs-增量)。

### 3. 键名必须是字典里的标准名

厂家代号（`U` / `I` / `P` / `Ep`）要靠规则链的 `renameKeys` 转成标准名，
否则数据进不了业务视图。判据与 SQL 见 [⑤ 数据流](/admin/data-flow#七厂家指标名不一样)。

---

## 验一条数据真的上来了

三步，每一步都要过，卡在哪一步就是那个环节的问题：

```bash
# ① 平台收到了（HTTP 200 = 接收成功）
#    见上文的 curl 验证

# ② 落库了（键名是标准名，不是厂家代号）
docker exec energy-postgres psql -U postgres -d thingsboard -c "
SELECT kd.key, count(*) AS 点数, max(to_timestamp(t.ts/1000)) AS 最新
FROM ts_kv t JOIN ts_kv_dictionary kd ON kd.key_id = t.key
WHERE t.entity_id = '<设备id>'
GROUP BY 1 ORDER BY 2 DESC LIMIT 10;"

# ③ 页面看得见
#    设备详情 → 最新遥测；再打个测试告警看能否触发
```

**② 有数据但 ③ 没有** → 是通道之外的配置问题：
设备没挂到场站（[④](/admin/data-model#场站归属只认关系不认属性)）、
没标计量层级、或品种判错。

---

## 上报不通，按这个顺序查

| 顺序 | 查什么 | 判据 |
| --- | --- | --- |
| 1 | `SERVICE_TYPE=monolith` 且 `HTTP_ENABLED=true` | 不是 → `/api/v1/...` 直接 404 |
| 2 | 端口映射 `1883->1883` | 只有 `8090/tcp` → `.env` 缺 `MQTT_PORT` |
| 3 | 访问令牌对不对 | 错的令牌返回 401，且不带原因 |
| 4 | 设备名是否与平台一致 | 网关模式下按**设备名**匹配，对不上会落到别的设备 |
| 5 | 时间戳 | 设备时钟偏差 > 5 分钟会被丢弃 |
| 6 | 键名 | 厂家代号能入库，但看板读不到（见上一节） |

**常见现场问题**：

| 现象 | 原因 |
| --- | --- |
| WiFi 连不上 | 路由器开了「防蹭网」/ 双频合一（2.4G 与 5G 同名） |
| 上报成功但没数据 | 设备名与平台不一致（网关模式） |
| 数据落在了别的设备上 | 同上，网关按名字匹配 |
| 一会有一会没有 | 信号弱 / 设备频繁重连 / 时钟漂移 |

---

## 演示环境（无真实设备时）

平台自带一套**纯模拟**的演示环境，用来演示、培训、验收。
不依赖任何硬件，脚本在服务器侧按小时生成数据。

### 拓扑

```
单相园区·平台演示中心（办公园区）
└─ ED1-Gateway          真实 RTU（HaaS506-ED1）或脚本模拟
   ├─ PowerMeter-DDSU666   单相电表（真实）→ 插座分项 · 公共区域
   ├─ Sensor-HZ8706        温湿度传感器（真实）→ 公共区域
   └─ Relay-8CH            8 路继电器（真实）← 可控 → A栋办公区
   ＋ PowerMeter-1P-SIM    单相模拟表（照明总表）→ 照明分项 · 公共区域
   ＋ WaterMeter-SIM       水表（模拟）→ 给排水分项 · 公共区域
   ＋ GasMeter-SIM         燃气表（模拟）→ 炊事分项 · 食堂区域

三相园区·平台演示中心（生产园区）
└─ ED2-Gateway          模拟（脚本发数据）
   ├─ PowerMeter-3P-SIM    三相电表 3P4W ← 电能质量全场景
   ├─ SteamMeter-SIM       蒸汽表 → 蒸汽分项 · 锅炉房
   ├─ HeatMeter-SIM        热力表 → 锅炉分项 · 锅炉房
   ├─ AHU-SIM              新风机组（env）← 可控 → 办公区
   └─ Breaker-SIM          智能空开（带计量）← 可控 → 动力分项 · 生产车间
```

### ⭐ 两路数据可以并存，也可以只开一路

**这是最容易误解的一点**：真实 RTU 与模拟上报是**两条独立的源**，
写的是**不同设备**，互不覆盖。场站总量是两者之和。

| | 谁控制 | 怎么开 | 怎么关 |
| --- | --- | --- | --- |
| **真实 RTU** | 硬件自己 | 板子上电、连上 WiFi 就开始报 | 断电 / 断网 |
| **模拟上报** | 脚本 | `--sim-only` 常驻 | `Ctrl-C` |

所以有四种基本用法：

| 场景 | 模拟 | 真实 | 命令 |
| --- | --- | --- | --- |
| **纯演示**（无硬件） | ✅ | — | `--sim-only` |
| **纯现场**（只有真表） | ❌ | ✅ | `--no-sim` |
| **混合**（真表 + 模拟） | ✅ | ✅ | 默认（两个参数都不加） |
| **只看状态** | — | — | `--status` |

---

### 完整参数说明（按「我要做什么」查）

> 下表每个命令都可以**直接复制**到服务器上跑。
> **关键区别看两列：「建客户账号？」和「写模拟数据？」** —— 这是最容易搞错的。

| 我要做什么 | 命令 | 建客户账号？ | 写模拟数据？ | 常驻？ |
| --- | --- | --- | --- | --- |
| 全新库一键到「能演示」 | `bash scripts/29-rtu-demo-up.sh` | ✅ 会 | ✅ 回填 30 天 + 发一轮 | 否，跑完退出 |
| **客户账号已建好，只想恢复模拟** | `bash scripts/29-rtu-demo-up.sh --sim-only` | ❌ **不建** | ✅ 持续上报 | ✅ **是，Ctrl-C 停** |
| 只要真实 RTU，不要任何假数据 | `bash scripts/29-rtu-demo-up.sh --no-sim` | ✅ 会 | ❌ 不写 | 否 |
| 看谁在报、谁停了 | `bash scripts/29-rtu-demo-up.sh --status` | ❌ 不建 | ❌ 不写 | 否，读完就退 |
| 只体检，不改任何数据 | `bash scripts/29-rtu-demo-up.sh --check` | ❌ 不建 | ❌ 不写 | 否 |
| 给另一个客户初始化 | `bash scripts/29-rtu-demo-up.sh --customer "新客户名"` | ✅ 会 | ✅ | 否 |
| 回填更长的历史 | `bash scripts/29-rtu-demo-up.sh --backfill-days 90` | ✅ 会 | ✅ 回填 90 天 | 否 |
| 不要历史，只发当前值 | `bash scripts/29-rtu-demo-up.sh --backfill-days 0` | ✅ 会 | ✅ 只发一轮 | 否 |
| 改模拟上报频率（默认 30s） | `bash scripts/29-rtu-demo-up.sh --sim-only --interval 10` | ❌ 不建 | ✅ 每 10s 一轮 | ✅ 是 |

#### 逐个场景备注

**① 默认（无参数）—— 只在「新库首次部署」时用**

```bash
cd ~/energy-app && bash scripts/29-rtu-demo-up.sh
```

做四件事：建客户 → 建场站/设备 → 回填 30 天历史 + 发一轮 → 重算资产汇总。
**跑完就退出**，模拟不会继续上报 —— 演示前还要再开 `--sim-only`。

> ⚠ 已有数据的环境重跑它，会**再走一遍建客户/建设备**（幂等，不会重复建，
> 但会耗时 1-3 分钟）。只想恢复模拟数据的话，用下面的 `--sim-only`。

**② `--sim-only` —— 日常最常用（客户已建好、只想看数据动起来）**

```bash
cd ~/energy-app
nohup bash scripts/29-rtu-demo-up.sh --sim-only --interval 30 \
  > /tmp/rtu-sim.log 2>&1 &
```

- **不会建客户、不会建账号、不会建场站设备** —— 直接跳到发数据步骤
- 客户不存在会直接报错退出（`找不到客户「xxx」`），不会替你建
- **这是常驻命令**（每 30s 一轮），关掉终端就停 —— 所以用 `nohup ... &`
- 停：`pkill -f 31-rtu-simulate.py`

验证是否真的在跑：

```bash
bash scripts/29-rtu-demo-up.sh --status
# 期望：模拟上报：8 台在上报 / 模拟脚本进程：1 个在跑
```

**③ `--no-sim` —— 现场只信真实 RTU**

```bash
bash scripts/29-rtu-demo-up.sh --no-sim
```

建客户/场站/设备，但**一条模拟数据都不写、不回填历史**。
看板能不能出数**完全取决于真实表有没有在报** —— 没报就是空的，这是真实状态。

**④ `--status` —— 排查第一条命令**

```bash
bash scripts/29-rtu-demo-up.sh --status
```

只读不写。看三类信息：谁在上报、最后上报多久前、模拟脚本进程在不在。
判活**只看数据不看进程**（原因见下面「`--status` 输出怎么看」）。

**⑤ `--check` —— 动数据之前先看一眼**

```bash
bash scripts/29-rtu-demo-up.sh --check
```

调 `30-rtu-env-init.py --dry-run`：列出「将会建/改什么」，**一次写入都不做**。
刚接手一个环境、不确定现状时先跑它。

**⑥ `--customer` —— 多客户环境必带**

```bash
bash scripts/29-rtu-demo-up.sh --sim-only --customer "星河工业园"
```

所有命令都该带上它。**不带时默认操作「平台演示中心」**，可能改到不是你想的那个客户。

**⑦ 组合示例**

```bash
# 新客户初始化 + 回填 90 天 + 保持模拟常驻（分两步：先初始化，再常驻）
bash scripts/29-rtu-demo-up.sh --customer "新客户" --backfill-days 90
nohup bash scripts/29-rtu-demo-up.sh --sim-only --customer "新客户" > /tmp/sim.log 2>&1 &

# 现场排查：先看状态，再决定要不要开模拟
bash scripts/29-rtu-demo-up.sh --status --customer "星河工业园"
bash scripts/29-rtu-demo-up.sh --sim-only --customer "星河工业园" --interval 60
```

#### 客户账号：脚本会不会重复建？

**不会重复建，但有一个例外要知道。**

脚本按固定规则生成演示账号邮箱：`demo+<客户id前8位>@126.com`。
先查这个邮箱在不在，在就不建、也不改密码。

| 情况 | 会发生什么 |
| --- | --- |
| 没建过 | 建 `demo+xxxxxxxx@126.com` / `demo123456`，并激活 |
| 已建过、没改密码 | 复用，结尾照实报密码 |
| 已建过、**客户改过密码** | 复用，结尾**不会**报 `demo123456`，而是提示「密码沿用原值」 |
| 你在后台自建了 `customer@xx.com` | 脚本**再建一个** `demo+xxxxxxxx@126.com`。两个账号共存，互不影响 |

最后一行是唯一的「多建一个」情况。不想多一个账号，就用 `--sim-only`
（完全不碰账号）。

### `--status` 输出怎么看

```
  来源     设备                                 最后上报       判定
  ────────────────────────────────────────────────────────────
  模拟     PowerMeter-3P-SIM·平台演示中心           1s 前       ✓ 实时
  真实     PowerMeter-DDSU666                 3s 前       ✓ 实时
  真实     Sensor-HZ8706                      3s 前       ✓ 实时

  ✓ 真实 RTU：3 台在上报
  ✓ 模拟上报：8 台在上报
  ✓ 模拟脚本进程：1 个在跑
```

**四条判据**：

| 判据 | 阈值 | 为什么 |
| --- | --- | --- |
| 真实 RTU「实时」 | 最后写入 ≤ 2 分钟 | 现场上报间隔可能到 1 分钟 |
| 模拟「实时」 | 最后写入 ≤ 5 分钟 | 默认 30s 一轮，留余量 |
| 网关不在列表里 | — | 网关只转发，本身不产生业务遥测；列进来会永远显示「已停」 |
| 进程检查只作提示 | — | 脚本可能跑在另一台机器 / nohup / systemd，进程不可靠 |

> **判活只看数据，不看进程。** 进程在跑但没数据 = 实际没在工作；
> 进程不在但数据新鲜 = 可能是**残留读数**（5 分钟内的最后写入），
> 不会继续更新。`--status` 会在这种情况下明确提示。

### `--no-sim` 时的预期

**不发模拟数据、不回填历史**，看板能不能出数**完全取决于真实表有没有在报**：

- 真实表在报 → 页面有数，场站/分项汇总只含真实表
- 真实表没报 → 页面空的。**这是真实状态，不是故障**

先 `--status` 确认真实表在报，再判断页面空是不是问题。

### 三个脚本的分工

| 脚本 | 作用 | 建客户/账号？ | 写模拟数据？ |
| --- | --- | --- | --- |
| `29-rtu-demo-up.sh` | **一键编排**：客户 / 场站 / 设备 / 回填 / 汇总 / 状态 | 看参数（下表） | 默认会，`--no-sim` 不会 |
| `30-rtu-env-init.py` | 只建/补齐数据（幂等，不碰遥测） | 会（查重，不重复建） | 不会 |
| `31-rtu-simulate.py` | 只发数据（持续上报 / 回填历史） | **不会** | 会 |

**`29` 的哪些参数会动客户/账号**：

| 参数 | 建客户 | 建账号 |
| --- | --- | --- |
| （无参数） | ✅ | ✅ |
| `--sim-only` | ❌ 直接跳到发数据 | ❌ |
| `--no-sim` | ✅ | ✅ |
| `--status` | ❌ | ❌ |
| `--check` | ❌（dry-run） | ❌ |

> 「客户已建好、只想恢复模拟数据」→ 用 `--sim-only`，它根本不调 `30-rtu-env-init.py`。
> 完整参数说明见上面「完整参数说明（按「我要做什么」查）」。

```bash
# 关闭电能质量异常注入（真实现场演示时不造假异常）
python3 scripts/31-rtu-simulate.py --interval 30 --no-pq-anomaly
```

> **部署目录里其他脚本是什么**：`scripts/` 里有十几个 `24-` `25-` `28-` `29-dedupe-`
> 开头的脚本，是历史上一次性修数据用的（改设备分类、去重重复时间控件等），
> 已经跑过的不必再动。日常只用上表三个，加 `02-onboard`、`09-onboard-customer`、
> `10-cleanup-customer`。不确定某个脚本干什么：看它开头 20 行的注释。

### 电能质量覆盖

三相模拟表按**专业电能质量表**的能力布局（tier = `harmonic` / `pq`）：

| 场景 | 遥测键 | 国标限值 | 正常态 |
| --- | --- | --- | --- |
| 三相电压趋势 | `voltage_a/b/c`、`voltage_avg` | 220V ±7% | 218~229 V |
| 电压偏差 | `voltage_deviation_a/b/c` | ±7%（GB/T 12325） | −3%~+4% |
| 频率偏差 | `frequency`、`frequency_deviation` | 50 ± 0.2 Hz | 49.95~50.05 |
| 三相不平衡 | `voltage_unbalance` | ≤ 2%（GB/T 15543） | ≤ 1.2% |
| 序分量 | `voltage_seq_*`、`current_seq_*` | —— | 负序 ≈ 不平衡×0.6 |
| 谐波畸变 | `voltage_thd_*`、`current_thd_*` | 电压 ≤ 5%（GB/T 14549） | 1.2~3.8% |
| 分次谐波 | `*_harmonic_2..31` | 分次限值 | 按次数递减 |
| 电压闪变 | `flicker_pst`、`flicker_plt` | Pst ≤ 1.0，Plt ≤ 0.8 | 0.20~0.90 |
| 中性线电流 | `current_n` | —— | 随不平衡上升 |

> **不产出 `flicker_pinst`**：它是 IEC 61000-4-15 的内部中间量，
> 主流电表（PM8000 / PAC4200 / M4M / APView500）只输出 Pst / Plt。

### 异常场景：每天四个整点各打一类问题

**默认开启**，让电能质量分析页有东西可看。`--no-pq-anomaly` 关闭。

| 时刻 | 注入类型 | 打到什么程度 | 对应页签 |
| --- | --- | --- | --- |
| 00:00 | 电压暂降 + 不平衡 | A 相 −11%，不平衡 8~9.5% | 电压偏差 / 三相不平衡 |
| 02:00 | 频率偏低 | 49.58~49.72 | 频率偏差 |
| 06:00 | 谐波超标 | 电压 THD 6.5~9.2% | 谐波检测 |
| 19:00 | 闪变超标 | Pst 1.25~1.85，Plt 0.90~1.15 | 电压闪变 |

**为什么固定时段而不是随机**：随机值在趋势图上是噪点，看不出「哪段时间有问题」；
固定时段在按日/按周视图里是规整的异常块，一眼能定位到班次。

### RPC（远程控制）

可控设备在平台上有 `rpcCommands` 属性，记着它接受哪些指令。

| 设备 | 方法 | 参数 |
| --- | --- | --- |
| Relay-8CH（真实） | `setRelay` | `{"ch":1..8,"state":true}` |
| | `setGroupRelay` | `{"chs":[1,2,3],"state":true}` |
| | `setAllRelay` | `{"state":true}` |
| | `readMeterNow` | `{}` 立即抄表 |
| AHU-SIM | `setMode` | `{"mode":"auto/manual/off"}` |
| | `setFanSpeed` | `{"freq":0..50}` |
| Breaker-SIM | `setState` | `{"state":true/false}` |
| | `getState` | `{}` |

**从平台下发**：设备详情页 → **RPC** 面板 → 选方法、填参数。

```bash
curl -X POST "http://127.0.0.1:8090/api/rpc/oneway/<设备id>"   -H "X-Authorization: Bearer $TOKEN" -H 'Content-Type: application/json'   -d '{"method":"setRelay","params":{"ch":1,"state":true},"timeout":10000}'
```

> 真实设备的 RPC 由 RTU 执行；模拟设备由脚本记录（不改变实际状态）。

---

## 装完 RTU 之后：四条链路逐条验

按顺序，不要跳。前一条不通，后一条必然也不通。

| # | 链路 | 怎么验 | 不通说明 |
| --- | --- | --- | --- |
| 1 | 采集 | 设备详情「最新遥测」有数据 | 见上文「上报不通」 |
| 2 | 分析 | 实时/历史/分项三张报表都能出数 | 设备没挂场站 / 没标层级 |
| 3 | 评估 | 告警规则是「继承来的」（挂档案） | 挂错设备了，见 [⑥](/admin/rules) |
| 4 | 汇总 | 场站/分项资产有 `energy_total` | 没重算，见 [⑤](/admin/data-flow) |
