# 故障排查

> 按现象索引。每一条都是本项目真实踩过的坑，给出定位命令、根因和修法。

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

## 5. 新租户仪表板 0 个

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

## 10. 排障通用三件套

```bash
# 1. 端口在不在
lsof -nP -iTCP:8090 -sTCP:LISTEN

# 2. 最近的错误
tail -200 /opt/energy/logs/guard-server.log | grep -E "ERROR|Caused by"

# 3. 状态自检
curl -s --noproxy '*' http://127.0.0.1:8090/api/noauth/setup/state
curl -s --noproxy '*' http://127.0.0.1:8090/api/auth/user -H "X-Authorization: Bearer $TOKEN"
```
