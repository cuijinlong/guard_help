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

一台 RTU 下面挂多块表时，有两种接法：

**接法 A：一表一设备（推荐）**

每块表在平台上建一台设备，各用各的 token。RTU 分主题发布：

```
v1/gateway/telemetry
{
  "表1的设备名": [{"energy": 1.2, "voltage_a": 220.1}],
  "表2的设备名": [{"energy": 3.4, "voltage_a": 219.8}]
}
```

网关自己用一台「网关」档案设备的 token 连接。

**接法 B：一表一 token（简单但不便管理）**

RTU 为每块表建一条 MQTT 连接。表多时连接数会爆，不推荐超过 20 块。

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

### 电表（46 个标准参数）

最常用的十几个：

| 字段 | 含义 | 单位 | 聚合 |
| --- | --- | --- | --- |
| `energy` | 本小时用电量（**增量**） | kWh | SUM |
| `energy_reading` | 正向有功总电度（**累积表底**） | kWh | MAX |
| `energy_day` | 当日累计 | kWh | MAX |
| `power_total` | 总有功功率 | kW | AVG |
| `power_a/b/c` | 分相有功功率 | kW | AVG |
| `voltage_a/b/c` | 分相电压 | V | AVG |
| `current_a/b/c` | 分相电流 | A | AVG |
| `power_factor_total` | 总功率因数 | — | AVG |
| `energy_peak` / `energy_flat` / `energy_valley` / `energy_deep` | 分时电量 | kWh | SUM |
| `frequency` | 频率 | Hz | AVG |
| `demand_max` | 最大需量 | kW | MAX |
| `load_rate` | 负载率 | % | AVG |
| `voltage_unbalance` | 电压不平衡度 | % | AVG |

完整 46 项在「能源参数字典」页面里看，或看[设备接入：上报哪些字段](/admin/device-access)。

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

**只写 A 相和 total：**

```json
{"energy":1.2,"energy_reading":33706.6,"power_a":1.2,"power_total":1.2,
 "voltage_a":220.5,"current_a":5.9,"power_factor_a":0.92,"power_factor_total":0.92}
```

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
