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

### 现象 F：租户菜单里没有「能源管理」

**定位**：

```bash
docker compose exec -T postgres psql -U postgres -d thingsboard -tA -c "
SELECT name, scope FROM custom_menu ORDER BY scope;"
```

应有「默认导航（能源管理）」(TENANT) 和「业务导航（能源管理）」(CUSTOMER) 两条。

**修法**：两条都是租户/客户创建时自动装的。缺了只能重建租户/客户，
或手工在平台里新建菜单。


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
