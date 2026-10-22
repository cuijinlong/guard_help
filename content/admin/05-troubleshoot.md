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
- 输出 **小于 11** → 菜单确实是旧版装的，点**平台自检 → 一键修复初始化**重装。

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

日志位置：

```bash
docker compose logs --tail=200 energy-server | grep -E "ERROR|Caused by"
docker compose logs --tail=100 gateway
```

## 12. 排障通用三件套

```bash
# 1. 端口在不在
lsof -nP -iTCP:8090 -sTCP:LISTEN

# 2. 最近的错误
tail -200 /opt/energy/logs/guard-server.log | grep -E "ERROR|Caused by"

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

### 14.16 删数据前的确认（危险操作）

```sql
-- 1. 先看清楚要删什么（以客户为例）
SELECT id, title FROM customer WHERE title = '星河工业园';

-- 2. 该客户名下的资产 / 设备数量（删客户不会自动删这些）
SELECT '资产' AS 类型, count(*) FROM asset  WHERE customer_id = '<客户id>'
UNION ALL
SELECT '设备',        count(*) FROM device WHERE customer_id = '<客户id>';

-- 3. 删客户后这些实体会变成「无主」，需要单独清理
```

> TB 删除客户只把资产的 `customer_id` 置空，**不删资产**。
> 重装/重建客户时如果看到一堆「无主」资产，就是这个原因。
