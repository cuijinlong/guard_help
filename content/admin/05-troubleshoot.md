# ⑤ 常见问题

> 按现象索引。每一条都是真实踩过的坑，给出**现象 → 定位命令 → 修法**。
>
> 先看这张表，能解决 80% 的问题：

| 现象 | 跳到 |
| --- | --- |
| 登录提示「用户名或密码错误」 | [第 0 节](#0-登录不进去) |
| 客户左侧菜单是 TB 原生的（设备/资产/实体视图） | [第 0 节](#0-登录不进去) |
| 客户看不到任何仪表板 | 第 5 节 |
| 报表有数但峰谷全是「平」 | 第 13 节 |
| 设备上报返回 404 | 第 14 节 |
| 磁盘满 | 第 10 节 |
| 服务起不来 | 第 9 节 |

## 0. 登录不进去

### 现象 A：提示「用户名或密码错误」（HTTP 401）

**先确认账号密码确实是什么。** 常见原因是重装平台时密码被覆盖 ——
`docker-98-rebuild.sh` 重装会重建库，用的是**它参数里的密码**，
不是上一次的。

**定位**：

```bash
for pair in "langmen@126.com:CJLqh@163" "tenant@126.com:12345678" "customer@126.com:12345678"; do
  user=${pair%%:*}; pass=${pair#*:}
  code=$(curl -s --noproxy '*' -m 8 -o /dev/null -w '%{http_code}' \
    -X POST http://127.0.0.1:8090/api/auth/login \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$user\",\"password\":\"$pass\"}")
  printf "%-24s %s\n" "$user" "$code"
done
```

`200` = 密码对；`401` = 密码错。

**修法一：用对的密码登录**（就是上面 200 的那个）。

**修法二：改密码**（知道旧密码时）：

```bash
TOK=$(curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"tenant@126.com","password":"旧密码"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/changePassword \
  -H "X-Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"currentPassword":"旧密码","newPassword":"新密码"}'
```

**修法三：忘了密码，直接重置**

```bash
# 生成一个新的 BCrypt 哈希（用容器里的工具，不用装额外软件）
cd ~/energy-app
docker compose exec -T energy-server sh -c \
  'echo -n "新密码" | sha256sum'   # 先确认能进容器

# 更直接：改数据库（BCrypt 哈希需要用工具生成）
docker compose exec -T postgres psql -U postgres -d thingsboard -c "
UPDATE user_credentials SET password = crypt('新密码', gen_salt('bf'))
WHERE user_id = (SELECT id FROM tb_user WHERE email='tenant@126.com');"
```

> 如果 `crypt` 函数不存在，装扩展：
> `CREATE EXTENSION IF NOT EXISTS pgcrypto;`
>
> 重置完立刻用新密码登录验证。

### 现象 A2：客户账号建好了，但激活链接点开是 `:80` / 打不开

**现象**：租户在「客户与用户 → 用户 → 新增」建了客户账号，选「显示激活链接」，
拿到的地址是 `http://127.0.0.1:80/api/noauth/activate?...` 或 `http://localhost:8080/...`，
客户点开 404 / 连接被拒。

**根因**（两层，都被修了）：

1. **nginx 没传 `X-Forwarded-Port`**。后端 `MiscUtils.getPort()` 的判断顺序是：
   ```
   ① 有 x-forwarded-port → 用它
   ② 否则只要有 x-forwarded-proto → http 硬编码 80，https 硬编码 443
   ③ 都没有 → request.getServerPort()
   ```
   nginx 必然要传 `X-Forwarded-Proto`（https 下取真实协议），于是掉进 ②，
   端口被强制写成 80。**只改 Host 头不管用**，必须显式传 `X-Forwarded-Port`。

2. `admin_settings.general.baseUrl` 还是 TB 出厂默认 `http://localhost:8080`。
   默认 `prohibitDifferentUrl=false` 时不读它，但一旦被打开或请求上下文为空
   （定时任务发邮件、报表），就会用它。

**定位**：

```bash
# 1) 看 nginx 是否传了端口
grep -n 'X-Forwarded-Port' ~/energy-app/nginx/energy.conf

# 2) 看后端配的对外地址
docker compose exec -T postgres psql -U postgres -d thingsboard -tAc "
SELECT json_value FROM admin_settings WHERE key='general';"
```

**修法**：

```bash
# 1) 确认 nginx 有这两行（新版本已内置）
#    map $http_host $forwarded_port { ... }
#    proxy_set_header X-Forwarded-Port $forwarded_port;
docker compose restart gateway

# 2) 把对外地址配成真实域名/IP（重跑 02 时加 --public-url 也行）
docker compose exec -T postgres psql -U postgres -d thingsboard -c "
UPDATE admin_settings
SET json_value = jsonb_set(json_value::jsonb,'{baseUrl}',
    to_jsonb('https://energy.example.com'::text))::text
WHERE key='general';"
```

**验证**：

```bash
# 取一台客户用户的激活链接，看端口/域名对不对
TOK=$(curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"tenant@126.com","password":"12345678"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

curl -s --noproxy '*' -H "X-Authorization: Bearer $TOK" \
  "http://127.0.0.1:8090/api/user/<用户id>/activationLink"
# 期望：http://<真实地址>:<真实端口>/api/noauth/activate?activateToken=...
```

> **注意 POST 与 GET 的区别**：`GET /api/noauth/activate` 从 **query** 读 token
> （浏览器打开链接走这条），`POST` 从 **body** 读（设密码时用）。
> 手工测试时把 token 放错位置会看到 `Incorrect activateToken null`，那不是 bug。

**没有邮件服务器怎么办**：内网离线部署本来就没有 SMTP。
新增用户时选「显示激活链接」而不是「发送激活邮件」，把链接直接发给客户。
邮箱配置在「运营配置 → 设置 → 邮件服务器」——**不配也能用**，只是不能自动发信。

### 现象 B：能登录，但页面白屏 / 转圈

**定位**（看浏览器控制台，或直接查资源）：

```bash
# 首页能不能拿到
curl -s --noproxy '*' -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8090/

# 主 JS 能不能拿到
CH=$(curl -s --noproxy '*' http://127.0.0.1:8090/ | grep -o 'main-[A-Z0-9]*\.js')
curl -s --noproxy '*' -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:8090/$CH"
```

两个都 `200` 但页面白 → 前端构建产物有问题，重新构建：

```bash
cd /你的路径/iot-rule-engine/ui-ngx
node --max_old_space_size=8192 ./node_modules/@angular/cli/bin/ng build --configuration production
```

然后重新打包部署（见[② 平台部署](/admin/deploy)）。

### 现象 C：客户登录后左侧是 TB 原生菜单

不是设备/资产/实体视图那套，而是应该有「能耗查询 / 能耗优化 / 设备运维 / 组织」。

**修法**：

```bash
cd ~/energy-app
bash scripts/07-init-menu.sh \
  --tenant tenant@126.com --tenant-pass '12345678' \
  --customer customer@126.com --customer-pass '12345678'
```

**根因**：客户菜单是「每个客户一份」的自定义菜单，建客户时自动装。
手工删过、或老客户升级上来没有，就要补装。

**注意**：脚本必须用**客户账号**操作。用租户账号建出来的
`customer_id` 是 NULL，直接违反 NOT NULL 约束，菜单根本建不出来。

### 现象 D：右侧大面积「加载部件配置时出现问题。关联的 部件类型可能已被移除。」

**根因**：看板里写的 `typeFullFqn` 前缀与部件的实际归属不一致。

| 部件建在 | 必须用的前缀 |
| --- | --- |
| 系统租户 NULL_UUID | `system.` |
| 某个租户下 | `tenant.` |

本平台的部件全部建在**系统租户**下，所以看板模板必须写
`system.energy_management.*`。曾经错写成 `tenant.` 导致客户侧所有看板都报错。

**定位**：

```bash
cd ~/energy-app
docker compose exec -T postgres psql -U postgres -d thingsboard -tA -c "
SELECT tenant_id, count(*) FROM widget_type
WHERE fqn LIKE 'energy_management.%' GROUP BY tenant_id;"
```

`13814000-1dd2-11b2-8080-808080808080` = 系统级 → 模板必须用 `system.`

**逐个验能不能加载**（把 fqn 换成看板里实际用的）：

```bash
CTOK=$(curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"customer@126.com","password":"12345678"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

curl -s --noproxy '*' -o /dev/null -w 'HTTP %{http_code}\n' \
  -H "X-Authorization: Bearer $CTOK" \
  'http://127.0.0.1:8090/api/widgetType?fqn=system.energy_management.analysis_bar'
```

`200` = 能加载；`400 Invalid fqn` = 前缀格式错；`500` = 前缀对但库里没有。

**修法**：模板已修正。重新部署即可：

```bash
bash shiyongshouce/downloads/deploy/docker-98-rebuild.sh ... --yes
```

### 现象 E：客户登录后落在空白的门户页

**根因**：`customer.additionalInfo.homeDashboardId` 没设。

**定位**：

```bash
docker compose exec -T postgres psql -U postgres -d thingsboard -tA -c "
SELECT title, additional_info FROM customer;"
```

没有 `homeDashboardId` 就是没设。

**修法**：

```bash
bash scripts/07-init-menu.sh \
  --tenant tenant@126.com --tenant-pass '12345678' \
  --customer customer@126.com --customer-pass '12345678'
```

它会同时补 `customerMenuId` 和 `homeDashboardId`。

### 现象 F：运营配置（Platform）里没有能源配置项

**定位**：

```bash
docker compose exec -T postgres psql -U postgres -d thingsboard -tA -c "
SELECT name, scope FROM custom_menu ORDER BY scope;"
```

应有「默认导航（能源管理）」(TENANT) 和「业务导航（能源管理）」(CUSTOMER) 两条。
租户那条的 `length(config) > 100` 才算真装了 —— 平台自带的 `Tenant default menu`
是 `{"items":[]}`（12 字节），用它计数会误判。

**修法**：两条都是租户/客户创建时自动装的。缺了就点**平台自检 → 一键修复初始化**，
不用重建租户（10–30 秒，幂等）。命令行等价：

```bash
curl -s --noproxy '*' -X POST -H "X-Authorization: Bearer $TOK" \
  http://127.0.0.1:8090/api/energy/repair-init
```


### 现象 G：租户菜单只剩几项，TB 原生菜单像是被删了

**现象**：左侧只剩 首页 和少数几项，实体、客户与用户、资源、安全这些
TOGGLE 型菜单整块消失（正常情况下应该是 11 项）。

**先确认数据没坏**：

```bash
TOK=$(curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"tenant@126.com","password":"12345678"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

curl -s --noproxy '*' -H "X-Authorization: Bearer $TOK" \
  http://127.0.0.1:8090/api/customMenu \
  | python3 -c "import json,sys; print('顶层项数:', len(json.load(sys.stdin)['items']))"
```

- 输出 **11** → 数据完好，是**前端**渲染问题：旧版前端遇到「toggle 型顶层项但没有 pages」会整项丢弃。换新前端即恢复，**不用重装、不用重跑初始化**。
- 输出 **小于 11** → 菜单确实是旧版装的（缺落地页或缺运营配置），点**平台自检 → 一键修复初始化**重装。

> **2026-10-22 起：启动不再重建菜单。**
> 之前每次重启都会删掉租户/客户菜单再按模板重装，导致「改一次菜单，重启就白改」。
> 现在：
> - 服务启动 → 菜单已存在就**跳过**（保留你调的顺序、加的项、隐藏的项）
> - `平台自检 → 一键修复初始化` → 只修**结构损坏**的菜单（缺落地页 / 缺运营配置），
>   结构完整的**一律不动**
> - 想彻底恢复成模板：先删掉这条菜单，再跑一次一键修复
>
> 代价：以后新增的菜单项不会自动出现在老租户上。需要的话在界面上自己加，
> 或按上面的办法重建。

详见[③ 数据初始化](/admin/init)「一之五」。


### 现象 H：看板里图表全空，控制台刷 404（`00000000-…` 开头的 id）

**现象**：Network 里出现

```
GET /api/relations?fromId=00000000-0000-0000-0000-0000000005a1&fromType=ASSET...  → 404
GET /api/asset/00000000-0000-0000-0000-00000000d101                              → 404
```

**原因**：看板模板里的实体引用是占位符，复制给客户时应替换成真实 id。
旧版本替换函数判断写错，**从未真正执行**，占位符原样留在客户看板里。

**确认**：

```bash
docker compose exec -T postgres psql -U postgres -d thingsboard -tAc \
  "SELECT count(*) FROM dashboard WHERE configuration LIKE '%00000000-0000-0000-0000-00000000%';"
```

大于 0 就是。

**修法**：这是数据里的旧副本，只能重新复制 ——
重装平台（`docker-98-rebuild.sh`）或在仪表板页把客户看板重新复制一份。
新版后端已修，重装后该计数应为 0。


### 现象 H2：点某个菜单项进去，又「弹回」能源概览

**现象**：点「实时能耗」「历史能耗」「设备管理」「平台自检」等菜单，地址栏一变就回到
`/home`（能耗概览），控制台只有一条 404，页面上没有任何提示。

**原因**：前端把**未注册的路径**交给 `**` 通配路由，它的行为就是 `redirectTo: 'home'`。
两种成因，都不会报错：

| 成因 | 特征 |
| --- | --- |
| 菜单里的 `dashboardId` 指向已删除 / 未分配给该客户的看板 | 重置演示数据、销户重建、或换掉看板后菜单没重绑 |
| 菜单里的站内 URL 在**部署的前端产物**里没有对应路由 | 换了菜单但没重打 ui-ngx jar |

**定位（一条命令）**：

```bash
cd ~/energy-app && bash scripts/08-verify-release.sh \
  --tenant tenant@126.com --tenant-pass '12345678' \
  --customer customer@126.com --customer-pass '12345678' \
  | grep -E "菜单里的看板|ngxai 子应用|失效看板"
```

- 「菜单里的看板全部可打开（失效 0 个）」—— 这一项失败会直接列出 **哪一项、哪个 id、HTTP 几**
- 「菜单里的 /ngxai 子应用入口可达」—— 失败说明 `ngxai-dist` 没挂到 nginx

**修法**：

```bash
# ① 看板被删 / 未分配：重装客户菜单并重绑看板
#    客户列表 → 该客户 → 「一键修复初始化」
#    或在部署目录：
curl --noproxy '*' -s -X POST -H "X-Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"customerId":"<客户id>"}' \
  http://127.0.0.1:8090/api/energy/repair-init

# ② 路由没进前端产物：按「改代码后怎么更新 → 只改了前端」五步重发
```

> 新版（2026-10-24 起）：看板真取不到时页面会直接写「这个看板不存在或已被删除，
> 请联系管理员重新分配菜单」，不再白屏。

**为什么以前没被发现**：旧验收只查「菜单项名字在」，不查「点进去能不能打开」。
现在 `08-verify-release.sh` 的 F 段会逐条请求菜单里的每个 dashboardId，
并在 G 段核对页面组件是否真的打进了前端产物 —— 重装后跑一遍就知道。

### 现象 H3：RTU 连上了，设备页显示"已上报"，但曲线全空

**现象**：真实 RTU / 网关接上后，`docker logs` 里能看到 MQTT 连接，
设备详情页的"最新遥测"里出现一个叫 **`values`** 的键，值是
`{"U":228.0,"Freq":49.94,"Ep":8.36,...}` 这样一整串 JSON 字符串；
而电压、电流、电量曲线全部为空。控制台/后端**没有任何报错**。

**根因**：网关遥测报文漏了 `ts`。正确格式是

```json
{"设备名": [{"ts": 1792829233716, "values": {"U": 228.0}}]}
```

少了 `ts` 时平台不报错，而是把整个 `values` 对象当成一个普通遥测键存进去。

**定位**：

```bash
# 看这个键在不在，以及它的值
docker compose exec -T postgres psql -U postgres -d thingsboard -tAc "
SELECT d.name FROM device d
  JOIN ts_kv v ON v.entity_id = d.id
  JOIN key_dictionary k ON k.key_id = v.key
 WHERE k.key = 'values';"
```

**修法**（两条都建议做）：

1. **升级固件**：新版 `rtu/main.py` 已强制带 `ts`，并且时间不可信时宁可不报
   （不会把数据写到 1970 年）。重烧后 `values` 键不再产生。
2. **平台侧兜底**：规则链「电表Key标准化」节点已内置兼容 —— 见到 `values`
   是 JSON 字符串就拆开再映射，旧固件也能正常出数。部署新版后端即生效。

**为什么曲线还是空的**：历史 `values` 点不会自动回填成标准键，
需要设备用正确格式重新上报（或重烧后自然覆盖）。

### 现象 H4：RTU 连接被接受，但消息全被丢弃

**现象**：CONNECT 成功（CONNACK 返回码 0），PUBLISH 也不报错，
但设备一条数据都没有。日志里反复出现：

```
ERROR MqttTransportHandler - [gatewaySessionHandler] is null, [xxx] Failed to process publish msg [v1/gateway/connect][-1]
```

**根因**：网关设备的 `additional_info` 里缺 `"gateway": true`。
平台只认这个字段，**不认**「设备档案 = 网关」。

**定位**：

```bash
docker compose exec -T postgres psql -U postgres -d thingsboard -tAc \
  "SELECT name, additional_info FROM device WHERE name='ED1-Gateway';"
# 缺 gateway 的会显示 {"siteId":"...","rtuDemo":true}
```

**修法**：

```bash
cd ~/energy-app
python3 scripts/21-rtu-onboard.py \
  --base http://127.0.0.1:8090 \
  --tenant tenant@126.com --tenant-pass '12345678' \
  --customer 星河工业园
```

脚本会补上 `gateway: true`（幂等，已正确时不动）。

### 现象 H5：客户账号点某个按钮，弹出「您没有权限执行此操作！」

**现象**：客户登录后点「一键修复初始化」或某个「去修复」，弹出权限错误；
或者点完直接跳到一个整页写着「您没有权限访问此位置！」的页面。

**根因**：前端对客户显示了**管理端才有的操作**。后端权限是对的，前端漏了判断。
2026-10-24 修掉了三处：

| 位置 | 原来的行为 | 修法 |
| --- | --- | --- |
| 平台自检 → 「一键修复初始化」 | 客户可点 → 403（`repair-init` 仅管理员） | 按 `isCustomerUser` 隐藏，改为提示「请联系管理员补装」 |
| 平台自检 → 每项的「去修复」 | 客户可点 → 跳到 `/profiles/*`、`/vendor-model`、`/custom-menu` 等租户专属页 → **整页权限报错** | 客户一律不显示 |
| 「去修复」的跳转表 | `/asset-profile`、`/device-profile` 这两个路径**不存在** → 命中 `**` 通配 → 跳回能耗概览（看起来像按钮没反应） | 改成真实路由 `/profiles/assetProfiles`、`/profiles/deviceProfiles` |

**定位**（一条命令，用客户账号跑）：

```bash
cd ~/energy-app && python3 - <<'EOF'
import json,urllib.request,urllib.error
T=json.load(urllib.request.urlopen(urllib.request.Request(
  'http://127.0.0.1:8090/api/auth/login',
  data=json.dumps({'username':'demo@126.com','password':'demo123456'}).encode(),
  headers={'Content-Type':'application/json'})))['token']
for m,p in [('POST','/api/energy/repair-init'),('POST','/api/energy/demo-data')]:
    r=urllib.request.Request('http://127.0.0.1:8090'+p,data=b'{}',method=m,
        headers={'Content-Type':'application/json','X-Authorization':'Bearer '+T})
    try: urllib.request.urlopen(r); print(m,p,'→ 可调（不该给客户）')
    except urllib.error.HTTPError as e: print(m,p,'→',e.code)
EOF
```

返回 403 的就是客户**不该看到**的入口；只要页面上还有按钮能触发它，就是前端漏判。

**修法**：按 `!isCustomerUser` 隐藏该按钮，并给客户一句「请联系管理员」——
客户需要的是下一步，而不是一句没头没尾的权限报错。

> **为什么这类问题必须优先修**：演示现场客户点一下就看到「没有权限」，
> 会认为**整个平台**都没给他权限，而不是「这个按钮不该给你」。第一印象很难挽回。
>
> **排查这类问题不要直接调有副作用的写接口试权限**。`DELETE /api/energy/demo-data`
> 这类端点对客户是**合法可用**的（设计上允许客户清自己的演示数据），
> 用客户 token 试一下就会真的把数据删光（本手册作者 2026-10-24 就这样误删过一次）。
> 判断权限只看 403/200 时，先选**幂等的读接口**或带 `?dryRun=true` 的形式。

### 现象 H6：清除演示数据后，「我的账单」里还有账单，但每行点开都是空的

**现象**：客户点「清除演示数据」→ 设备列表空了，但账单页仍有十几张账单，
每一行都指向已经不存在的表计。

**根因**：账单资产（`type=energy_bill`）的 `additional_info` 是 null，**不带 `demo` 标记**，
所以 `deleteDemoData` 的主循环不会删它们 —— 留下孤儿账单（实测清一次留 19 个）。

**定位**：

```bash
docker compose exec -T postgres psql -U postgres -d thingsboard -tAc "
SELECT count(*) AS orphan FROM asset a
 WHERE a.type='energy_bill'
   AND NOT EXISTS (SELECT 1 FROM device d WHERE d.id::text = a.name);"
```

**修法**：新版 `deleteDemoData` 会在删完设备后，扫描该客户的账单资产，
读其 SERVER_SCOPE `deviceId` 属性 —— 设备已不存在就删账单，设备还在就保留
（真实表计的账单不会被误伤）。重装/重启后端即生效。

存量孤儿可以用接口逐个清（读 `deviceId` 属性判断，见本文档的运维 SQL 章节）。

### 现象 I：客户看板持续刷 403 + 404（同一个 id），几秒或一分钟一次

**现象**：客户登录后，首页 Network 里反复出现**同一个 id**的两种请求：

```
GET /api/asset/9f9af670-...   403
GET /api/device/9f9af670-...  404
```

间隔可能是 3 秒（部件无限重试）或 60 秒（页面定时刷新）。
`Referer` 是 `/home`。

**这和现象 H 正好相反**：

| | 现象 H | 现象 I |
| --- | --- | --- |
| 问题 | 占位符**没被**替换 | 替换**过头**了 |
| 请求的 id | `00000000-…` 开头的占位符 | 真实 id，但属于**租户级**实体 |
| 状态码 | 404 | asset 403 / device 404 |

**原因**：客户看板里存了**租户级资产**的 id。
客户用户无权读租户级实体（`customer_id` = `NULL_UUID`），所以 403；
前端失败后回退去试设备，但不是设备，所以 404。

典型是「能源参数字典」「电能品种节点」这两个 —— 它们是租户级主数据，
客户共用但不能直接读。

**为什么部件会一直重试**：品种选项取不到 → `sources` 为空 →
部件设了 `retryTimer`（3 秒）等它。看起来就是「一直在报」。

**确认**（分类 config JSON 里所有 UUID）：

```bash
cd ~/energy-app
docker compose exec -T postgres psql -U postgres -d thingsboard -tAc "
WITH ta AS (
  SELECT id FROM asset WHERE customer_id = '13814000-1dd2-11b2-8080-808080808080'
)
SELECT c.title, d.title, a.id
FROM dashboard d
JOIN customer c ON c.id = d.customer_id,
     asset a
WHERE a.id IN (SELECT id FROM ta)
  AND d.configuration LIKE '%'||a.id||'%';"
```

有任何一行 → 就是这个问题。期望 **0 行**。

**修法一（推荐）：点「平台自检 → 一键修复初始化」**

不用写 SQL、不用懂原理。`repair-init` 会自动：

1. 找出所有租户级资产的 id
2. 扫描每个客户的看板 config
3. 把落在里面的租户级 id 换回占位符

返回里看 `tenantAssetLeaksFixed` 这个数（修好的看板数）：

```bash
TOK=$(curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"tenant@126.com","password":"12345678"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

curl -s --noproxy '*' -X POST -H "X-Authorization: Bearer $TOK" \
  http://127.0.0.1:8090/api/energy/repair-init
# {"dashboardsFixed":0,"tenantAssetLeaksFixed":10,...}
```

**平台自检里也能先看到问题**（新增检查项 `customer.dashboard-tenant-leaks`）：

```
customer.dashboard-tenant-leaks   看板无租户级资产引用   实际 10 / 期望 0 处   ✗
                ↓ 点一键修复
                                  实际 0 / 期望 0 处     ✓
```

> 新版复制逻辑也已修好（`buildDashboardPlaceholders` 不再替换字典与电能品种），
> 所以**新开的客户不会再出现**；一键修复负责治存量。

**修法二（手工改数据，仅在无法调接口时用）**：

```sql
-- 先把租户级资产的 id 找出来
SELECT id, name FROM asset
WHERE customer_id = '13814000-1dd2-11b2-8080-808080808080'
  AND name IN ('能源参数字典');

-- 把客户看板里的这些 id 换回占位符
UPDATE dashboard
SET configuration = replace(configuration,
      '<上面查到的id>',
      '00000000-0000-0000-0000-0000000011b7')
WHERE customer_id IS NOT NULL
  AND configuration LIKE '%<上面查到的id>%';
```

**⚠ 修完必须让用户强制刷新浏览器**（`Cmd+Shift+R` / `Ctrl+Shift+R`）。
数据库改了，但**已经打开的页面内存里还是旧配置**，会继续重试。
表现是「间隔从 3 秒变成 60 秒但没消失」—— 改数据前就已经打开的页面不会自动重新拉取。

这一点对「一键修复」同样成立：**修复是改服务端数据，不会推送到已打开的页面。**

**验证刷新后确实没事**：用客户 token 逐个解析全部看板的别名，
真实 id 都应当 200，占位符应当跳过，失败数应为 0。完整脚本见
知识库 `05-踩坑清单.md` 第十四节。

**顺便记住 config JSON 里的 id 分三类**（不是「有 id 就有问题」）：

| 类别 | 正常吗 | 说明 |
| --- | --- | --- |
| 占位符 `00000000-…` | ✓ | 前端当「上下文实体」哨兵，**不发请求** |
| 客户自有实体 id | ✓ | 客户有权读 |
| 配置内部 id（部件/别名自身） | ✓ | 不是实体引用 |
| **租户级 / 别家客户实体 id** | ✗ | **只有这类要修** |

> 设计原则：**能从 API 拿的数据，不要通过实体别名拿。**
> 实体别名受用户权限约束，API 只要接口放行就不受。

---

### 现象 I-2：客户页面部件 403，但看板 config 里查不到租户级 id

**和现象 I 的区别**：现象 I 是**配置泄漏**（看板 JSON 里存了租户级 id）；
这一条是**代码运行时**才拿到租户级 id —— config 里干干净净，查不出来。

**现象**：客户登录后某些图表空着，Network 里是这些请求：

```
GET /api/plugins/telemetry/ASSET/<品种id>/values/attributes/SERVER_SCOPE?keys=paramDict   403
GET /api/relations?fromId=<品种id>&fromType=ASSET&relationType=Contains                    403
```

报错文本会点名实体：

```json
{"message":"You don't have permission to perform 'READ_ATTRIBUTES' operation with ASSET '电能'!"}
```

**先确认这批 id 是谁**（十有八九是租户级主数据）：

```sql
SELECT a.name, a.type, a.customer_id,
       CASE WHEN a.customer_id IS NULL OR a.customer_id='13814000-1dd2-11b2-8080-808080808080'
            THEN '租户级 → 客户必然 403' ELSE '客户级' END AS 归属
FROM asset a WHERE a.id = '<报错里的 id>';
```

**根因链**（实测 2026-10-23）：

```
① 看板部件启动
      ↓
② GET /api/energy/metric-params        ← 客户版接口，200，正常
      ↓  返回 kinds[{id: 租户级品种资产 id, name:'电能', params:[...]}]
③ 旧版部件不直接用 params，而是拿 kinds[].id 去读那个资产的属性
      ↓
④ GET /api/plugins/telemetry/ASSET/<租户级id>/values/attributes/SERVER_SCOPE
      ↓  客户无权读租户级资产 → 403
⑤ 部件拿不到 paramDict → 参数下拉为空 / 图表不渲染
```

**哪些部件会这样**（`controllerScript` 里搜 `values/attributes/SERVER_SCOPE`）：

```
overview_stats          calendar_heatmap     realtime_kpi
realtime_trend          ranking_list         asset_stats_chart
distribution_chart      query_panel（已升级走 metric-params，仅回退路径会）
```

> `query_panel` 已优先用 `metric-params` 下发的 `params`，只有接口不可用时才回退。
> 其余 7 个仍是「拿 id 读属性」，所以客户打开就 403。

**修法（代码级，`repair-init` 修不了）**

权限层放行「租户级公共主数据资产」的**只读**：

```java
// CustomerUserPermissions#isTenantLevelPublicAsset
// 白名单：energy_type_library / default / rate_template / tou_scheme
// 条件：customerId 为 null 或 NULL_UUID（租户级）
```

三个容易踩错的点：

| 坑 | 正确写法 | 后果 |
| --- | --- | --- |
| 以为 `getOwnerId()` 能判租户级 | 用 `getCustomerId().isNullUid()` | `Asset.getOwnerId()` 对租户级返回的是 **tenantId**，比 `NULL_UUID` 永远 false |
| 只放行 `Operation.READ` | 还要放行 `READ_ATTRIBUTES` / `READ_TELEMETRY` | 属性接口用的是 `READ_ATTRIBUTES`，只放 READ 仍然 403 |
| 只改默认权限集 | 存量库要跑 `repair-init` | 客户角色是**租户级共享的一条**（`customer_id = NULL_UUID`），`findOrCreateCustomerUserRole` 发现存在就不更新权限 |

**验证：跑客户视角探针**

```bash
cd ~/energy-app
python3 scripts/27-customer-surface-probe.py   --base http://127.0.0.1:8090   --tenant tenant@126.com --tenant-pass '12345678'   --customer customer@126.com --customer-pass '12345678' --strict

# 期望：失败 0 条，退出码 0
```

这个探针会以客户身份打 **295 条**请求：自有资产/设备/看板的全部属性与关系、
看板引用的非自有实体、`metric-params` 下发的品种 id……任何 4xx 都会列出来。

> **为什么必须有这一层**：普通的 API 验收只调「我们认为重要」的接口，
> 而客户打开页面时是**部件**在发请求。部件会去读租户级主数据 ——
> 这类 403 在 API 级断言里永远看不见。实测：74 项验收全绿的同时，
> 客户打开看板有 22 条 403。

---

### 现象 J：RTU 上报成功（HTTP 200），但报表全空；库里只有 `U` / `I` / `P`

**先看一眼库里存的到底是什么**：

```bash
# 最近 2 分钟有哪些 key（按写入时间倒序）
docker exec energy-postgres psql -U postgres -d thingsboard -At -F' | ' -c "
select k.key, to_char(to_timestamp(max(v.ts)/1000),'HH24:MI:SS'), max(v.dbl_v)
from ts_kv v join key_dictionary k on k.key_id=v.key
where v.ts > (extract(epoch from now())*1000 - 120000)::bigint
group by k.key order by 2 desc;"
```

- 看到 `voltage_a` / `current_a` / `power_total` → 正常
- 看到 `U` / `I` / `P` / `Ep` → **电表 Key 标准化节点没生效**，报表按标准名取数自然全空

**两个原因，按顺序查**：

1. **节点根本没装**（新装 / 重装 / 新租户）

   ```bash
   curl --noproxy '*' -s -X POST \
     -H "X-Authorization: Bearer $TOKEN" \
     http://127.0.0.1:8090/api/energy/repair-init | jq '.meterKeyTransformFixed'
   ```

   返回 `true` = 刚补装，再上报一次验证；返回 `false` 说明节点在，看第 2 条。

2. **节点在，但脚本写错了**（历史手工配置常见）

   日志或 `ruleEngineException` 里如果出现：

   ```
   Can't parse value: "{\"U\":232.9,...}"
   ```

   说明脚本里多写了一次 `JSON.stringify(...)`，返回值被双重编码。
   同样，脚本里多写 `JSON.parse(msg)` 会抛异常 → 走 `catch` 原样返回 → 数据不转换。

   原因和正确写法见手册 **③ 数据初始化 → 五之二、电表 Key 标准化节点**；
   执行一次 `repair-init` 会自动把脚本刷成平台标准版本。

**为什么这种故障难发现**：上报接口是 fire-and-forget，消息处理失败也返回 `200`；
节点缺失也不影响服务启动。唯一的早期信号就是「报表没数」。

---

### 现象 K：抄表能跑，但台账用量是 0 / 账单金额是空的

**先看是哪种 0**：

```bash
curl --noproxy '*' -s -H "X-Authorization: Bearer $TOKEN" \
  "$BASE/api/energy/meter-reading/ledger?period=2026-10" \
  | jq '.items[] | {deviceName, usage, lastUsage, periodOpen, periodClose}'
```

| 看到什么 | 含义 | 怎么办 |
| --- | --- | --- |
| `usage: null`，`periodOpen: null` | 本月只有一次抄表（首抄建基线）| 等下一次抄表；不是故障 |
| `usage: null`，`periodClose` 有值 | 表底倒走或读不到表底 | 查现场表计/倍率 |
| `usage: 0` 但 `periodOpen == periodClose` | 本月确实没新增用电 | 正常 |
| 设备全部 `quality: estimated`、`reason` 含「数据陈旧」 | 遥测超过 10 分钟没更新 | 看下一条 |

**「数据陈旧」是抄表最常见的空数原因**

抄表要的是「此刻的读数」，不是「最后一次读到的数」。设备超过
`STALE_WINDOW_MS = 10 分钟` 没上报，一律判 `stale` 而不拿旧值充数。

- 真实设备：查网关在线、看 `/api/noauth/energy/health`、重启 RTU
- 演示环境 / 没有硬件：用模拟器持续上报

```bash
./scripts/20-rtu-simulator.py --base http://127.0.0.1:8090 \
    --tenant tenant@126.com --tenant-pass '12345678' \
    --device '单相园-1#进线总表' --interval 60 --count 0
```

**如果 usage 明显小于实际用电**（例如本月用了 94 kWh，台账只报 0.313）

那是旧版本的「取最后一次增量」口径。正确口径是「账期累计」：
账期用量 = 期末表底 − 期初表底。升级后 `usage` 就是累计值，
`lastUsage` 保留本次增量。详见手册 **③ 九之二、抄表的用量口径**。

---

### 现象 L：接口返回 500「Required request parameter ... is not present」

**这是调用方少传了参数，不是服务端故障。** 正确状态码应该是 `400` +
`errorCode=31`（`BAD_REQUEST_PARAMS`）。

如果看到的是 `500` / `errorCode=2`（`GENERAL`），说明异常处理器把它当成了
服务端错误 —— 后果是前端去查数据库日志、监控把参数错误计入 5xx 告警。

修复后应该是：

```bash
curl --noproxy '*' -s -o /dev/null -w '%{http_code}\n' \
  -H "X-Authorization: Bearer $TOKEN" "$BASE/api/energy/tou-analysis"
# 期望 400
```

代码位置：`ThingsboardErrorResponseHandler.handle` —— 参数类异常要在兑底分支里
提前分流。**不要**用 `@ExceptionHandler` 单独声明这两个异常：父类
`ResponseEntityExceptionHandler` 已经注册过，再写一遍会让 Spring 启动时抛
`Ambiguous @ExceptionHandler method mapped for ...`，服务直接起不来。

---

### 现象 M：把设备/资产分配给客户后，对方看不到

**先分清是哪种「看不到」**：

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 列表里没有 | 分配接口 404 / 没调成功 | 看下一段 |
| 列表里有、点开 403 | 权限缓存没失效 | 见「缓存」段 |
| 列表里有、点开 404 | 分配到了别的租户 | 查 `customer_id` |

**列表里没有** —— 分配接口本身可能不存在（迁移遗漏）。

```bash
# 应返回 200 + 设备 JSON；404 说明接口缺失
curl --noproxy '*' -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H "X-Authorization: Bearer $TENANT_TOKEN" \
  "$BASE/api/customer/$CUSTOMER_ID/device/$DEVICE_ID"
```

**点开 403** —— 归属改了但 `ENTITY_OWNERS_CACHE` 没失效。

正确实现必须走 `ownersCacheService.changeEntityOwner(...)`（它内部改组 + 清缓存），
而不是只 `device.setCustomerId(...)` + `saveDevice`。后者会让已登录会话继续用旧的
owner 判断 —— 表现为「分配成功、对方 403、重启服务才恢复」。

**取消分配是还给租户，不是还给原客户**：

```bash
DELETE /api/customer/device/{id}   → customer_id = NULL_UUID（租户所有）
```

要让原客户重新看到，得再 `POST /api/customer/{原客户}/device/{id}`。
测试时容易踩：把客户资产「取消分配」后，它变成租户级，
客户看板里引用它的地方全 403，自检报「看板无租户级资产引用 9 处」。

---

### 现象 N：峰谷分析的数和台账对不上

**九成是边界没对齐整点。**

峰谷按小时聚合，只统计「终点落在 `(from, to]` 内」的增量。
传整点区间时，结果与「末点表底 − 首点表底」**分毫不差**：

```bash
# 对，总量 == 表底首末差
/api/energy/tou-analysis?deviceId=X&from=1791547200000&to=1791561600000   # 10-09 00:00 ~ 10-10 00:00

# 也会差一点（首尾各一小时不能整除）—— 正常，不是 bug
/api/energy/tou-analysis?deviceId=X&from=<now-13d>&to=<now-1h>
```

**如果差得离谱**（几十倍），看响应里的 `backwardDevices`：

```json
{ "backwardDevices": 1, "backwardSegments": 1,
  "warnings": ["1 台表计出现表底倒走…"] }
```

表底倒走（换表 / 归零 / 上报错值）的段被跳过了，这个月的数不能用，先核对表底。

**如果台账有数、峰谷是 0**：区间太短（< 1 小时）。两次抄表间隔几十秒时，
小时聚合只有 1 个点，算不出差值。这不是故障，见手册 ③ 九之三。

---

### 现象 O-1：升级后报 `resource sql/schema-views.sql not found`

**整个系统补丁步骤会失败**，部件更新、视图刷新都不会生效。

```
ERROR SystemPatchApplier - Failed to apply system data patch updates
java.lang.IllegalArgumentException: resource sql/schema-views.sql not found
```

原因：`guard-server` 是自带 DAO 源码的单体，不依赖 `dao` 模块，
所以 `dao/src/main/resources/sql/` 不会自动进 jar；而升级补丁要读
`sql/schema-views.sql` 与 `sql/schema-functions.sql`。

修复：

```bash
cp dao/src/main/resources/sql/*.sql guard-server/src/main/resources/sql/
cd guard-server && mvn package -DskipTests
```

`docker-97-preflight.sh` 第 3c-2 节会检查 jar 里有没有这两个文件，发版前跑一次。

---

### 现象 O：账单出不来 / 金额是 0 / 账单数比表少

**先看返回里的 `reason`** —— 出账接口对每台表都会说明为什么没出：

```bash
curl ... -d '{"period":"2026-10","dryRun":true}' /api/energy/billing/generate \
  | jq '.items[] | select(.usable==false) | {deviceName, reason}'
```

四种最常见的原因：

| reason | 原因 | 处理 |
| --- | --- | --- |
| 设备档案未声明 energyTypeCode | 档案没绑定能源品种 | 设备档案 → 编辑 → 能源品种 |
| 未配置「elec」的电价 | 三级费率都没配 | 场站/组织/客户任一处配价 |
| 设备未归属任何客户 | 账单要开给客户 | 把设备分配给客户 |
| 本账期读数不足两点 | 新接入或设备离线 | 等上报；或用 20-rtu-simulator.py |
| 本账期读数不足两点（**虚拟表**） | 判定读错位置，被当成实表；或该月未填报 | 确认 `device.additionalInfo.deviceVirtual`；到「手工填报」页录入该月值 |

**账单数比表少很多（例如 17 台只剩 4 张）** → 账单号重复，后一张覆盖前一张。
账单号必须带表码：`BILL-<客户码>-<账期>-<品种>-<表码>`。

```bash
# 查有没有重名（正常应为 0）
curl ... "/api/energy/billing/summary?period=2026-10" | jq '.items[].billingNo' | sort | uniq -d
```

**金额是 0**：

- 电度费 0 → 单价没配到该品种，或 `fixedPrice` 写成了 `prices.flat`（错误结构）
- 只有基本电费 → 该表没用量（表底没变或读数不足）

**虚拟表（手工填报）出不来** → 先看 dry-run 里的 `usageSource`：

- `manual` 且 `usable=true`：正常，用量来自该月 1 日 00:00 的填报值；
- `manual` 且 `usable=false`：该月没填报，去「手工填报」页录入；
- `telemetry`：判定错了 —— 虚拟标记必须在 `device.additionalInfo.deviceVirtual`，
  不在 SERVER_SCOPE 属性里。平台只认 `MeteringMath.isVirtual`，不要再各写一份。

虚拟表如果是时段制（tou），账单会带 `touAssumedFlat=true`：整月归「平」档。
这是估算口径，不是漏数。

**台账里看不到虚拟表** → 台账主体来自抄表记录，虚拟表没有抄表行，
由 `appendVirtualRows` 补进来。缺了说明该版本未包含这段（对着 08 验收脚本看
「台账包含虚拟表行」这一项）。

**基本电费被重复收了很多次** → 检查 `meterLevel`。
基本电费/力调电费只计入线总表（`meterLevel=1`）。
如果所有表都被打了 level 1，就会出现 11 × 1600 元这种账单。

```bash
docker exec energy-postgres psql -U postgres -d thingsboard -At -F' | ' -c "
select d.name, coalesce(a.dbl_v::text,a.str_v) lvl
from device d left join attribute_kv a on a.entity_id=d.id
left join key_dictionary k on k.key_id=a.attribute_key and k.key='meterLevel'
where d.name like '%进线%' or d.name like '%分项%' order by lvl;"
```

**已经付款的账单被重算改了** → 不应该发生。
受保护的账单状态是 `paid` / `void`，重算返回 `action=skipped-paid` 并保留全部字段。
若发现被改，检查 `EnergyBillingService.upsertBill` 是否还在用 `readAttrJson` 读状态
（status 是字符串属性，必须用 `attributesOf`）。

---

### 现象 X：切换场站后左侧设备树不更新、右侧图表也不动

**只有带实时刷新的看板会出现**（实时能耗最明显）；历史能耗切场站是好的。

**原因：浏览器连接池被实时轮询占满，重建树的请求排在最后。**

实时部件一轮刷新 = 每台设备一个 telemetry 请求。`refreshSecs` 配成 3 秒时，
两个实时部件 × 6 台设备 = 每 3 秒 12 个请求；浏览器对同一域名只有 6 条连接，
切场站后重建树的 `GET /api/customer/{id}/devices` 被压在最底下。
实测排队 15.4 秒（同一条 URL 在页内直接 fetch 只要 33 ms），用户看到的就是
「场站换了、树不动、数据也不动」。

**确认**（把小于 8 的刷新间隔揪出来）：

```sql
docker exec energy-postgres psql -U postgres -d thingsboard -At -F' | ' -c "
select d.title, w->'config'->'settings'->>'refreshSecs' secs
from dashboard d, jsonb_each(d.configuration->'widgets') x(w)
where (w->'config'->'settings') ? 'refreshSecs'
  and (w->'config'->'settings'->>'refreshSecs')::int < 8;"
```

**修**（四层，都已内置）：

1. 看板里部件的 `refreshSecs` 不低于 10（部件代码把下限卡在 8 秒，配 3 也不会再打满连接池）。
2. 实时部件在 `siteCtx` 变化时等 2 秒再刷新，先把连接让给重建树。
3. 实时取数加并发闸门（每轮最多 2 个在途）：服务端 6 个 telemetry 并发时单个要 4.5 秒，
   限到 2 个后单个仍 ~0.2 秒，总量反而更快。
4. 查询设置里「所有设备」（`entityType=DEVICE`、无额外过滤）直接用客户设备清单建树，
   不再先 `POST /api/entitiesQuery/find` 拿一遍 id（省一次 1 秒往返）。

修完实测（客户账号，实时能耗）：

```
切场站 → 树生效 356 / 344 / 341 ms（连测三次，期间 1~5 个请求）
修复前：15~40 秒
```

---

### 现象 X2：顶栏没有「场站」选择器 / 换了场站某页不跟着变

**先分清三种情况，不是同一个问题：**

1. **当前页是看板**（能耗概览、历史能耗、分项、区域、参数报表…）
   → 主顶栏被看板隐藏了（`hideMainToolbar`），选择器在**看板自己的工具栏右上角**。
   这是有意的：看板的工具栏已经占了同一行，再顶一条会出现两个工具栏。
   两个位置渲染的是同一个组件、同一份全局状态，切哪个都一样。

2. **当前页是「组织与场站」**（`/sites`）
   → 不显示是设计。那一页的职责就是管理整棵树（建场站、改归属、配权限），
   在它上面再挂一个「当前场站」会让人误以为列表被过滤了。

3. **其它页面**（设备管理 / 设备分组 / 设备拓扑 / 告警中心 / 自检…）
   → 必须有。没有就是这一版前端没装上，先确认版本：

```bash
docker exec energy-server sh -c 'unzip -p /opt/energy/app.jar "BOOT-INF/lib/ui-ngx-*.jar" 2>/dev/null | head -c0' ; \
docker compose --profile split ps energy-server
```

> 版本对了仍不显示，看浏览器控制台：`tb-station-select` 组件依赖
> `/api/energy/visible-sites`，接口 403/500 会让它静默空着（页面右上角只剩一个空白）。

**切了场站、某一页不跟着变**，按页面查：

| 页面 | 跟随方式 | 不跟随的典型原因 |
| --- | --- | --- |
| 看板 | `DashboardPageComponent` 订阅全局状态后写进 `state.siteCtx` | 看板是「嵌入模式」且 `customerId` 与当前客户不同 —— 有意不写，避免串客户 |
| 设备管理 | 订阅 `StationContextService.current$`，前端过滤 `additionalInfo.siteId` | 设备没有 `additionalInfo.siteId`（归属没配，任何场站都不显示） |
| 设备分组 | 用**显示名**匹配树里的场站容器 | 树里还没有这个场站的容器（初始化时未建），或场站改过名 |
| 设备拓扑 | 订阅全局 id，作为 `siteId` 查询参数 | 拓扑的 `site_id` 是空（老数据没归属） |
| 告警中心 | 作为 `siteId` 查询参数发给 `/api/energy/alarms` | 见现象 X3 |

---

### 现象 X3：告警中心切到场站后一条都没有，但「本企业」有几十条

**症状**：顶上范围条正常，分页显示 `1 – 0 / 0`；把场站切到「本企业」（旧版本）就有数据。
抓请求能看到 `GET /api/energy/alarms?...&siteId=<场站id>`，响应里 `scope.deviceCount = 0`。

**根因**：按场站收集 originator 时只拿到了场站资产本身，没有子设备。

`EnergyScopeService.findContainsTargets` 先查 `FROM_ENTITY_GROUP` 组的 `Contains`，
**只有返回 `null` 才回退 `COMMON`**。但底层 `findByFromAndType` 对「没有匹配」
返回的是**空列表**，于是回退永远不触发 —— 场站资产的关系都在 `COMMON` 组，
结果就是一台设备都收不到。已在 2026-10-26 改成 `relations == null || relations.isEmpty()`。

**自查**（确认场站下真的有设备）：

```bash
docker exec energy-postgres psql -U postgres -d thingsboard -At -F' | ' -c "
select relation_type_group, relation_type, to_type, count(*)
from relation
where from_id = '<场站id>'
group by 1,2,3 order by 4 desc;"
```

正常应看到 `COMMON | Contains | DEVICE | N`（N > 0）。是这个结果但接口仍返回 0 条，
说明跑的是旧 jar，重新打包 `guard-server` 并重启 `energy-server`。

**验证**（demo 客户，两个场站分别应有 5 / 6 条）：

```bash
TOKEN=$(curl -s -X POST http://localhost:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"demo@126.com","password":"demo123456"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

curl -s -H "X-Authorization: Bearer $TOKEN" \
  "http://localhost:8090/api/energy/alarms?pageSize=10&page=0&siteId=<场站id>" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["totalElements"], d["scope"])'
```

---

### 现象 Y：部件显示「部件无数据可显示」，但它的脚本明明会自己取数

**原因：TB 根本没执行 `onInit`。**

`ui-ngx` 的 `widget.component.ts#displayWidgetInstance()` 有两个放行条件：
部件类型是 `static`，或 `typeParameters.processNoDataByWidget` 为真。
否则它遍历数据订阅，**没有任何订阅 `isDataResolved()` 就返回 false** ——
此时既不调 `onInit`，还盖一层「部件无数据可显示」。

自绘部件（脚本里用 `self.ctx.http` 取数、不走 TB data 订阅）如果不声明
`self.typeParameters`，就必然踩这个坑。客户看板里的数据源别名若指向
租户级占位符（`00000000-…`，如组织占位符），解析一定失败 → 部件永远空白。

**确认**：

```bash
# 输出 0，且脚本里有 self.ctx.http → 就是它
grep -c 'self.typeParameters' guard-server/src/main/data/json/system/widget_types/<部件>.json
```

**修**：部件脚本开头补

```js
self.typeParameters = function () {
  return { datasourcesOptional: true, processNoDataByWidget: true, dataKeysOptional: true };
};
```

2026-10-25 已给全部 `energy_management_*` 自绘部件补齐（当时能耗概览的
「概览指标卡」「日历热力图」、参数报表的同一批部件都是空的）。
从验收脚本里能直接看出来：`python3 scripts/08-verify-release.sh` 的
客户视角探针会把这类空态记成 `部件无数据可显示`。

---

## 1. 全新部署卡在第一步：setup 接口返回 423

**现象**

```bash
curl -s --noproxy '*' http://127.0.0.1:8090/api/noauth/setup/state
# {"status":423,"message":"System setup is not complete","errorCode":47,
#  "setupState":"ACCOUNT_REQUIRED"}
```

无论 `GET state` 还是 `POST complete`，都被同一个 423 挡回，耗时只有 10 毫秒 —— 说明请求根本没进 Controller。

**定位**

```bash
grep -n "SETUP_ALLOWED_ENTRY_POINTS" -A 5 \
  guard-server/src/main/java/com/guard/server/config/ThingsboardSecurityConfiguration.java
```

看列表首项有没有 `/api/noauth/setup/**`。

**根因**

`SystemSetupFilter` 在初始化未完成时锁住整个 `/api/**`，白名单 `SETUP_ALLOWED_ENTRY_POINTS` 必须显式放行 setup 自己的入口。这一项在从上游移植时漏掉了 —— 于是「唯一能解锁的接口」也被锁住，全新部署必然死锁。

**修法**

在白名单首项加入：

```java
public static final String SETUP_ENTRY_POINT = "/api/noauth/setup/**";
// ...
public static final List<RequestMatcher> SETUP_ALLOWED_ENTRY_POINTS = List.of(
        entryPoint(SETUP_ENTRY_POINT), entryPoint(DEVELOPMENT_MODE_PROBE_ENTRY_POINT), ...
```

修复后 `GET state` 返回 `200 {"status":"ACCOUNT_REQUIRED"}`。Controller 自身仍会拒绝在已有管理员时重复 complete，所以放行不降低安全性。

## 2. 建租户直接 400：Asset profile with such name already exists

**现象**

```json
{"status":400,"message":"Asset profile with such name already exists!","errorCode":31}
```

数据库里查不到这个租户 —— 整个事务回滚了。

**定位**

```bash
docker exec tb-postgres psql -U postgres -d thingsboard -c \
  "SELECT tenant_id, name FROM asset_profile ORDER BY created_time DESC LIMIT 5;"
```

同时看服务日志里的 `duplicate key value violates unique constraint "asset_profile_name_unq_key"`，键值是 `(tenant_id, name)=(新租户id, default)`。

**根因**

`TenantServiceImpl.saveTenant` 的顺序是：先执行建租户回调，**之后**才创建租户默认资产档案 `default`。回调里的能源字典保存 `type=default` 的品种资产时，`BaseAssetService` 发现资产没有 profile，会自动建一个同名 `default` 档案；随后平台再建默认档案就撞唯一键。

**修法**

把能源字典初始化从「回调内」挪到 `saveTenant` 返回之后：

```java
Tenant savedTenant = tenantService.saveTenant(tenant, tenantId -> {
    installScripts.createDefaultRuleChains(tenantId);
    // ... 其余默认资源
});
if (created && !isTestProfile()) {
    energyLibraryInstaller.createDefaultEnergyLibrary(savedTenant.getId());
}
```

此时默认档案已落库，自动建档退化为一次查找。

## 3. 客户登录后读自己名下资产 403

**现象**

```json
{"status":403,"message":"You don't have permission to perform 'READ' operation with CUSTOMER '星河工业园'!"}
```

同一个接口换租户管理员调用是 200。

**定位**

```bash
docker exec tb-postgres psql -U postgres -d thingsboard -c \
  "SELECT name, tenant_id FROM role;
   SELECT user_group_id, role_id FROM group_permission;
   SELECT id, owner_id, name FROM entity_group WHERE type='USER';"
```

会看到权限都授在 `Tenant Users` / `Customer Users` 这些**角色组**上，而新用户只被加进了 `All` 组。

**根因**

`UserServiceImpl` 新建用户时只调用 `addEntityToEntityGroupAll`，即只进 `All` 组。`DefaultUserService.save` 原逻辑只在「由 SYS_ADMIN 创建」时补加 `Tenant Administrators` 组；于是**租户管理员通过 REST 创建的客户账号没有任何角色组**，权限判定为空。

**修法**

按新用户的 authority 补默认组：

```java
if (created && Authority.CUSTOMER_USER.equals(savedUser.getAuthority())
        && savedUser.getCustomerId() != null && !savedUser.getCustomerId().isNullUid()) {
    EntityGroup customerUsers = entityGroupService.findOrCreateCustomerUsersGroup(
            savedUser.getTenantId(), savedUser.getCustomerId(), null);
    entityGroupService.addEntityToEntityGroup(
            savedUser.getTenantId(), customerUsers.getId(), savedUser.getId());
} else if (created && Authority.TENANT_ADMIN.equals(savedUser.getAuthority())) {
    EntityGroup admins = entityGroupService.findOrCreateTenantAdminsGroup(savedUser.getTenantId());
    entityGroupService.addEntityToEntityGroup(
            savedUser.getTenantId(), admins.getId(), savedUser.getId());
}
```

注意：这类账号已经建出来的，修完代码也不会自动补组。要么删掉重建，要么手工往 `Customer Users` 组里加一次。

## 4. 客户建好了，但一台演示设备都没有

**现象**

开通脚本报「全部验证通过」，但设备列表是 0 台。服务日志：

```
[energy] 未找到「电能表」设备档案，演示设备不建
```

**定位**

```bash
docker exec tb-postgres psql -U postgres -d thingsboard -c \
  "SELECT name, tenant_id FROM device_profile;"
```

新租户下只有 `default`，没有 `电能表` / `水表` / `燃气表` / `蒸汽表`。

**根因**

`EnergyLibraryInstaller.createMeterProfiles` 组装 `DeviceProfile` 时只设了 name/type/transportType/provisionType，**没有设 `profileData`**。`DeviceProfileDataValidator` 会直接调用 `getProfileData().getTransportConfiguration()`，null 触发 NPE；异常被每个档案自己的 `catch` 吃掉，只留下一条日志，外表看就是「档案静默消失」。

**修法**

补上三件套：

```java
DeviceProfileData profileData = new DeviceProfileData();
profileData.setConfiguration(new DefaultDeviceProfileConfiguration());
profileData.setTransportConfiguration(new DefaultDeviceProfileTransportConfiguration());
profileData.setProvisionConfiguration(new DisabledDeviceProfileProvisionConfiguration(null));
p.setProfileData(profileData);
```

修完后新租户会有 4 个计量器具档案，客户创建时演示设备正常产出 3 台。

## 5. 仪表板 0 个

### 情况 A：租户自己也是 0 个

**现象**

租户建成功、资产正常，但 `/api/tenant/dashboards` 返回 0，日志里没有任何报错。

**定位**

```bash
# 看运行时实际用的是哪个数据目录
grep -n "install.data_dir" /opt/energy/thingsboard.yml
# 看候选目录里有没有 json/
ls -d application/src/main/data/json guard-server/src/main/data/json 2>/dev/null
```

**根因**

`InstallScripts.getDataDir()` 在未显式配置时按启动目录猜：仓库里 `application/src/main/data` 存在（但只有一个 `certs/`），于是被选中；`createDefaultTenantDashboards` 的 `listDir` 捕获 `NoSuchFileException` 后返回空流 —— 不报错，仪表板就是 0。

**修法**

1. 启动参数显式加 `-Dinstall.data_dir=/opt/energy/data`（**推荐，必须做**）；
2. 代码侧也收紧：候选目录必须含 `json/` 才返回，并继续尝试 `guard-server/src/main/data`。

### 情况 B：租户有看板，客户 0 个

**现象**：租户管理员能看到全部看板，客户登录后「仪表板」列表是空的。

**定位**：

```bash
TOK=$(curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"tenant@126.com","password":"12345678"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

CID=$(curl -s --noproxy '*' -H "X-Authorization: Bearer $TOK" \
  'http://127.0.0.1:8090/api/customers?pageSize=5&page=0' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id']['id'])")

curl -s --noproxy '*' -H "X-Authorization: Bearer $TOK" \
  "http://127.0.0.1:8090/api/customer/$CID/dashboards?pageSize=100&page=0" \
  | python3 -c "import json,sys; print('客户可见:', json.load(sys.stdin).get('totalElements',0))"
```

**根因**：客户看板的查询条件是 `dashboard.customer_id = 该客户`。
上游的「分配给客户」只写 `assigned_customers` 和 relation，**不改 customer_id** ——
所以分配了也查不到。

**修法**：建客户时本平台会把租户的全部看板**复制一份**到客户名下（已自动）。
手工补：

```bash
cd ~/energy-app
bash scripts/02-onboard.sh ...（参数同上，会重建客户并复制看板）
```

或者只删客户再重建（见[③ 数据初始化](/admin/init)第七节）。

## 6. 01-install.sh 报 psql: command not found

**现象**

```
01-install.sh: line 73: psql: command not found
```

**根因**

数据库跑在 Docker 里，宿主机没装 PostgreSQL 客户端。

**修法**

加 `--db-container`，让脚本在容器内执行 psql：

```bash
bash 01-install.sh --db-container tb-postgres --db-name thingsboard ...
```

## 7. curl 全部返回 HTTP 000

**现象**

服务日志显示已启动、端口也在监听，但所有 `curl` 都是 `000`。

**根因**

本机配置了 HTTP 代理，`127.0.0.1` 走了代理。

**修法**

```bash
curl --noproxy '*' http://127.0.0.1:8090/api/noauth/setup/state
```

脚本里要写成函数，不能写成 `CURL="curl ... --noproxy *"` —— 变量展开时 `*` 会被 glob 成当前目录的文件名。

## 8. install 中断：UnrecognizedPropertyException on widget type

**现象**

install 跑到部件装载时中断：

```
UnrecognizedPropertyException: Unrecognized field "type" ...
```

**根因**

`WidgetTypeDetails` 是严格反序列化，JSON 顶层只允许 `fqn/name/scada/descriptor/deprecated/tags/description/resources/image`。构建脚本把内部使用的 `type` 字段一起写进了 JSON。

**修法**

发布前统一剔除顶层 `type`：

```js
const { type, ...payload } = widgetJson;  // type 只用于本地分类
```

自检和发布都必须用剔除后的 `payload`。

## 9. 服务起不来 / 端口冲突

同一台机器跑第二个实例时必须同时改这些，否则会撞：

| 配置 | 默认值 | 用途 |
| --- | --- | --- |
| `--server.port` | 8090 | HTTP |
| `INTEGRATIONS_RPC_PORT` | 9090 | 集成服务 RPC |
| `EDGES_RPC_PORT` | 7070 | 边缘服务 RPC |
| `TB_QUEUE_CF_ROCKS_DB_PATH` | `~/.rocksdb/cf_states` | 队列状态 |
| `TB_EDQS_ROCKSDB_PATH` | `~/.rocksdb/edqs` | EDQS |
| CoAP | 5683 | 关闭用 `COAP_ENABLED=false` |

## 10. Docker 占满磁盘 / 构建缓存过大

**现象**：安装或构建时报 `No space left on device`，或系统提示磁盘不足。

先看是谁占的：

```bash
docker system df
```

三个最常见的来源：**容器日志**（默认不限制）、**构建缓存**（不自动回收）、**悬空镜像**。

最安全的一步清理：

```bash
docker builder prune -f      # 只清构建缓存，不影响任何运行中的服务
docker image prune -f        # 清悬空镜像（<none>）
```

⚠️ **不要**随手用 `docker system prune -a --volumes -f` —— 它会删掉未使用的命名卷，数据库可能一并丢失。

完整的磁盘调优、日志轮转、`data-root` 迁移见[① Docker](/admin/docker) 第二、三节。

## 11. 平时该盯什么

| 指标 | 怎么看 | 异常信号 |
| --- | --- | --- |
| 服务存活 | `docker compose ps` | 容器反复重启 → 看 `docker inspect --format '{{.State.OOMKilled}}'` |
| 数据库连接数 | `SELECT count(*) FROM pg_stat_activity;` | 接近 200 说明连接泄漏 |
| 遥测写入 | 日志搜 `totalFailed` | 非 0 说明写库受阻 |
| 磁盘 | `df -h /` | 低于 10% 立即清理，见第 10 节 |
| 慢查询 | `SELECT * FROM pg_stat_activity WHERE state='active' AND now()-query_start > interval '30s';` | 长时间 active 的查询要优化 |

### 日志在哪：**没有文件日志，全在 Docker 里**

这一点必须先说清楚，否则会去找一个不存在的文件。

```
energy-server 的 logback.xml 只有 ConsoleAppender（STDOUT）
        │
        ▼
   Docker json-file 驱动接管
        │
        ▼
/var/lib/docker/containers/<容器id>/<容器id>-json.log
        │
        ▼
   docker logs / docker compose logs 读它
```

**日志有两份，取决于 `SPRING_PROFILE`**：

| profile | 控制台（Docker） | 文件（宿主 `~/energy-app/logs/`） |
| --- | --- | --- |
| `dev` | ✓ | ✗ 不生成 |
| **`pro`（生产）** | ✓ | ✓ **一天一个文件**，保留 30 天 |

```
pro 模式：

  logback-spring.xml
        ├── ConsoleAppender ──▶ stdout ──▶ Docker json-file ──▶ docker logs
        └── RollingFileAppender ─▶ /opt/energy/logs/guard-server.log
                                      │  过了当天自动重命名
                                      ▼
                                  guard-server.2026-10-22.log
                                  guard-server.2026-10-23.log
                                  …（最多 30 个，总量上限 2GB）
```

**关键事实**：

| 项目 | 实际情况 |
| --- | --- |
| 文件在哪 | 宿主 `~/energy-app/logs/`（挂载到容器 `/opt/energy/logs`） |
| 文件名 | 当天：`guard-server.log`；归档：`guard-server.YYYY-MM-DD.log` |
| 按天切吗 | **pro 模式按天切**（`TimeBasedRollingPolicy`，严格一天一个，不按大小分片） |
| 保留多久 | `maxHistory=30` 天，更早的自动删 |
| 总量上限 | `totalSizeCap=2GB`，30 天加起来超 2GB 就从最旧的删 |
| `dev` 模式有文件吗 | **没有**，只有控制台 |
| 容器控制台日志 | `json-file`，`max-size=50m` × `max-file=5` = 最多 250MB，`down` 后随容器删除 |

**怎么确认当前是哪个模式**：

```bash
cd ~/energy-app
grep '^SPRING_PROFILE' .env          # 期望 pro
ls -lh logs/                          # 期望看到 guard-server.log
head -3 logs/guard-server.log         # 期望 "The following 1 profile is active: \"pro\""
```

**切到生产模式**（如果没有文件日志）：

```bash
sed -i 's/^SPRING_PROFILE=.*/SPRING_PROFILE=pro/' ~/energy-app/.env
cd ~/energy-app && docker compose --profile split up -d --force-recreate energy-server
# 改环境变量必须 up -d，restart 不生效
```

**常用查法**：

```bash
cd ~/energy-app

# 文件日志（pro）
tail -f logs/guard-server.log                     # 实时跟
tail -200 logs/guard-server.log                   # 最近 200 行
less logs/guard-server.2026-10-22.log             # 看某一天

# 控制台（任何模式都有）
docker compose logs --tail=200 energy-server
docker compose logs --since 30m energy-server
docker compose logs -f energy-server
docker compose logs energy-server | grep -E "ERROR|Caused by"
```

> 两者内容相同。文件日志便于按日期回溯与归档，控制台便于实时跟。

**日志配置在哪**：`guard-server/src/main/resources/logback-spring.xml`。

⚠️ 文件名必须是 `logback-spring.xml`，不能是 `logback.xml` ——
只有 `-spring` 后缀才会被 Spring Boot 的 Joran 配置器加载，
`<springProfile>` 标签才生效。早期用 `logback.xml` 时该标签会被忽略，
表现为「配置写了但 dev/pro 没区别」。

## 11A. 日志排查命令大全（照抄即用）

> 先决条件：`SPRING_PROFILE=pro` 时日志会按天落盘到 `~/energy-app/logs/`。
> dev 模式只有容器控制台，下面的 `logs/` 命令要换成 `docker compose logs`。

### 11A.1 日志在哪

```
① 文件日志（pro 模式，按天）
   ~/energy-app/logs/guard-server.log              ← 今天正在写
   ~/energy-app/logs/guard-server.2026-10-21.log   ← 归档（保留 30 天）

② 容器控制台（任何模式都有）
   docker compose logs energy-server
      ↳ 底层是 /var/lib/docker/containers/<id>/<id>-json.log
      ↳ 按大小轮转：50MB × 5 个 = 最多 250MB，超了滚掉
```

**两者内容相同**，区别是：文件日志按天留存、可用 `grep`/`awk` 精细处理；
控制台适合实时跟、且不受 `docker compose down` 之外的删除影响。

```bash
cd ~/energy-app

# 今天
tail -f logs/guard-server.log

# 指定日期
less logs/guard-server.2026-10-21.log

# 最近 N 行（等价于 docker compose logs --tail）
tail -200 logs/guard-server.log
```

### 11A.2 三个基础动作

```bash
# ① 实时跟（排障时开着，复现一次就抓到）
tail -f logs/guard-server.log

# ② 只看最近 30 分钟
awk -v t="$(date -v-30M '+%Y-%m-%d %H:%M:%S')" '$0 >= t' logs/guard-server.log

# ③ 某个时间窗（例：14:00 到 15:00 之间出事）
sed -n '/2026-10-22 14:00/,/2026-10-22 15:00/p' logs/guard-server.log
```

> macOS 的 `date -v-30M` 在 Linux 上要写 `date -d '30 minutes ago'`。服务器上是后者。

### 11A.3 按级别筛

```bash
# 只看错误（最常用）
grep -E " (ERROR|FATAL) " logs/guard-server.log

# 警告 + 错误
grep -E " (WARN|ERROR|FATAL) " logs/guard-server.log

# 排除噪音，只看真正的业务错误
grep " ERROR " logs/guard-server.log | grep -v "GitSyncService"

# 统计各级别条数（一眼看出今天健康不健康）
awk '{for(i=1;i<=NF;i++) if($i=="ERROR"||$i=="WARN"||$i=="INFO"){print $i; break}}' \
  logs/guard-server.log | sort | uniq -c | sort -rn
```

### 11A.4 关键词匹配（按问题类型）

```bash
# 数据库
grep -iE "SQLException|BadSqlGrammar|relation .* does not exist|constraint|deadlock" \
  logs/guard-server.log

# 表/字段不存在（迁移漏表的典型症状）
grep -iE 'relation "[a-z_]+" does not exist' logs/guard-server.log

# 超时
grep -iE "timeout|timed out|Read timed out|connect timed out" logs/guard-server.log

# 内存
grep -iE "OutOfMemory|heap space|GC overhead" logs/guard-server.log

# 空指针（多半是代码 bug）
grep -iE "NullPointerException" logs/guard-server.log

# 权限 / 认证
grep -iE "AccessDenied|Unauthorized|403|401|BadCredentials" logs/guard-server.log

# 设备接入（MQTT / HTTP）
grep -iE "mqtt|transport|Credentials|device.*not found" logs/guard-server.log

# 规则链 / 计算字段
grep -iE "rule.engine|calculated.field|RuleNode|CalculatedField" logs/guard-server.log

# 能源业务（本项目自建的部分）
grep -iE "\[energy\]|\[energy-schema\]|meter-reading|self-check" logs/guard-server.log
```

### 11A.5 带上下文（定位根因的关键）

错误行本身往往没用，**前因在它上面几行**：

```bash
# 错误前后各 5 行
grep -n -B5 -A10 " ERROR " logs/guard-server.log

# 把整段异常栈打出来（Caused by 才是根因）
grep -n -A30 "Exception" logs/guard-server.log | grep -E "Caused by|at com.guard" | head -30

# 只看本项目自己的代码行（过滤掉 Spring/JDK 的栈帧）
grep -E "^\s+at com\.guard" logs/guard-server.log | sort | uniq -c | sort -rn | head -20
```

### 11A.6 聚合统计（找规律）

```bash
# 出现最多的错误消息（去掉时间戳和线程名，只留消息正文）
grep " ERROR " logs/guard-server.log \
  | sed -E 's/^[0-9-]+ [0-9:,]+ \[[^]]*\] ERROR +[^ ]+ - //' \
  | sort | uniq -c | sort -rn | head -20

# 按小时看错误分布（判断是持续故障还是瞬时抖动）
grep " ERROR " logs/guard-server.log \
  | awk '{print substr($2,1,2)":00"}' | sort | uniq -c

# 哪些 logger 在刷屏（找出噪音源）
awk '/^[0-9]{4}-/ {for(i=1;i<=NF;i++) if($i=="INFO"||$i=="WARN"||$i=="ERROR"){print $(i+1); break}}' \
  logs/guard-server.log | sort | uniq -c | sort -rn | head -15
```

### 11A.7 追踪一次请求

本平台日志**没有 requestId / traceId**（TB 未启用 MDC），所以只能靠
**线程名 + 时间窗**定位：

```bash
# 1. 先找到可疑时间点（用户报障的时间）
grep "2026-10-22 14:3" logs/guard-server.log | tail -50

# 2. 从错误行拿到线程名，例：[http-nio-0.0.0.0-8090-exec-5]
# 3. 追这个线程的全部输出
grep "http-nio-0.0.0.0-8090-exec-5" logs/guard-server.log

# 4. HTTP 请求的线程名规律
#    http-nio-0.0.0.0-8090-exec-N       REST 请求
#    sql-log-N-thread-1                 SQL 批量写
#    TB-Scheduling-N                    定时任务
#    git-sync-N-thread-1                git 同步（可忽略，见 11A.8）
```

> 想真正拿到 requestId，需要在 `logback-spring.xml` 的 pattern 里加
> `%X{requestId}` 并在过滤器里 `MDC.put`。当前版本没做。

### 11A.8 已知噪音（可以安全忽略）

这几条出现**不代表故障**，别浪费时间：

| 日志内容 | 原因 | 要不要处理 |
| --- | --- | --- |
| `DefaultGitSyncService ... Failed to initialize repository ... github.com/thingsboard/data-converters.git` | 内网/离线环境拉不到 GitHub。TB 内置的示例库同步 | **不用**。功能不依赖它 |
| `AgentAppTemplateSyncService ... sync completed` | 正常心跳 | 不用 |
| `Transport Stats: connections_active[protocol=MQTT] [0]` | 每分钟统计，0 表示当前无设备连接 | 有设备在线时应当 > 0 |
| `TbSqlBlockingQueue ... totalFailed [0]` | 写库队列统计，`totalFailed` 才是关键 | 0 正常；非 0 要查 |
| `HikariPool-N - Starting...` / `Start completed` | 连接池正常启动 | 不用 |

**过滤掉噪音看真正的错误**：

```bash
grep " ERROR " logs/guard-server.log \
  | grep -vE "GitSyncService|data-converters" 
```

### 11A.9 按本项目历史故障反查（最有用的表）

这份表是从实际踩过的坑反推出来的 **grep 速查**：

| 症状 | 命令 | 典型根因 |
| --- | --- | --- |
| 页面 500 / 提示表不存在 | `grep 'relation ".*" does not exist' logs/guard-server.log` | 迁移漏表（抄表/账单那 5 张） |
| 客户登录后空白 | `grep -iE "customMenu|HomeMenuItem|homeDashboard" logs/guard-server.log` | 菜单第一项不是 home |
| 看不费率 / 组织树空 | `grep -iE "visible-sites|organization|energyRates" logs/guard-server.log` | 组织缺失或费率层级断 |
| 峰谷报表全 0 | `grep -iE "tou-analysis\|touScheme\|scheme" logs/guard-server.log` | 分时方案没命中 |
| 闲时告警不出 | `grep -iE "idle_exceed\|IdleEnergy\|Required arguments" logs/guard-server.log` | 计算字段没拿到参数 |
| 设备上报 404 | `grep -iE "v1/.*telemetry\|Device.*not found\|Invalid credentials" logs/guard-server.log` | token 错 / 设备不存在 |
| MQTT 连不上 | `grep -iE "MQTT\|CONNACK\|transport.*start" logs/guard-server.log` | 端口没映射 / transport 未就绪 |
| 激活链接打不开 | `grep -iE "activationLink\|baseUrl" logs/guard-server.log` | `X-Forwarded-Port` 缺失 |
| 启动报 bean 找不到 | `grep -iE "NoSuchBeanDefinition\|Unsatisfied dependency" logs/guard-server.log` | 包不在 `@ComponentScan` |
| 建表没生效 | `grep "energy-schema" logs/guard-server.log /tmp/energy-install.log` | 表在 install 阶段建的 |

### 11A.10 导出与归档

```bash
# 导出最近 24 小时（发给开发排查）
docker compose logs --since 24h energy-server > /tmp/server-$(date +%F).log

# 导出指定日期的文件日志
cp logs/guard-server.2026-10-21.log /tmp/

# 打包所有日志（注意体积）
tar czf /tmp/energy-logs-$(date +%F).tar.gz logs/

# 只看某个客户/设备相关的
grep "<设备uuid>\|<客户uuid>" logs/guard-server.log

# 把 ERROR 段单独抽出来（通常只有几百 KB，便于传阅）
grep -A30 " ERROR " logs/guard-server.log > /tmp/errors-$(date +%F).log
```

### 11A.11 日志占多少磁盘

```bash
# 文件日志（pro 模式）
du -sh ~/energy-app/logs/
ls -lh ~/energy-app/logs/

# 归档超过 30 天的会被自动删除（maxHistory=30）
# 总量上限 2GB（totalSizeCap），超了从最旧的删

# 容器控制台日志
docker inspect energy-server --format '{{.LogPath}}' | xargs ls -lh
```

**日志暴涨的排查**（一天几百 MB 通常不正常）：

```bash
# 哪个 logger 在刷
awk '/^[0-9]{4}-/ {for(i=1;i<=NF;i++) if($i=="INFO"||$i=="WARN"||$i=="ERROR"){print $(i+1); break}}' \
  logs/guard-server.log | sort | uniq -c | sort -rn | head -5
```

最常见是某个设备高频上报、或规则链死循环。先看 `TbSqlBlockingQueue` 的
`totalAdded` 增长速度。

## 12. 排障通用三件套

```bash
# 1. 端口在不在
lsof -nP -iTCP:8090 -sTCP:LISTEN

# 2. 最近的错误（日志在 Docker 里，不是文件）
docker compose logs --tail=200 energy-server | grep -E "ERROR|Caused by"

# 3. 状态自检
curl -s --noproxy '*' http://127.0.0.1:8090/api/noauth/setup/state
curl -s --noproxy '*' http://127.0.0.1:8090/api/auth/user -H "X-Authorization: Bearer $TOKEN"
```

---

## 13. 系统架构图

### 13.1 容器与端口

```
                        浏览器（租户 / 客户）
                                 │  http://<主机>:8090
                                 ▼
        ┌────────────────────────────────────────────────────┐
        │  energy-gateway          nginx:1.27-alpine         │
        │  容器内 :80，宿主映射 ${HTTP_PORT:-8090}            │
        │  职责：统一入口、gzip、WebSocket 升级、路由分流       │
        └───┬──────────────────────────────┬─────────────────┘
            │ /  /api/  /ngxapi?           │ /ngxai/  /ngxapi/
            │ （前端产物 + REST + WS）       │ （AI 前端静态 + AI 后端）
            ▼                              ▼
  ┌─────────────────────────┐   ┌──────────────────────────┐
  │  energy-server          │   │  energy-ngxai-backend    │
  │  eclipse-temurin:25-jre │   │  energy/ngxai-backend    │
  │  :8090  HTTP/REST       │   │  :18801  FastAPI          │
  │  :1883  MQTT（设备接入） │   │  预测 / 建议 / 质量分析    │
  └───────────┬─────────────┘   └────────────┬─────────────┘
              │                              │
              └──────────────┬───────────────┘
                             ▼
              ┌──────────────────────────────┐
              │  energy-postgres             │
              │  postgres:16-alpine  :5432   │
              │  卷 pgdata（唯一有状态服务）   │
              └──────────────────────────────┘
```

**设备接入只有一条路**：设备 → MQTT `:1883` → `energy-server` 的规则链 → 写库。
没有直连数据库的路径。

**为什么 gateway 不代理 MQTT**：1883 是 TCP 协议，nginx 这个配置只做 HTTP。
设备要连宿主机的 1883（compose 里 `energy-server` 直接映射了该端口）。

### 13.2 数据模型（业务视角）

```
tenant（租户 / 能源服务商）
  │
  ├── customer（客户 / 用能单位）
  │     │  additional_info.energyRates  ← 客户级兜底费率
  │     │  custom_menu_id               ← 该客户看到的左侧菜单
  │     │
  │     ├── asset(type='组织')           ← 费率维护层级
  │     │     │  SERVER_SCOPE.energyRates ← 组织级费率（下属场站继承）
  │     │     │
  │     │     ├── asset(type='场站')
  │     │     │     │  SERVER_SCOPE.idleConfig     ← 闲时阈值
  │     │     │     │  SERVER_SCOPE.siteCustomRates ← 场站自定义费率（最高优先）
  │     │     │     │
  │     │     │     ├── device（计量点 / 传感器 / 网关）
  │     │     │     │     │  device_profile_id → 决定它是电表/水表/…
  │     │     │     │     └── ts_kv（遥测，按月分区）
  │     │     │     │
  │     │     │     └── asset(type='分项'|'区域'|'空间位置'|'用能性质')
  │     │     │
  │     │     └── asset(type='组织')  ← 组织可嵌套
  │     │
  │     └── dashboard（看板副本，customer_id = 该客户）
  │
  ├── asset_profile（资产档案 16 个）← 租户级
  ├── device_profile（设备档案 8 个）← 租户级
  │     │  isMeter / energyTypeCode / wiring  ← 能力声明
  │     └── calculated_field（告警规则 + 派生指标，11 条）
  │
  ├── asset(type='energy_type_library') 能源参数字典 ← 租户级
  │     └── asset(type='default') 电能 / 水表 / 燃气 / 蒸汽
  │            └── SERVER_SCOPE.paramDict  ← 两级指标 key
  │
  ├── asset(type='tou_scheme') 分时时段方案 ×4 ← 租户级
  ├── asset(type='rate_template') 费率模板 ×4 ← 租户级（仅示例价参考）
  ├── asset(type='厂商' / '设备型号') ← 租户级
  │
  └── custom_menu（租户菜单 11 项 / 客户菜单 13 项）
```

**两条铁律**（踩过坑，写在这）：

1. **租户级实体的 `customer_id` 是 NULL_UUID，不是 `null`**。
   判断要写 `customerId == null || customerId.isNullUid()`，
   只写 `== null` 会永远不成立，把租户级主数据全部过滤掉，且不报错。
2. **客户菜单的 `custom_menu.customer_id` 恒为 NULL_UUID**。
   归属关系走反方向：`customer.custom_menu_id → custom_menu.id`。

### 13.3 费率的三层解析顺序

```
请求：这个场站按什么价结算？
   │
   ├─① 场站 SERVER_SCOPE.siteCustomRates 有该品种？ ──有──▶ 用它
   │
   ├─② 沿 Contains 父链向上，找最近的 type='组织'
   │     且 SERVER_SCOPE.energyRates 非空？
   │         └─有──▶ 用它（支持组织嵌套，逐级向上，最多 8 层）
   │
   └─③ 客户 additional_info.energyRates 有该品种？ ──有──▶ 用它
          └─都没有──▶ 视为该品种未开通
```

### 13.4 闲时能耗的判定链路

```
① 场站 idleConfig（workStart/workEnd/standbyPowerThreshold/idleRatioThreshold）
        │
        ▼
② IdleEnergyService 扫描设备遥测（energy_reading / power_total）
        │  只统计「设备档案 isMeter=true 且 energyTypeCode=elec」的设备
        ▼
③ 逐日算「闲时电量占比」与「闲时平均功率」，判定 isExceed
        │
        ├── 历史天数：直写 ts_kv（不触发告警，避免刷屏）
        └── 最新一天：经 TelemetrySubscriptionService 推一次
                │
                ▼
④ 设备档案上的计算字段「闲时能耗超标」读 idle_exceed
        │  参数映射只认**本次上报批次**里的键 —— 这是必须走②而不是直写 DAO 的原因
        ▼
⑤ 生成 / 清除 alarm（type='闲时能耗超标'）
```

**关键约束**：TB 的计算字段参数（`TS_LATEST`）只从本次上报的那批遥测取值，
不去库里查最新点。直接把值写进 `ts_kv` 不会触发告警，症状是规则一直报
`Required arguments are missing: exceed`。

### 13.4b 看板配置里的 id：三类，只有一类要担心

客户的 18 个看板都是从**租户级模板**复制出来的（租户名下 20 个模板，其中 2 个运营台不复制给客户）。模板是共享的，
所以里面不能用某个客户的真实 id，只能用约定的**占位符**：

```
00000000-0000-0000-0000-00000000xxxx
```

复制给客户时，「该替换的」换成那个客户的真实 id，「不该替换的」保留占位符。

```
                    ┌─────────────────────────────┐
                    │ 模板（租户名下 20 个看板）      │
                    │  全部是占位符                  │
                    └──────────────┬──────────────┘
                                   │ 复制给客户
                                   ▼
              ┌────────────────────┴────────────────────┐
              │         按「引用的是谁」分流              │
              └───────┬───────────────────────┬─────────┘
                      │                       │
        ┌─────────────▼──────────┐  ┌─────────▼────────────────┐
        │ 客户级实体（能替换）      │  │ 租户级实体（保持占位符）    │
        │  · 场站  …05a1          │  │  · 能源参数字典  …11b7     │
        │  · 4 个维度根 d101~d104 │  │  · 电能品种节点  …e1ec     │
        │  · 用电分项根  …17e0    │  │                            │
        └─────────────┬──────────┘  └─────────┬─────────────────┘
                      │                       │
                      ▼                       ▼
        换成客户真实 id                原样保留占位符
        客户有权读 → 200              前端不发请求，部件走 API
```

**三类 id 的判断表**（在 `configuration` JSON 里看到的 UUID）：

| 类别 | 例子 | 正常吗 | 说明 |
| --- | --- | --- | --- |
| 占位符 | `00000000-…-0000000011b7` | ✓ | 前端当「上下文实体」哨兵，**不发请求** |
| 客户自有实体 | 场站/维度根真实 id | ✓ | 客户有权读，200 |
| 配置内部 id | 部件 id、alias key、datasource id | ✓ | 不是实体引用，前端内部用 |
| **租户级实体** | 能源参数字典真实 id | ✗ | **403**，客户无权读 |
| **别家客户实体** | 别的客户的场站 id | ✗ | 403/404 |

**只有最后两类要修。**

**为什么不能用「占位符数量是否为 0」当判据**

这是本项目踩过的坑：早期验收脚本写「客户副本不应残留占位符 = 0」，
把占位符一律视为错误。结果修好之后这条断言反而失败 ——
因为租户级主数据的引用**本来就该留占位符**。

正确判据是**反向检查**：客户看板里有没有出现**租户级资产的真实 id**。

```sql
-- 期望 0 行
WITH ta AS (
  SELECT id::text AS aid FROM asset
  WHERE customer_id = '13814000-1dd2-11b2-8080-808080808080'
)
SELECT d.title, ta.aid
FROM dashboard d, ta
WHERE d.customer_id IS NOT NULL
  AND d.configuration LIKE '%'||ta.aid||'%';
```

**设计原则**：**能从 API 拿的数据，不要通过实体别名拿。**
实体别名受用户权限约束；API 只要接口放行，对客户与租户一视同仁。
`/api/energy/metric-params` 就是按这个原则做的 —— 客户和租户都返回 200，
所以部件不依赖「能源参数字典」那个实体。

**这张表已经由「一键修复初始化」自动维护**

```
平台自检
   └─ customer.dashboard-tenant-leaks   看板无租户级资产引用
        实际 N / 期望 0 处
              │
              ▼  点「一键修复初始化」
        repair-init → repairTenantAssetLeaks()
              │
              ├─ 列出所有租户级资产的 id
              ├─ 扫每个客户的看板 config
              └─ 换回占位符 → 返回 tenantAssetLeaksFixed
```

所以**不需要人肉排查、也不需要写 SQL**。
自检里看到该项不为 0，点一下就修好了（存量客户一并处理）。

> 这项检查的 `status` 语义与其他项相反：**0 才是正确状态**。
> 通用 `item()` 把 `actual <= 0` 判为 `MISSING`（缺数据），
> 在这里会把「一切正常」显示成「缺失」—— 已单独覆盖为 `leaks == 0 ? OK : PARTIAL`。

### 13.5 自建表：哪些表是我们自己的，不属于 ThingsBoard

**这条必须记住** —— 出问题时先分清「TB 的表」和「我们的表」，
否则会去翻 TB 文档找一个它根本没有的功能。

```
                    ┌──────────────────────────────────────┐
                    │  guard-server（本平台的 Java 服务）    │
                    └──────────────┬───────────────────────┘
                                   │
            ┌──────────────────────┴──────────────────────┐
            │                                             │
   ┌────────▼─────────┐                        ┌──────────▼──────────┐
   │ 走 TB 的 DAO/Service │                     │ 直接 jdbcTemplate    │
   │ （TB 原生功能）      │                      │ （本平台自建功能）    │
   └────────┬─────────┘                        └──────────┬──────────┘
            │                                             │
   ┌────────▼──────────────────┐          ┌───────────────▼─────────────────┐
   │ TB 自己的表（TB 负责建）    │          │ 我们自己的表（EnergySchemaInstaller│
   │                            │          │  在启动时自动建）                 │
   │ tenant / customer          │          │                                  │
   │ asset / device             │          │ meter_reading_batch  抄表批次     │
   │ asset_profile              │          │ meter_reading_record 抄表明细     │
   │ device_profile             │          │   └─ 按月分区 _YYYY_MM           │
   │ attribute_kv               │          │ billing              用能账单     │
   │ relation                   │          │ billing_detail       账单明细     │
   │ dashboard / custom_menu    │          │ tb_sync_log          同步日志     │
   │ ts_kv（按月分区）/ ts_kv_latest │      │                                  │
   │ alarm / audit_log / ...    │          │ 函数 energy_ensure_reading_partition│
   └────────────────────────────┘          └──────────────────────────────────┘
```

**自建表清单与用途**

| 表 | 用途 | 谁写 | 谁读 | 分区 |
| --- | --- | --- | --- | --- |
| `meter_reading_batch` | 一次「一键抄表」的运行记录（总数 / 正常 / 缺数 / 异常） | `EnergyMeterReadingController` | 抄表功能看板、「抄表批次」页 | 否 |
| `meter_reading_record` | 每设备每账期一条读数（上期 / 本期 / 用量 / 质量） | 同上 | 抄表台账、手工填报、参数报表 | **是**（按 `reading_time` 月分区） |
| `billing` | 用能账单（费用快照，`billing_no` 幂等） | 账单生成逻辑 | 「我的账单」看板 | 否 |
| `billing_detail` | 账单明细（每条费率一行） | 同上 | 同上 | 否 |
| `tb_sync_log` | 同步日志（遥测键 / 告警规则 / 校验规则 / 排班 / 账单） | 同步逻辑 | 排障时看 | 否 |

**为什么抄表明细要按月分区**：粒度是「每设备每账期一条」，一年下来
设备数 × 12 行。单表能撑，但查询永远带时间范围（台账按账期、报表按月），
分区后只扫目标月份，也便于整月归档或删除。

**建表在什么时候发生 —— 两个阶段，同一个方法**

```
① install 建库阶段（docker-01-install.sh）
   ThingsboardInstallApplication 启动
      │  它的 @ComponentScan 包含 com.guard.server.service.install
      ▼
   ApplicationReadyEvent
      │
      ▼
   EnergySchemaInstaller.ensureEnergyTables()   ← 全新库在这里就把表建好
      │
② energy-server 启动阶段
   ApplicationReadyEvent
      │
      ▼
   ensureEnergyTables()   ← 表已在 → 直接返回，什么也不做
```

**为什么两个阶段都会触发**：`install` 和 `server` 是两个独立进程，
但扫描到同一个组件、监听同一个事件。结果是——
**全新安装时，`docker-01-install.sh` 跑完表就有了**，
`energy-server` 起来时只是确认一遍。

**日志去哪个文件找**：

| 阶段 | 日志位置 | 特征 |
| --- | --- | --- |
| install 建库 | `/tmp/energy-install.log`（重装脚本）/ 命令行输出 | `能源自建表补齐：新建 8 个对象` |
| server 启动 | `docker logs energy-server` | **表已存在时不打 INFO**（只有 DEBUG） |

⚠️ **别只查 `docker logs energy-server` 就断言「没建表」** ——
如果是 install 阶段建的，server 日志里什么都不会有。
先用 14.18 的 SQL 查表在不在，那才是判据。

日志特征（真正建了东西才打 INFO）：

```
[energy-schema] 能源自建表补齐：新建 8 个对象，分区 [meter_reading_record_2026_10, ...]
```

「8 个对象」= 5 张表 + 3 个分区，`created` 列表把两者都算进去了。

**幂等性实测**（2026-10-22 重装验证）：全新库 install 阶段建 8 个对象；
随后 `energy-server` 启动无日志；再跑两次 `repair-init` 也不碰表。


**这是一次真实的迁移事故**：这 4 张表的 DDL 早就写在
`nenghaobao/energy-config/sql/`（01-billing / 02-meter-reading /
03-tb-sync-log / 04-meter-reading-batch），迁移脚本
`11-migrate-db.mjs` 用「docker exec psql」把它建在了**开发库**上，
脚本注释里写了「生产路径：追加进 guard-server 的 upgrade/schema_update.sql」——
**但这条路径从没执行过**。

结果：开发机（`tb-postgres`）有 36 条批次 / 147 条记录，看起来一切正常；
新装出来的库 0 张表，抄表与手工填报 **7 个接口全 500**。
验收脚本也没抓到（只测了带参数能通过的少数几个）。

**教训**：功能上线前，必须在**全新空库**上跑一遍完整流程，
而不是在「跑了几个月、表早就手工建好」的库上验收。

---

## 13A. Cassandra（默认遥测存储）

Cassandra 是**默认的遥测存储**（`DATABASE_TS_TYPE=cassandra`）。
只有 2GB 内存的小机器或纯功能演示才建议改成 `sql`（遥测回到 Postgres）。

**完整文档在独立页面**：[②b Cassandra](/admin/cassandra) ——
安装启用、切回、卸载、cqlsh 查询、nodetool 运维、备份恢复、常见故障都在那里。

这里只留三条**最容易在排障时撞上**的：

**① 改 `.env` 直接重启会失败**

```
InvalidKeyspaceException: Invalid keyspace thingsboard
```

keyspace 只在 install 阶段建（`@Profile("install")`），server 不会补。
正确做法：`bash scripts/11-cassandra.sh enable`（内部走 TB 原生 install）。

**② install 报 `tenant_profile_name_unq_key` 重复键是正常的**

非空库上 install 会在重建系统数据时撞重复键 —— 但 Cassandra 建表在它**之前**
已完成。判成败看 keyspace 与两张表是否存在，不看 install 退出码。

**③ `data/cassandra/` 必须存在**

早先打包漏了这个目录，install 直接崩 `NoSuchFileException`。
已修；若你的部署目录缺，重跑 `docker-00-prepare.sh --force`。

---

## 14. 运维常用 SQL

全部在 `energy-postgres` 容器里执行：

```bash
docker exec -it energy-postgres psql -U postgres -d thingsboard
```

> 下面的 SQL 都在真实库上跑通过。涉及 `additional_info` 的查询必须写
> `additional_info::jsonb->>'key'` —— 该列是 `character varying`，
> 直接写 `additional_info->>'key'` 会报
> `operator does not exist: character varying ->> unknown`。

> **⚠ Cassandra 后端（默认）下，凡是用到 `ts_kv` 的 SQL 要先跑一次镜像**
>
> ```bash
> bash scripts/ts-mirror.sh
> ```
>
> 它把 Cassandra 的遥测导出到 PG 并建同名视图 `ts_kv`，SQL 一行都不用改。
> 不跑的话会报 `relation "ts_kv" does not exist`。原理见
> [②b · 四之二](/admin/cassandra)。

### 14.1 总览：这套系统里到底有什么

```sql
SELECT '租户'   AS 实体, count(*) AS 数量 FROM tenant
UNION ALL SELECT '客户',       count(*) FROM customer
UNION ALL SELECT '组织',       count(*) FROM asset  WHERE type='组织'
UNION ALL SELECT '场站',       count(*) FROM asset  WHERE type='场站'
UNION ALL SELECT '资产档案',   count(*) FROM asset_profile
UNION ALL SELECT '设备档案',   count(*) FROM device_profile
UNION ALL SELECT '设备',       count(*) FROM device
UNION ALL SELECT '遥测点',     count(*) FROM ts_kv
UNION ALL SELECT '计算字段',   count(*) FROM calculated_field
UNION ALL SELECT '告警',       count(*) FROM alarm
UNION ALL SELECT '看板',       count(*) FROM dashboard
UNION ALL SELECT '自定义菜单', count(*) FROM custom_menu;
```

### 14.2 组织与场站的层级

```sql
SELECT
  a.type                        AS 类型,
  a.name                        AS 名称,
  coalesce(p.name, '(无父节点)') AS 上级,
  c.title                       AS 客户
FROM asset a
LEFT JOIN relation r ON r.to_id = a.id
                    AND r.relation_type = 'Contains'
                    AND r.relation_type_group = 'COMMON'
LEFT JOIN asset    p ON p.id = r.from_id
LEFT JOIN customer c ON c.id = a.customer_id
WHERE a.type IN ('组织','场站')
ORDER BY a.type DESC, 上级, a.name;
```

**怎么读**：`上级 = (无父节点)` 的组织是这个客户最顶层；
场站的上级应该是一个组织。若场站上级为空，它拿不到组织级费率（只能吃客户兜底）。

### 14.3 每个场站挂了哪些设备、最后上报时间

```sql
SELECT
  s.name                       AS 场站,
  dp.name                      AS 设备档案,
  count(DISTINCT d.id)         AS 设备数,
  to_char(to_timestamp(max(kv.ts)/1000) AT TIME ZONE 'Asia/Shanghai',
          'MM-DD HH24:MI')     AS 最后上报
FROM asset s
JOIN device d          ON d.additional_info::jsonb->>'siteId' = s.id::text
JOIN device_profile dp ON dp.id = d.device_profile_id
LEFT JOIN ts_kv kv     ON kv.entity_id = d.id
WHERE s.type = '场站'
GROUP BY s.name, dp.name
ORDER BY s.name, dp.name;
```

### 14.4 谁配了费率（组织 / 客户 / 场站三级）

```sql
SELECT '组织' AS 层级, a.name  AS 对象,
       jsonb_object_keys(ak.json_v::jsonb) AS 品种
FROM asset a
JOIN attribute_kv ak  ON ak.entity_id = a.id
JOIN key_dictionary k ON k.key_id = ak.attribute_key
WHERE k.key = 'energyRates' AND a.type = '组织'
UNION ALL
SELECT '客户', c.title, jsonb_object_keys(ak.json_v::jsonb)
FROM customer c
JOIN attribute_kv ak  ON ak.entity_id = c.id
JOIN key_dictionary k ON k.key_id = ak.attribute_key
WHERE k.key = 'energyRates'
UNION ALL
SELECT '场站', a.name, jsonb_object_keys(ak.json_v::jsonb)
FROM asset a
JOIN attribute_kv ak  ON ak.entity_id = a.id
JOIN key_dictionary k ON k.key_id = ak.attribute_key
WHERE k.key = 'siteCustomRates' AND a.type = '场站'
ORDER BY 1, 2, 3;
```

### 14.5 某场站最终会用哪一层的价（继承链）

```sql
WITH RECURSIVE up(id, name, type, depth) AS (
  SELECT a.id, a.name, a.type, 0
  FROM asset a
  WHERE a.name = '单相园区·星河工业园'          -- ← 换成要查的场站名
  UNION ALL
  SELECT p.id, p.name, p.type, up.depth + 1
  FROM up
  JOIN relation r ON r.to_id = up.id
                 AND r.relation_type = 'Contains'
                 AND r.relation_type_group = 'COMMON'
  JOIN asset p    ON p.id = r.from_id
  WHERE up.depth < 8
)
SELECT depth AS 层, type AS 类型, name AS 名称,
       EXISTS (SELECT 1 FROM attribute_kv ak
                 JOIN key_dictionary k ON k.key_id = ak.attribute_key
                WHERE ak.entity_id = up.id AND k.key = 'energyRates') AS 配了组织费率,
       EXISTS (SELECT 1 FROM attribute_kv ak
                 JOIN key_dictionary k ON k.key_id = ak.attribute_key
                WHERE ak.entity_id = up.id AND k.key = 'siteCustomRates') AS 配了场站自定义
FROM up ORDER BY depth;
```

**怎么读**：从 `层=0`（场站自己）往上，第一个「配了组织费率」的组织就是生效来源；
若场站自己「配了场站自定义」，则它以最高优先级覆盖。

### 14.6 品种字典的两级指标数

```sql
SELECT a.name AS 品种,
       ak.str_v AS 编码,
       jsonb_array_length(ak2.json_v::jsonb->'params') AS 一级指标,
       (SELECT count(*)
          FROM jsonb_array_elements(ak2.json_v::jsonb->'params') p
          CROSS JOIN LATERAL jsonb_array_elements(coalesce(p->'children','[]'::jsonb)) ch
       ) AS 二级key,
       ak2.json_v::jsonb->>'version' AS 版本
FROM asset lib
JOIN relation r ON r.from_id = lib.id
               AND r.relation_type='Contains' AND r.relation_type_group='COMMON'
JOIN asset a    ON a.id = r.to_id
LEFT JOIN attribute_kv ak  ON ak.entity_id = a.id
                          AND ak.attribute_key = (SELECT key_id FROM key_dictionary WHERE key='code')
LEFT JOIN attribute_kv ak2 ON ak2.entity_id = a.id
                          AND ak2.attribute_key = (SELECT key_id FROM key_dictionary WHERE key='paramDict')
WHERE lib.type = 'energy_type_library'
ORDER BY a.name;
```

**期望**（本版）：电能 26 一级 / 48 二级；水表、燃气、蒸汽各 3 / 3；版本 `4`。

### 14.7 设备档案能力（判断某设备算不算表计）

```sql
SELECT dp.name AS 设备档案,
       coalesce(
         (SELECT a.bool_v::text FROM attribute_kv a JOIN key_dictionary k ON k.key_id=a.attribute_key
           WHERE a.entity_id=dp.id AND k.key='isMeter'),
         (SELECT a.str_v        FROM attribute_kv a JOIN key_dictionary k ON k.key_id=a.attribute_key
           WHERE a.entity_id=dp.id AND k.key='isMeter')
       ) AS 表计,
       (SELECT a.str_v FROM attribute_kv a JOIN key_dictionary k ON k.key_id=a.attribute_key
         WHERE a.entity_id=dp.id AND k.key='energyTypeCode') AS 能源品种,
       (SELECT a.str_v FROM attribute_kv a JOIN key_dictionary k ON k.key_id=a.attribute_key
         WHERE a.entity_id=dp.id AND k.key='wiring') AS 接线
FROM device_profile dp
ORDER BY dp.name;
```

> `isMeter` 在库里存的是 `bool_v`（布尔列），`energyTypeCode` 存 `str_v`。
> 一律用 `str_v` 读 `isMeter` 会得到 null，把所有电表判成「不是表计」。

### 14.8 ⚠ 自查：非电表却被判闲时超标（期望 0 行）

```sql
SELECT DISTINCT
  d.name  AS 设备,
  dp.name AS 档案,
  coalesce((SELECT a.str_v FROM attribute_kv a
             WHERE a.entity_id = dp.id
               AND a.attribute_key = (SELECT key_id FROM key_dictionary WHERE key='energyTypeCode')),
           '(未标品种)') AS 能源品种
FROM ts_kv kv
JOIN key_dictionary k  ON k.key_id = kv.key
JOIN device d          ON d.id = kv.entity_id
JOIN device_profile dp ON dp.id = d.device_profile_id
WHERE k.key = 'idle_exceed' AND kv.long_v = 1
  AND coalesce((SELECT a.str_v FROM attribute_kv a
                 WHERE a.entity_id = dp.id
                   AND a.attribute_key = (SELECT key_id FROM key_dictionary WHERE key='energyTypeCode')), '') <> 'elec'
ORDER BY 设备;
```

**有结果说明什么**：水表 / 燃气表 / 蒸汽表被算进了闲时能耗判定。
它们没有 `power_total`，闲时电量占比会被算成 100%，于是全部误判「超标」，
把告警中心塞满假告警。

**修法**：这些是旧版本跑出来的历史数据（旧版把场站下所有表计都算进闲时）。

代码侧已改为只统计「`isMeter=true` 且 `energyTypeCode=elec`」的设备
（`EnergyScopeService.electricMeterProfileIds`），重算不会再给非电表写结果。
但**重算不会删除旧点**，历史脏数据要单独清：

```sql
-- 备份（先看会删多少）
SELECT dp.name AS 档案, k.key AS 键, count(*) AS 点数
FROM ts_kv kv
JOIN key_dictionary k  ON k.key_id = kv.key
JOIN device d          ON d.id = kv.entity_id
JOIN device_profile dp ON dp.id = d.device_profile_id
WHERE k.key IN ('idle_exceed','idle_energy','work_energy','idle_avg_power','idle_delta_count')
  AND coalesce((SELECT a.str_v FROM attribute_kv a
                 WHERE a.entity_id = dp.id
                   AND a.attribute_key = (SELECT key_id FROM key_dictionary WHERE key='energyTypeCode')), '') <> 'elec'
GROUP BY dp.name, k.key ORDER BY 点数 DESC;

-- 删除（幂等，删干净后再跑返回 DELETE 0）
DELETE FROM ts_kv kv
USING device d, device_profile dp
WHERE kv.entity_id = d.id
  AND dp.id = d.device_profile_id
  AND kv.key IN (SELECT key_id FROM key_dictionary
                  WHERE key IN ('idle_exceed','idle_energy','work_energy',
                                'idle_avg_power','idle_delta_count'))
  AND coalesce((SELECT a.str_v FROM attribute_kv a
                 WHERE a.entity_id = dp.id
                   AND a.attribute_key = (SELECT key_id FROM key_dictionary WHERE key='energyTypeCode')), '') <> 'elec';
```

删之前先确认：这些设备档案上**没挂**「闲时能耗超标」计算字段，
所以这些点从未产生过告警，删除不影响任何告警历史。
本版实测：清理 420 点（水表 28 + 燃气表 28 + 蒸汽表 28 条 `idle_exceed`，
其余是配套的 `idle_energy` / `work_energy` / `idle_avg_power` / `idle_delta_count`）。

### 14.9 闲时阈值与判定结果

```sql
-- 阈值
SELECT a.name AS 场站,
       ak.json_v::jsonb->>'workStart'             AS 工作开始,
       ak.json_v::jsonb->>'workEnd'               AS 工作结束,
       ak.json_v::jsonb->>'standbyPowerThreshold' AS 待机功率阈值kW,
       ak.json_v::jsonb->>'idleRatioThreshold'    AS 闲时占比阈值pct
FROM asset a
JOIN attribute_kv ak  ON ak.entity_id = a.id
JOIN key_dictionary k ON k.key_id = ak.attribute_key
WHERE k.key = 'idleConfig'
ORDER BY a.name;

-- 最新一天的判定（1 = 超标）
SELECT d.name AS 设备,
       kv.long_v AS 超标,
       to_char(to_timestamp(kv.ts/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 判定时间
FROM ts_kv kv
JOIN key_dictionary k ON k.key_id = kv.key
JOIN device d         ON d.id = kv.entity_id
WHERE k.key = 'idle_exceed'
  AND kv.ts = (SELECT max(ts) FROM ts_kv k2
                WHERE k2.entity_id = kv.entity_id AND k2.key = kv.key)
ORDER BY kv.long_v DESC, d.name;
```

### 14.10 未清除告警与计算字段清单

```sql
-- 未清除告警（按类型统计）
SELECT type AS 告警类型, severity AS 级别, count(*) AS 条数
FROM alarm WHERE NOT cleared
GROUP BY type, severity ORDER BY 条数 DESC;

-- 计算字段挂在哪（应该在设备档案上，不是单台设备上）
SELECT dp.name AS 设备档案, cf.name AS 规则, cf.type AS 类型
FROM calculated_field cf
JOIN device_profile dp ON dp.id = cf.entity_id
ORDER BY dp.name, cf.type, cf.name;
```

**期望**：单相电能表 5 条、电能表 6 条，共 11 条。
如果 `entity_id` 指向的是 `device.id` 而不是 `device_profile.id`，
告警只在那一台设备上生效，同档案的其它设备不会继承。

### 14.11 ⚠ 自查：孤儿客户菜单（期望 0 行）

```sql
SELECT cm.name AS 菜单名, cm.scope AS 作用域,
       count(*) AS 同名条数,
       count(*) FILTER (WHERE cm.assignee_type <> 'ALL') AS 其中未绑定
FROM custom_menu cm
GROUP BY cm.name, cm.scope
HAVING count(*) > 1
ORDER BY 同名条数 DESC;
```

**有结果说明什么**：每次重装 / 每次 repair-init 都会新增一条同名菜单而没删旧的。

**根因**（已修）：早先 `removeExisting` 按 `customer_id` 判断归属，
但客户菜单的 `custom_menu.customer_id` 恒为 NULL_UUID，一条都删不掉。
现在 `removeCustomerMenu` 按「客户实体当前引用的 + 未被任何客户引用的同名孤儿」两步清理。

**修法**：跑一次「平台自检 → 一键修复初始化」，或重装。

### 14.12 数据量与磁盘

```sql
-- ts_kv 是按月分区的，直接查父表会是 0 字节，必须统计分区
SELECT
  (SELECT count(*) FROM ts_kv)                  AS 遥测点数,
  (SELECT count(DISTINCT entity_id) FROM ts_kv) AS 有数据的实体数,
  (SELECT pg_size_pretty(sum(pg_total_relation_size(c.oid)))
     FROM pg_inherits i
     JOIN pg_class p ON p.oid = i.inhparent
     JOIN pg_class c ON c.oid = i.inhrelid
    WHERE p.relname = 'ts_kv')                  AS ts_kv_总占用,
  pg_size_pretty(pg_database_size(current_database())) AS 整库占用;

-- 分区清单（看有没有该建的新月份分区）
SELECT child.relname AS 分区, pg_size_pretty(pg_total_relation_size(child.oid)) AS 大小
FROM pg_inherits
JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
JOIN pg_class child  ON pg_inherits.inhrelid  = child.oid
WHERE parent.relname = 'ts_kv'
ORDER BY child.relname;
```

### 14.13 ⚠ 自查：长时间没上报的设备（超过 60 分钟）

```sql
SELECT d.name AS 设备,
       dp.name AS 档案,
       to_char(to_timestamp(max(kv.ts)/1000) AT TIME ZONE 'Asia/Shanghai','MM-DD HH24:MI') AS 最后上报,
       round(extract(epoch FROM (now() - to_timestamp(max(kv.ts)/1000)))/60) AS 已停分钟
FROM device d
JOIN device_profile dp ON dp.id = d.device_profile_id
LEFT JOIN ts_kv kv     ON kv.entity_id = d.id
GROUP BY d.name, dp.name
HAVING max(kv.ts) IS NULL
    OR now() - to_timestamp(max(kv.ts)/1000) > interval '60 minutes'
ORDER BY 已停分钟 DESC NULLS LAST;
```

**虚拟表**（名字里带「虚拟」）本来就不上报，长期出现属正常。
其余设备出现在这里，说明网关/RTU 掉线或上报键名不对。

### 14.14 ⚠ 自查：上报了但字典里没有的键（报表认不出）

```sql
SELECT k.key AS 遥测键,
       count(DISTINCT kv.entity_id) AS 设备数,
       count(*) AS 数据点数
FROM ts_kv kv
JOIN key_dictionary k  ON k.key_id = kv.key
JOIN device d          ON d.id = kv.entity_id
JOIN device_profile dp ON dp.id = d.device_profile_id
WHERE k.key NOT IN (            -- 后端派生量，本就不在字典里
        'idle_exceed','idle_energy','idle_avg_power','idle_delta_count','work_energy',
        'load_rate','carbon_emission','energy_day','energy_used_day',
        'energy_reverse_day','demand_max','demand_reverse_max')
  AND NOT EXISTS (
        SELECT 1 FROM asset lib
        JOIN relation r     ON r.from_id = lib.id AND r.relation_type='Contains'
                            AND r.relation_type_group='COMMON'
        JOIN asset kind     ON kind.id = r.to_id
        JOIN attribute_kv pd ON pd.entity_id = kind.id
                            AND pd.attribute_key = (SELECT key_id FROM key_dictionary WHERE key='paramDict')
        CROSS JOIN LATERAL jsonb_array_elements(pd.json_v::jsonb->'params') p
        CROSS JOIN LATERAL jsonb_array_elements(coalesce(p->'children','[]'::jsonb)) ch
        WHERE lib.type = 'energy_type_library' AND ch->>'key' = k.key
      )
GROUP BY k.key ORDER BY 数据点数 DESC;
```

**有结果说明什么**：设备上报了一个字典里没声明的键。
数据照样存库，但所有报表都不认它 —— 表现为「设备有数据、图表全空」，**且不报错**。

**本版实测**剩下 3 个（都不是问题）：
`energy_deep`（深谷电量，字典待补）、`humidity` / `temperature`（温湿度传感器，非能源计量）。
如果出现电压/电流/功率之类的键，就是设备的字段映射配错了。

### 14.15 客户菜单配置

```sql
SELECT cm.name AS 菜单名, cm.scope AS 作用域, cm.assignee_type AS 分配给,
       c.title AS 绑定客户,
       jsonb_array_length(cm.config::jsonb->'items') AS 一级项数
FROM custom_menu cm
LEFT JOIN customer c ON c.custom_menu_id = cm.id
ORDER BY cm.scope, cm.name;
```

**期望**：租户菜单 `默认导航（能源管理）` 11 项；
客户菜单 `业务导航（能源管理）` 13 项且绑定到客户。
客户菜单项数若为 0，说明配置没写进去（客户登录会看到默认菜单，不是能源菜单）。

### 14.16 一个客户的数据落在哪些表（入驻后自查）

给客户开通后，用客户 ID 就能把这套数据全部串起来。

| 表 | 里面是什么 | 关键列 |
| --- | --- | --- |
| `customer` | 客户主体 | `title` = 客户名，`custom_menu_id` → 菜单 |
| `tb_user` | 客户管理员账号 | `authority = 'CUSTOMER_USER'`，`customer_id` |
| `user_credentials` | 密码哈希 | `user_id` + bcrypt |
| `asset` | 场站 / 分项 / 维度根 / 拓扑图 | `type`：`场站` `分项` `energy_item_library` `topology` |
| `device` | 设备（普通 + 虚拟） | `additional_info->>'deviceVirtual'` = real / virtual |
| `device_credentials` | 每台设备一个接入令牌 | `credentials_id`（发给现场装 RTU） |
| `relation` | 实体关系 | `relation_type = 'Contains'`（拓扑连线写的就是它） |
| `attribute_kv` | 设备/资产属性 | `attribute_type = 2`（SERVER_SCOPE） |
| `ts_kv` | 遥测（**按月分区**） | `entity_id` + `key` + `ts` + `dbl_v` |
| `dashboard` | 看板副本 | `customer_id` = 该客户（**不是** `assigned_customers`） |
| `custom_menu` | 客户菜单 13 项 | 归属走 `customer.custom_menu_id`（菜单的 `customer_id` 恒为 NULL_UUID） |
| `entity_group` / `group_permission` | 场站级用户授权（可选） | 只有授过场站权限的客户才非空 |

**一、客户总览（一行看全）**

```sql
SELECT c.title AS 客户,
       (SELECT count(*) FROM asset  WHERE customer_id = c.id AND type='场站')     AS 场站,
       (SELECT count(*) FROM asset  WHERE customer_id = c.id AND type='分项')     AS 分项,
       (SELECT count(*) FROM device WHERE customer_id = c.id)                     AS 设备,
       (SELECT count(*) FROM asset  WHERE customer_id = c.id AND type='topology') AS 拓扑,
       (SELECT count(*) FROM dashboard WHERE customer_id = c.id)                  AS 看板,
       (SELECT count(*) FROM tb_user WHERE customer_id = c.id)                    AS 用户
FROM customer c ORDER BY c.created_time;
```

**期望**（演示数据）：场站 2 / 分项 12 / 设备 21 / 拓扑 2 / 看板 20 / 用户 1。

**二、设备清单（含虚拟标记与所属场站）**

```sql
SELECT d.name AS 技术名, d.label AS 显示名, d.type AS 档案,
       d.additional_info::jsonb->>'deviceVirtual' AS 虚拟,
       left(d.additional_info::jsonb->>'siteId', 8) AS 场站
FROM device d WHERE d.customer_id = '<客户id>'
ORDER BY d.name;
```

> `name` 带「·客户名」后缀（租户内唯一约束），`label` 是干净显示名。
> 界面读 `label`。

**三、设备接入令牌（现场装 RTU 用）**

```sql
SELECT d.name, dc.credentials_id AS 令牌, dc.credentials_type
FROM device d JOIN device_credentials dc ON dc.device_id = d.id
WHERE d.customer_id = '<客户id>'
ORDER BY d.name;
```

**四、遥测数据量与时间范围**

```sql
-- ts_kv 按月分区，父表 0 字节 —— 必须查分区（这里查的就是分区，PG 会自动并）
SELECT count(*) AS 数据点,
       to_timestamp(min(ts)/1000) AS 最早,
       to_timestamp(max(ts)/1000) AS 最新
FROM ts_kv
WHERE entity_id IN (SELECT id FROM device WHERE customer_id = '<客户id>');
```

**五、抽查最近上报（判断 RTU 是否真在传数）**

```sql
-- ★ ts_kv.key 是**整数**（key id），不是键名字符串。
--   必须 join key_dictionary 才能按 'energy' 过滤 —— 直接写 t.key='energy'
--   会报 invalid input syntax for type integer（实测 2026-10-22）。
SELECT to_timestamp(t.ts/1000) AS 时间, d.label AS 设备, k.key AS 键, t.dbl_v AS 值
FROM ts_kv t
JOIN device d ON d.id = t.entity_id
JOIN key_dictionary k ON k.key_id = t.key
WHERE d.customer_id = '<客户id>'
  AND k.key = 'energy'
  AND t.ts > (extract(epoch from now()) - 86400) * 1000
ORDER BY t.ts DESC LIMIT 20;
```

**六、拓扑图与它挂的场站**

```sql
SELECT a.name AS 技术名, a.label AS 显示名,
       a.additional_info::jsonb->>'siteId' AS 场站id,
       a.additional_info::jsonb->>'viewType' AS 视图
FROM asset a WHERE a.customer_id = '<客户id>' AND a.type = 'topology';
```

**七、客户菜单项数**

```sql
SELECT cm.name AS 菜单名,
       jsonb_array_length(cm.config::jsonb->'items') AS 菜单项数,
       (cm.config::jsonb->'items'->0->>'id') AS 第一项id,
       (cm.config::jsonb->'items'->0->>'type') AS 第一项类型
FROM customer c JOIN custom_menu cm ON cm.id = c.custom_menu_id
WHERE c.id = '<客户id>';
```

> 第一项必须是 `id = 'home'` / `type = 'HOME'` —— 否则客户登录会落在空门户页。

**八、复制给客户的看板**

```sql
SELECT title FROM dashboard WHERE customer_id = '<客户id>' ORDER BY title;
```

### 14.17 删数据前的确认（危险操作）

```sql
-- 1. 先看清楚要删什么（以客户为例）
SELECT id, title FROM customer WHERE title = '星河工业园';

-- 2. 该客户名下有多少东西（删客户会把这些**全部删掉**）
SELECT '资产' AS 类型, count(*) FROM asset  WHERE customer_id = '<客户id>'
UNION ALL
SELECT '设备',        count(*) FROM device WHERE customer_id = '<客户id>'
UNION ALL
SELECT '看板',        count(*) FROM dashboard WHERE customer_id = '<客户id>'
UNION ALL
SELECT '用户',        count(*) FROM tb_user WHERE customer_id = '<客户id>';

-- 3. 遥测数据量大，先看量再决定
SELECT count(*) FROM ts_kv WHERE entity_id IN (
    SELECT id FROM device WHERE customer_id = '<客户id>');
```

> **删客户 = 级联硬删，不是置空。**
>
> 实测 + 代码双重确认（`CustomerServiceImpl#deleteCustomer`，2026-10-22）：
> 删客户会依次删掉该客户的
> 看板 / 实体视图 / 资产 / 设备 / Edge / Agent / 用户 /
> 调度事件 / 报表 / 报表模板 / 实体组 / 角色，
> 最后才删客户本身。
>
> 代码依据：
> ```java
> dashboardService.deleteDashboardsByTenantIdAndCustomerId(...);
> assetService.deleteAssetsByTenantIdAndCustomerId(...);
> deviceService.deleteDevicesByTenantIdAndCustomerId(...);
> userService.deleteCustomerUsers(...);
> ```
>
> **所以「删掉重建」是安全的清理手段**：不会留下无主资产。
> 唯一不删的是 `ts_kv` 里的历史遥测（按 device id 存，设备删了数据仍在），
> 需要单独按时间分区清理。
>
> 反过来说：**误删客户 = 客户的所有演示数据和自建架构一起没了**，
> 删之前务必先备份（`backups/backup-db.sh`）。

### 14.18 自建表健康检查（部署后必查一次）

**先看表在不在** —— 这是「功能报 500」的第一嫌疑：

```sql
SELECT t AS 表名,
       CASE WHEN to_regclass('public.'||t) IS NULL THEN '✗ 缺失'
            ELSE '✓ 存在' END AS 状态
FROM unnest(ARRAY['meter_reading_batch','meter_reading_record',
                  'billing','billing_detail','tb_sync_log']) AS t;
```

**期望 5 行全是「✓ 存在」**。任何一行缺失 → 看服务启动日志：

```bash
docker compose logs energy-server | grep 'energy-schema'
```

- 有 `能源自建表补齐：新建 N 个对象` → 已经自动补上了，重查即可
- 完全没有这行 → 服务没跑建表逻辑（jar 是旧的），或建表抛异常
- 有 `能源自建表补齐失败` → 后面跟了具体错误，按错误处理

**手动补建**（一般不需要，重启服务即可）：

```bash
docker compose restart energy-server
sleep 30 && docker compose logs energy-server | grep energy-schema
```

**看分区是否够用**（抄表明细按月分区，跨月前必须有下个月的分区）：

```sql
SELECT c.relname AS 分区名,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS 大小,
       (SELECT count(*) FROM pg_class i
         WHERE i.relname LIKE c.relname || '_%' AND i.relkind = 'i') AS 索引数
FROM pg_class c
WHERE c.relname LIKE 'meter_reading_record_%' AND c.relkind = 'r'
ORDER BY c.relname;
```

**每个分区都应该有 4 个索引**（batch_id / device_id+reading_time / period /
period+quality）。索引数为 0 说明分区是手工建的、没继承索引 ——
数据一多就全表扫。

**分区不连续会怎样**：写入落在没有分区的月份 → 报
`no partition of relation "meter_reading_record" found for row`。
服务写入前会调 `energy_ensure_reading_partition()` 自动补，
所以正常情况下不会遇到；但如果那个函数被删了就会。

**函数在不在**（`Controller` 每次抄表都会调它）：

```sql
SELECT p.proname AS 函数名,
       pg_get_function_arguments(p.oid) AS 参数
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'energy_ensure_reading_partition';
```

期望 1 行，参数是 `month_start date`。

---

### 14.19 抄表数据怎么查（客户 / 运维都会问）

**最近的抄表批次**（每次「一键抄表」一行）：

```sql
SELECT id,
       period                                  AS 账期,
       trigger_type                            AS 触发方式,
       status                                  AS 状态,
       total                                   AS 总数,
       normal_count                            AS 正常,
       missing_count                           AS 缺数,
       abnormal_count                          AS 异常,
       to_timestamp(started_time/1000)         AS 开始时间,
       round((coalesce(finished_time, started_time) - started_time)/1000.0, 1) AS 耗时秒
FROM meter_reading_batch
ORDER BY started_time DESC
LIMIT 20;
```

看什么：
- `状态` 一直是 `running` 且耗时很久 → 批次卡住了
- `缺数 + 异常` 占比高 → 设备没上报或表底倒走，去查设备

**某账期每位表计的读数**：

```sql
SELECT r.device_name              AS 设备,
       r.meter_no                 AS 表号,
       r.period                   AS 账期,
       r.prev_reading             AS 上期,
       r.curr_reading             AS 本期,
       r.usage                    AS 用量,
       r.unit                     AS 单位,
       r.quality                  AS 质量,
       r.source                   AS 来源,
       CASE WHEN r.field_value IS NOT NULL THEN r.field_value END AS 现场补抄值
FROM meter_reading_record r
WHERE r.period = to_char(now(), 'YYYY-MM')
ORDER BY r.device_name;
```

`quality` 取值：`normal` 正常 / `missing` 无数据 / `abnormal` 倒走或突变。
`source` 取值：`auto` 系统算 / `field` 现场补抄。

**异常读数清单**（要人工核对的）：

```sql
SELECT r.period          AS 账期,
       r.device_name     AS 设备,
       r.prev_reading    AS 上期,
       r.curr_reading    AS 本期,
       r.usage           AS 用量,
       r.quality         AS 质量,
       r.note            AS 说明
FROM meter_reading_record r
WHERE r.quality <> 'normal'
ORDER BY r.period DESC, r.device_name
LIMIT 100;
```

**用能与原始遥测交叉核对**（判断报表准不准）：

```sql
-- 逐设备对比：抄表用量 vs 原始遥测合计（同一台表、同一个月）
WITH m AS (
    SELECT device_id, coalesce(sum(usage), 0) AS meter_usage
    FROM meter_reading_record
    WHERE period = to_char(now(), 'YYYY-MM')
    GROUP BY device_id
), t AS (
    SELECT t.entity_id AS device_id, round(sum(t.dbl_v)::numeric, 2) AS telemetry_usage
    FROM ts_kv t
    JOIN key_dictionary k ON k.key_id = t.key
    WHERE k.key = 'energy'
      AND t.ts >= extract(epoch from date_trunc('month', now())) * 1000
      AND t.ts <  extract(epoch from date_trunc('month', now()) + interval '1 month') * 1000
    GROUP BY t.entity_id
)
SELECT d.name                       AS 设备,
       coalesce(m.meter_usage, 0)   AS 抄表用量,
       coalesce(t.telemetry_usage, 0) AS 遥测合计,
       round(coalesce(m.meter_usage,0) - coalesce(t.telemetry_usage,0), 2) AS 差额
FROM m
FULL JOIN t ON t.device_id = m.device_id
LEFT JOIN device d ON d.id = coalesce(m.device_id, t.device_id)
ORDER BY abs(coalesce(m.meter_usage,0) - coalesce(t.telemetry_usage,0)) DESC
LIMIT 20;
```

要查单台设备，把 `WHERE period = ...` 后面加一句
`AND device_id = '真实设备uuid'` 即可（uuid 从「设备」列表里复制）。

> **两者对不上是正常的**，前提是知道口径：
> 抄表用量 = **本期表底 − 上期表底**；遥测 `energy` 是**每次上报的增量**。
> 有补抄（`field_value`）或表底倒走时，两者必然有差。
> 真正要一致的是「同一口径」的比较 —— 见 06-verify-e2e 的整点过滤说明。

---

### 14.20 手工填报数据怎么查

手工填报的值存在两处，别查错地方：

| 位置 | 存什么 | 用途 |
| --- | --- | --- |
| `meter_reading_record.field_value` | 现场补抄的表底值 | 与系统值并列保存，便于对比审计 |
| `ts_kv`（虚拟设备） | 月度汇总值 | 报表与看板读这里 |

**某场站某年的填报记录**：

```sql
SELECT r.period           AS 账期,
       r.device_name      AS 设备,
       r.field_value      AS 填报值,
       r.field_status     AS 填报状态,
       to_timestamp(r.field_time/1000) AS 填报时间,
       r.field_note       AS 备注
FROM meter_reading_record r
WHERE r.customer_id = '<客户id>'
  AND r.field_value IS NOT NULL
  AND r.period LIKE to_char(now(), 'YYYY') || '%'
ORDER BY r.period DESC, r.device_name;
```

查往年就把 `to_char(now(), 'YYYY')` 换成具体年份字符串（如 `'2025'`）。

**填报了但没进遥测**（虚拟设备应当同步到 `ts_kv`）：

```sql
-- 找出有填报值、但该设备本月没有遥测点的记录
SELECT r.period, r.device_name, r.field_value
FROM meter_reading_record r
WHERE r.field_value IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM ts_kv t
    WHERE t.entity_id = r.device_id
      AND t.ts >= extract(epoch from to_date(r.period || '-01', 'YYYY-MM-DD')) * 1000
      AND t.ts <  extract(epoch from to_date(r.period || '-01', 'YYYY-MM-DD') + interval '1 month') * 1000
  )
ORDER BY r.period DESC;
```

期望 0 行。有行说明填报值只写进了自建表、没同步到遥测 ——
看板会显示 0，但台账里明明填了。

---

### 14.21 账单与同步日志

**账单按月汇总**（平台当前免费，一般没有数据，表可以空着）：

```sql
SELECT period       AS 账期,
       energy       AS 品种,
       count(*)     AS 单数,
       round(sum(amount), 2)   AS 合计金额,
       round(sum(usage), 2)    AS 合计用量,
       status       AS 状态
FROM billing
GROUP BY period, energy, status
ORDER BY period DESC, energy;
```

`status` 取值：`draft` 草稿 / `published` 已发布 / `paid` 已付。

**账单明细**（默认取最新一张账单，按费率拆开）：

```sql
SELECT d.line_type  AS 行类型,
       d.name       AS 项目,
       d.usage      AS 用量,
       d.price      AS 单价,
       d.amount     AS 金额
FROM billing_detail d
JOIN billing b ON b.id = d.billing_id
WHERE d.billing_id = (
        SELECT id FROM billing ORDER BY created_time DESC LIMIT 1
      )
ORDER BY d.created_time;
```

**同步失败记录**（有异常才需要看）：

```sql
SELECT sync_type        AS 同步类型,
       source_entity    AS 源类型,
       source_id        AS "源ID",
       status           AS 状态,
       retry_count      AS 重试次数,
       error_msg        AS 错误,
       to_timestamp(created_time/1000) AS 时间
FROM tb_sync_log
WHERE status <> 'synced'
ORDER BY created_time DESC
LIMIT 50;
```

期望 0 行。有行说明某次同步失败了，`error_msg` 里有原因。

---

### 14.22 一次完整的「部署后自检」SQL（复制即用）

按顺序跑，每段都有明确期望值。

```sql
-- ① 自建表齐不齐（期望 5 行「✓ 存在」）
SELECT t AS 表名,
       CASE WHEN to_regclass('public.'||t) IS NULL THEN '✗ 缺失' ELSE '✓ 存在' END AS 状态
FROM unnest(ARRAY['meter_reading_batch','meter_reading_record',
                  'billing','billing_detail','tb_sync_log']) AS t;

-- ② 分区函数在不在（期望 1 行）
SELECT count(*) AS 分区函数数
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname='public' AND p.proname='energy_ensure_reading_partition';
-- 期望 1

-- ③ 分区覆盖到哪个月（当前月与下月必须在）
SELECT c.relname AS 分区
FROM pg_class c
WHERE c.relname LIKE 'meter_reading_record_%' AND c.relkind='r'
ORDER BY c.relname;

-- ④ 租户级主数据在不在（期望 4 / 4 / 16 / 8）
SELECT '能源品种' AS 项目, count(*) AS 数量 FROM asset
  WHERE customer_id='13814000-1dd2-11b2-8080-808080808080' AND type='default'
UNION ALL SELECT '分时方案', count(*) FROM asset
  WHERE customer_id='13814000-1dd2-11b2-8080-808080808080' AND type='tou_scheme'
UNION ALL SELECT '资产档案', count(*) FROM asset_profile
UNION ALL SELECT '设备档案', count(*) FROM device_profile;

-- ⑤ 菜单装没装（期望 2 行，项数 11 与 13）
SELECT scope AS 层级, name AS 菜单名,
       jsonb_array_length(config::jsonb->'items') AS 顶层项数
FROM custom_menu
WHERE name LIKE '默认导航%' OR name LIKE '业务导航%';

-- ⑥ 有没有孤儿菜单（期望 0）
SELECT count(*) AS 悬空引用
FROM customer c
WHERE c.custom_menu_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM custom_menu cm WHERE cm.id = c.custom_menu_id);

-- ⑦ 遥测有没有在写（期望 > 0）
SELECT count(*) AS 近一小时数据点
FROM ts_kv
WHERE ts > (extract(epoch from now()) - 3600) * 1000;
```

> 只看「有没有」而不看「多少」时，用 `count(*) > 0` 而不是精确值 ——
> 演示数据会随时间增长，写死数字的断言迟早会红。

### 现象 P：全新库安装到「建库」就失败，容器起不来

**报错**（`/tmp/energy-install.log`）：

```
Parameter N of constructor in com.guard.server.service.energy.XxxService
required a bean of type 'com.guard.server.service.security.permission.OwnersCacheService'
that could not be found.
APPLICATION FAILED TO START
```

**为什么只有全新库会这样**：install 阶段的 `ThingsboardInstallApplication`
只扫描少数包（含 `service.energy`，因为要用 `EnergyBootstrapInstaller`），
**不含** `service.security.permission`。库里已经装好的环境跑的是运行时应用
（扫描范围全），所以永远看不到这个错 —— 一清库就必失败。

**判定**：报错里出现 `required a bean of type` 且类型不在下面这几个包内，
就是这个问题：

```
com.guard.server.dao.*            ✓ 在扫描范围
com.guard.server.service.energy.*  ✓ 在扫描范围（同包互相依赖没问题）
其它 service.*                     ✗ 不在范围
```

**修法**（改代码，不是改配置）：把该依赖改成可选，并在用到的地方显式判空：

```java
@Autowired(required = false)
private OwnersCacheService ownersCacheService;

if (ownersCacheService == null) {
    throw new IllegalStateException("OwnersCacheService 未装配，当前环境不应执行出账");
}
```

**不要**把缺的包直接加进 `@ComponentScan` —— 那些包里的组件依赖运行时缓存/队列，
install 阶段装不起来，会变成一串新的报错。

> 这条已写进代码注释。往 `service.energy` 加新类时，先看它的字段：
> 有没有非 `dao` / 非本包的 Service。

### 现象 Q：重装脚本自己崩了，`APP_HOME: unbound variable`

```
docker-00-prepare.sh: line 291: APP_HOME: unbound variable
✗ 组装部署目录失败
```

脚本开了 `set -u`，而写 `.env` 的 heredoc 里有一行注释含 `${APP_HOME}` ——
bash 在写文件前就展开了它，而这个变量只存在于**生成出来的** .env 里。

**修法**：heredoc 里想输出字面量变量一律转义：`\${APP_HOME}`。

**自查**：改完任何 `docker-0*.sh` 后跑一次 `bash -n`，再走一遍全新重装。

### 现象 R：装完自检 `missing=2`（费率 + 电表 Key 节点）

全新库装完，自检报：

```
MISSING  费率配置（出账前提）   0 / 1
MISSING  电表 Key 标准化节点    0 / 1
```

**先确认版本**：这两项现在由「建客户」自动完成（`onCreateCustomer`）。
如果装完仍是 MISSING，说明 jar 是旧版本 —— 换成新 jar 后点一次
「平台自检 → 一键修复初始化」即可补齐，不用重装。

**这两项缺失的实际后果**：

- 缺费率 → 出账每一台都「未配置电价」跳过，**账单页永远空**
- 缺 Key 节点 → RTU 发的 `U`/`I`/`P`/`Ep` 原样落库，报表「只是没数据」

**验证**（租户账号）：

```bash
curl --noproxy '*' -s -H "X-Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8090/api/energy/self-check | jq '.summary'
# 期望 {"missing":0,"partial":0,"healthy":true}
```

### 现象 S：跑完 06 验收再跑 04，报「Σ峰谷 == energy 不符」

```
✗ 1 处不符：('单相园-1#进线总表', 1792721470731, 0.0, 1.23)
```

`1.23` 是 06 的「数据上报」节写进演示设备的测试值 —— 它有 `energy` 但没有
`energy_tip/peak/flat/...` 分量，破坏了演示数据的守恒关系。

**产品没坏，是验收污染了数据**。新版本 06 已改用临时设备（用完即删），
不会再出现。旧版本留下点的话，按下面清掉：

```sql
DELETE FROM ts_kv t USING key_dictionary k, device d
WHERE t.key = k.key_id AND t.entity_id = d.id
  AND d.name LIKE '%进线总表%'
  AND k.key IN ('energy','power_total','voltage_a')
  AND mod(t.ts, 3600000) <> 0;      -- 非整点 = 手工注入的测试点
```

> 判据是「非整点」：演示数据全部落在整点，测试上报落在任意时刻。

---

### 现象 T：客户登录后，仪表板大量部件是 0.0 或「无数据」

```
今日用电量  0.0
本月用电量  0.0
今年用电量  0.0
总用电量    0.0
历史用电量详细：所选范围内无数据
```

而接口全返回 `200`。

**先分清三种情况**，别一上来就怀疑权限：

**① 部件本来就要用户先选范围**

「实时能耗」「我的账单」「抄表功能」等页面上半部分是「查询设置」，
必须勾选设备（或保持「不勾选 = 看当前品种全部」）后才出数。
这类页面首次打开是空白的，属于交互设计，不是故障。

判据：页面顶部有「查询设置 / 场站 / 能源品种 / 勾选设备」区块。

**② 设备有数，但资产没有汇总值**

设备列表里能看见数据，场站页和概览页却是 0 —— 这是 `energy_total` 没算。

一条 SQL 定位：

```sql
-- 场站/分项有没有汇总点
SELECT a.name, a.type,
       count(*) FILTER (WHERE kd.key='energy_total') AS 汇总点数
FROM asset a
LEFT JOIN ts_kv t ON t.entity_id = a.id
LEFT JOIN key_dictionary kd ON kd.key_id = t.key
WHERE a.customer_id = '<客户id>' AND a.type IN ('场站','分项','组织')
GROUP BY a.name, a.type ORDER BY 汇总点数;
```

汇总点数为 0 → 等一轮定时任务（默认每小时），或立刻手工重算：

```bash
curl -s -X POST -H "X-Authorization: Bearer $TOKEN" \
  'http://127.0.0.1:8090/api/energy/asset-totals/rebuild' \
  -H 'Content-Type: application/json' -d '{"days":2}'
```

确认定时任务在跑：

```bash
docker logs energy-server 2>&1 | grep "资产汇总刷新完成"
# [energy] 资产汇总刷新完成：2 个客户 / 26 个资产，耗时 5172 ms
```

**③ 部件把「品种资产」当成了取数实体（旧部件才有）**

根规则链和数据库都正常，但部件发的是：

```
GET /api/plugins/telemetry/ASSET/<品种资产id>/values/timeseries?keys=energy_total
→ 200 {}
```

「电能」这类品种资产只有 `paramDict` 属性，**没有任何遥测**。

确认是不是这个原因：

```bash
docker exec energy-postgres psql -U postgres -d thingsboard -tAc "
SELECT fqn,
       (descriptor::jsonb->>'controllerScript') LIKE '%fromKind%' AS 旧逻辑
FROM widget_type
WHERE fqn IN ('energy_management.overview_stats',
              'energy_management.calendar_heatmap',
              'energy_management.asset_stats_chart');"
```

`旧逻辑 = t` → 部件版本旧，重新部署 `energy_management.*` 三个部件
（种子在 `guard-server/src/main/data/json/system/widget_types/`，
挂载在 `$APP_HOME/data/json/system/widget_types/`，运行库在 `widget_type.descriptor` ——
**三处都要更新**，否则重启会回退）。

**④ 数字偏大 / 偏小**

先看日聚合桶边界是否对齐零点。起点若是「现在往前推 400 天」这种任意时刻，
「今天」的桶会跨到昨天，实测多算 16.6 kWh（83.4 vs 66.81）。

详细原理与修复见[⑦ 数据流第六节](/admin/data-pipeline)。

**一条命令覆盖 ②③**：

```bash
python3 scripts/27-customer-surface-probe.py \
  --base http://127.0.0.1:8090 \
  --tenant tenant@126.com --tenant-pass 12345678 \
  --customer customer@126.com --customer-pass 12345678 --strict
```

它现在不只判 4xx，还会断言：

- **S1** 设备有遥测 → 所属场站的 `energy_total` 必须非空
- **S2** 看板 alias 不能把品种/字典资产当取数实体

> 这条断言是 2026-10-23 补的。此前探针只把 `401/403/5xx` 判失败，
> `200 + {}` 算通过 —— 于是「295 条全通、页面全 0」同时成立，误导了验收。

---

### 现象 U：切到 Cassandra 后，验收脚本大面积报「0 台 / 没有数据」

```
✗ 单相电表 ≥ 1 台  — 0 台
✗ 三相电表 ≥ 1 台  — 0 台
✗ 资产上没有 energy_total（看板选场站会是空的）
✗ 峰谷分析无法核对（设备无整点表底）
✗ idle_exceed 时序点：实际 0，至少 1
```

而设备列表里明明有 21 台，页面也正常出数。

**产品没坏，是验收脚本看错了库。**

验收脚本（`04/06/08`）里写的是直查 SQL：

```sql
SELECT d.name, k.key, t.ts, t.dbl_v
  FROM ts_kv t
  JOIN key_dictionary k ON k.key_id = t.key
  JOIN device d ON d.id = t.entity_id
 WHERE k.key IN ('energy', 'energy_reading')
 LIMIT 5;
```

这是按「遥测存 Postgres」写的。默认后端换成 Cassandra 后，**PG 里没有 `ts_kv` 表**，
于是 `04` 的 `devs`（从遥测列表派生）为空 → 所有设备统计归零。

**一条命令验证是不是这个原因**：

```bash
docker compose --profile split exec -T postgres psql -U postgres -d thingsboard -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_name='ts_kv';"
# sql 后端 → 1
# cassandra 后端且没做过镜像 → 0
```

**修法**：

```bash
bash scripts/ts-mirror.sh          # 导出 Cassandra 遥测 → PG 镜像 + ts_kv 视图（约 40 秒）
bash scripts/04-verify-data.sh     # 重跑
```

`04/06/08` 开头已自动调用 `ts-mirror.sh`。如果它没生效，先看文件在不在：

```bash
ls -la scripts/ts-mirror.sh
# 不存在 → 重装时 prepare 漏拷，手工补：
cp <仓库>/shiyongshouce/downloads/scripts/ts-mirror.sh scripts/
```

原理见[②b Cassandra · 四之二](/admin/cassandra)。

**另一个容易误判的**：

```bash
docker exec energy-cassandra cqlsh -e "SELECT count(*) FROM thingsboard.ts_kv_cf;"
# ReadFailure: ... received 0 responses and 1 failures
```

Cassandra 全表 `count(*)` 会读超时，**不是数据坏了**。用 `nodetool tablestats`
或 `scripts/ts-mirror.sh`。

---

### 现象 V：清除演示数据后再初始化，看板全变「部件无数据可显示」

```
能耗概览：今日用电量 0.0 / 本月 0.0 / 日历「所选范围内无数据」
而接口查场站 energy_total 有值
```

**根因：看板 alias 指向了已删除的旧场站 uuid。**

```
清除 → 场站被删
重新初始化 → 生成新 uuid 的场站
看板 entityAliases 里存的还是旧 uuid → 部件查一个不存在的实体
```

一条 SQL 确认：

```sql
-- 看板 alias 指向的实体还在不在
SELECT d.title, a.value->>'alias' AS alias,
       a.value->'filter'->'singleEntity'->>'id' AS 实体id
FROM dashboard d, LATERAL jsonb_each(d.configuration::jsonb->'entityAliases') a
WHERE d.customer_id = '<客户id>'
  AND (a.value->'filter'->'singleEntity'->>'id') IS NOT NULL
  AND (a.value->'filter'->'singleEntity'->>'id') NOT LIKE '00000000-%'
  AND NOT EXISTS (SELECT 1 FROM asset x WHERE x.id = (a.value->'filter'->'singleEntity'->>'id')::uuid);
-- 有行 = 悬空引用
```

> `00000000-…` 开头的是**有意保留**的占位哨兵（品种/字典），不是悬空，别一起报。

**修法**（2026-10-23 版已自动闭环）：

| 阶段 | 平台动作 |
| --- | --- |
| 清除时 | 把场站引用还原成占位符 `00000000-…-0000000005a1` |
| 初始化时 | 对**已存在**的看板重新填占位符（旧逻辑直接跳过） |

已经在旧版本上踩了的，**再点一次「初始化演示数据」即可**（不用清库）：

```
[energy] 已为客户 某某公司 处理 6 个仪表板（新建 0 / 重绑场站 6，共 20 个模板）
```

确认重绑成功：

```bash
# 看板 alias 的场站 id 应与当前场站一致
docker exec energy-postgres psql -U postgres -d thingsboard -tAc "
SELECT configuration::jsonb->'entityAliases' FROM dashboard
 WHERE customer_id='<客户id>' AND title='能耗概览';"
docker exec energy-postgres psql -U postgres -d thingsboard -tAc "
SELECT id, name FROM asset WHERE customer_id='<客户id>' AND type='场站';"
```

详细原理见[⑦ 数据流 6.6](/admin/data-pipeline)。

---

### 现象 W：顶栏写着「数据源（10 台）」，下面所有数字都是 0

```
范围：数据源（10 台） · 当前 8 台计量点
综合能源消费量  0.00 tce
能源费用        ¥ 0
碳排放估算      0.00 tCO₂
能源消耗趋势    当前范围内没有遥测数据
能源品种构成    无数据
```

**这种「台数对、数字全 0」是部件 JS 里的过滤 bug，不是数据问题。**

接口层完全正常：设备有遥测、场站有 `energy_total`、请求全 200。
问题出在部件把设备池算空了。

三个已知原因（2026-10-23 全部修复）：

| 缺陷 | 症状 | 根因 |
| --- | --- | --- |
| `isVirtual` 黑名单 | **台数对、全 0** | `deviceVirtual='real'` 被判成虚拟表 |
| 关系只加载一层 | 台数显示「1 台」 | 场站→分项→设备 只展开第一层 |
| 类型名精确匹配 | 设备被静默跳过 | 类型是「单相电能表」，字典里只有「电能表」 |

**一条命令自查**：

```bash
python3 scripts/27-customer-surface-probe.py \
  --base http://127.0.0.1:8090 \
  --tenant tenant@126.com --tenant-pass 12345678 \
  --customer customer@126.com --customer-pass 12345678 --strict
```

S3 断言会直连 Postgres 扫全部部件的 `controllerScript`：

```
✗ S3 部件虚拟表判据错误（1 条）
    200  energy_management.energy_overview
         → isVirtual 用黑名单判定，deviceVirtual='real' 会被当成虚拟表
```

**手工确认**（不跑探针时）：

```sql
SELECT fqn,
       (descriptor::jsonb->>'controllerScript') LIKE '%=== true%' AS 白名单,
       (descriptor::jsonb->>'controllerScript') LIKE '%expandLevel%' AS BFS
FROM widget_type
WHERE fqn LIKE 'energy_management.%'
  AND (descriptor::jsonb->>'controllerScript') LIKE '%isVirtual%';
-- 期望两列全 t
```

修复要同步**三处**（少一处重启就回退）：

```
① 仓库种子  guard-server/src/main/data/json/system/widget_types/*.json
② 挂载目录  $APP_HOME/data/json/system/widget_types/*.json
③ 运行库    widget_type.descriptor
```

原理与三个缺陷的细节见[⑦ 数据流 6.7](/admin/data-pipeline)。

---

### 现象 Z：Cassandra 无限重启，平台整体 502

**症状**

```
$ docker ps --filter name=energy-cassandra
energy-cassandra   Restarting (0) 3 seconds ago

$ docker inspect -f '{{.RestartCount}}' energy-cassandra
67

$ curl -s --noproxy '*' http://127.0.0.1:8090/api/noauth/setup/state
502 Bad Gateway
```

重启计数一路涨，`9042` 端口拒连，`energy-server` 一直连不上遥测库，
整个平台不可用。容器日志或容器内 `/var/log/cassandra/system.log` 里能看到：

```
ERROR [main] JVMStabilityInspector.java:196 - Exiting due to error while processing commit log during initialization.
org.apache.cassandra.db.commitlog.CommitLogReadHandler$CommitLogReadException:
    Could not read commit log descriptor in file /var/lib/cassandra/commitlog/CommitLog-7-<ts>.log
    at org.apache.cassandra.db.commitlog.CommitLogReader.readCommitLogSegment(CommitLogReader.java:196)
    at org.apache.cassandra.service.CassandraDaemon.setup(CassandraDaemon.java:353)
```

**根因：commitlog 被写到一半就进程被杀。**

Cassandra 先把写入追加到 commitlog（顺序写），再异步刷进 SSTable。
容器被**非优雅终止**时，当前 commitlog 段的头部描述符没落盘，下次启动读到
半截文件就直接退出 —— 而 `restart: unless-stopped` 让它无限重试，形成
「起 → 读到坏文件 → 退出 → 再起」的死循环，**不会自己好**。

常见的非优雅终止来源：

- `docker kill` / `docker stop` 超时后 SIGKILL（默认只等 10 秒）
- 直接强退 Docker Desktop、或 Docker VM 进程被杀
- 宿主机内存压力把 VM 里的 Cassandra 压死（OOM）
- **把 Docker VM 内存调小**（见下方红线）

**判断（三步，约 5 秒）**

```bash
docker inspect -f 'status={{.State.Status}} health={{.State.Health.Status}} restarts={{.RestartCount}}' energy-cassandra
docker logs --tail 200 energy-cassandra 2>&1 | grep -c "Could not read commit log descriptor"
docker exec energy-cassandra sh -c 'tail -60 /var/log/cassandra/system.log' 2>/dev/null | grep -A2 "commit log"
```

只要第三条出现 `CommitLogReadException`，就是本现象。

**恢复：一条命令**

```bash
cd ~/energy-app
bash scripts/12-cassandra-recover.sh --status   # 先诊断
bash scripts/12-cassandra-recover.sh --yes      # 备份 + 清 commitlog + 重启 + 验证
```

它做四件事，**SSTable 一个字节都不动**：

1. 停容器（最多等 180 秒，让它自己收尾）
2. 把整个 `commitlog` 目录备份到 `~/.cassandra-commitlog-backup/<时间戳>/`
3. 只删 `commitlog/*.log`
4. 重启并等健康（最长 10 分钟），验证 `keyspace thingsboard` 可读

代价：最多丢掉最后一次 flush 之后几百毫秒的写入（而坏文件本来就一点都读不出来）。

**预防（已经写进部署，不用你手动做）**

| 措施 | 落点 | 作用 |
| --- | --- | --- |
| `stop_grace_period: 180s` | `docker-compose.yml` 的 cassandra 服务 | 正常关闭时给足 flush 时间，不再 SIGKILL |
| 启动前自愈预检 | `docker-02-start.sh` 第 1.5 步 | 检测到损坏就自动调 12 号脚本，不带病启动 |
| 遥测后端默认 sql | `.env` 的 `DATABASE_TS_TYPE=sql` | 数据量小的时候根本不引入 Cassandra 这个故障点 |

**Docker VM 内存红线（这次故障的直接触发点）**

```
物理内存 8 GB 的机器：Docker VM 不低于 6144 MiB
```

Cassandra 堆 2 GB + 页缓存 + 另外三个容器（Postgres 0.6G / server 1.2G / gateway）
在 3.8 GB 的 VM 里会互相挤压，Cassandra 被反复杀掉就制造 commitlog 损坏。
2026-10-25 实测：把 VM 从 5941 MiB 调到 3931 MiB 后，`RestartCount` 从 0 涨到 67。

**要不要干脆别用 Cassandra？**

数据量在**千万行以内 / 20 GB 以内**，Postgres 存遥测完全够，而且少一个容器、
少 2 GB 常驻内存、少一整类故障。切换方式：

```bash
cd ~/energy-app
bash scripts/11-cassandra.sh disable    # 改 .env + 重启 server，保留 Cassandra 数据
```

⚠ 切换**不迁移存量遥测**：切过去之后旧区间查不到，只有新数据写新后端。
有历史数据要保留时，先按[② Cassandra](/admin/cassandra) 一节的迁移步骤办。

---

### 现象 Y2：分项能耗图例显示的是「设备名」，不是「分项名」

**症状**

```
期望：照明 / 插座 / 给排水 / 炊事 / 蒸汽 / 空调
实际：单相园-照明分项总表 / 单相园-A栋照明回路 / 单相园-插座分项总表 …
```

区域能耗页是对的（显示 A栋办公区 / 食堂 / 公共区域），只有分项能耗页不对。

**原因：树根下移后，遍历深度也跟着变了。**

2026-10-26 为了把「分项」和「区域」两个维度彻底分开，`analysis_bar`
的树根从「场站」下移到「维度容器 → 该场站分组」：

```
修前  场站 → Contains{ 分项, 区域, topology }     ← 两套分类混在一起
修后  用电分项 → 单相场站 → Contains{ 照明, 插座, … }   ← 只有分项
      用能区域 → 单相场站 → Contains{ A栋办公区, … }   ← 只有区域
```

树根变了，`asset_stats_chart` 的 `collectLeafAssets`（向下展开到叶子）
就多下了一层：分项节点下面还有设备，于是它继续展开到设备，
图例变成设备名；而区域节点下面直接挂设备，展开一次正好到区域层
（因为区域本身没有子资产时才算叶子 —— 但区域有设备子节点，所以停在了区域）。

**影响**：只影响图例的**显示层级**，不影响数字 ——
分项能耗与区域能耗的总量仍然一致（各自 4.58 kW·h）。

**要不要改，取决于业务口径**：

| 口径 | 图例 | 适用 |
| --- | --- | --- |
| 停在分项层 | 照明 / 插座 / 炊事 | 看「各类用途耗了多少电」 |
| 展开到设备层 | 照明分项总表 / A栋照明回路 | 看「具体哪块表在走字」 |

现行为「展开到设备层」。若要停在分项层，改
`asset_stats_chart` 的 `collectLeafAssets`：遇到 `type=分项（或区域）`
就把该节点本身当叶子，不再下钻设备。

> 这条是**已知行为、非缺陷**，登记在此是为了下次有人反馈「图例怎么是设备名」
> 时能直接判断是不是这个，而不是当成 bug 重新排查。

---

### 现象 Y3：分项能耗与区域能耗的总量对不上

**症状**

```
分项能耗   5 条   合计 2.66 kW·h   照明 / 插座 / 炊事 / 给排水 / 蒸汽
区域能耗   3 条   合计 4.58 kW·h   公共区域 2.21 / A栋办公区 1.92 / 食堂 0.45
```

同一天、同一批设备，两页合计差了 1.92 kW·h。

**原因：父子表被分到了不同区域，区域合计把两者都算了一遍。**

演示数据的层级是：

```
单相场站
 ├─ 照明（分项）
 │   ├─ 单相园-照明分项总表     1.26 kW·h   ← 该分项的汇总表
 │   └─ 单相园-A栋照明回路       1.12 kW·h   ← 总表下属的回路
 └─ 插座（分项）
     ├─ 单相园-插座分项总表     0.90
     └─ 单相园-A栋插座回路       0.80
```

按名称分区域时：「A栋…回路」进 `A栋办公区`，「…分项总表」没有 A 栋字样、
落到兜底区域 `公共区域`。于是：

```
A栋办公区 = 1.12 + 0.80            = 1.92   ← 只算回路
公共区域 = 1.26 + 0.90 + 0.05(水表) = 2.21   ← 只算总表（其中已含 A栋的量）
合计 4.58 —— 1.92 被算了两次
```

分项页没这个问题：它停在分项层，每个分项只读一张总表，天然不重复。

**这不是维度隔离的缺陷**（`siteChildType` 已把它们分对了），
而是**设备归属**的口径问题：总表与它下属的回路表必须落在同一个区域。

**怎么修，取决于业务口径**：

| 方案 | 做法 | 适用 |
| --- | --- | --- |
| ① 同区域归属 | 区域分配时，「…分项总表」跟随其下属回路所在区域 | 计量层级清晰的现场（推荐） |
| ② 按 meterLevel 去重 | 汇总时只取每棵子树的最上层表 | 已有 `meterLevel`（0 不计入 / 1 总表 / 2 分表）的现场 |
| ③ 区域只放回路表 | 总表不进任何区域，只作分项汇总 | 区域是纯空间概念、总表在配电房 |

演示数据当前用的是「按名称猜」，所以命中了这个问题。
真实客户按现场实际归属配置后不会有这个偏差。

**自查 SQL**（看某区域是否同时含父表与子表）：

```sql
-- 同一区域内，设备的 parentDeviceId 也指向该区域内的另一台设备 → 重复
SELECT p.label AS 父表, c.label AS 子表
FROM device c
JOIN device p ON p.id = (c.additional_info::jsonb->>'parentDeviceId')::uuid
WHERE c.customer_id = '<客户id>'
  AND p.additional_info::jsonb->>'siteId' = c.additional_info::jsonb->>'siteId';
```

> 演示数据目前没有 `parentDeviceId` / `meterLevel`（两列都是空），
> 所以上条 SQL 查不出东西 —— 这正是它无法自动去重的原因：
> 缺少层级信息时，平台只能把每台表都当成独立计量点。

