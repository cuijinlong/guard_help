# 左侧菜单：租户与客户各长什么样

> 菜单不对，等于功能没交付。这一页讲清两件事：
> **客户看到的是能源管理主题的菜单**、**租户的能源配置收在 Platform 里**，
> 以及菜单坏了怎么一键重建。

## 客户菜单

客户登录后看到的顶层项：

```
首页
仪表板            ← 兜底入口，22 个能源看板可按名字找
能耗查询 ▾
   实时能耗       （看板）
   历史能耗       （看板）
   分项能耗       （看板）
   区域能耗       （看板）
   峰谷分析       （看板）
   电能质量       （看板）
   参数报表       → /param-report
能耗优化 ▾
   能耗洞察       （看板）
   闲时能耗       （看板）
   节能记录       （看板）
   闲时能耗配置   → /idle-config
设备运维 ▾
   组织与场站     → /sites
   设备分组       → /device-group
   设备管理       → /device-management
   设备拓扑       → /device-topology
   告警中心       → /alarm-center
   抄表管理       → /meter-reading
   手工填报       （看板）
组织 ▾
   组织与场站     → /sites
   客户能源档案   （看板）
   基础配置中心   （看板）
报表与账单 ▾
   综合能耗       （看板）
   盘查报告       （看板）
   我的账单       （看板）
   我的账单模板   （看板）
   基础报表       （看板）
```

**为什么客户不用 ThingsBoard 原生菜单**：TB 的「设备 / 资产 / 实体视图」是给平台
开发者用的建模概念。客户要做的是「我这栋楼今天用了多少电、哪块表异常、账单怎么算」，
看到「实体视图」只会困惑。

**看板入口为什么不是写死的**：客户名下那 22 个看板是「从租户模板复制一份」得到的，
每个客户的看板 ID 都不同。菜单里存的是**该客户自己的看板 ID**，
所以换客户、重建客户都不会点空。

---

## 租户菜单

租户管理员的菜单是 ThingsBoard 原生的那一套（仪表板 / 设备 / 资产 / 客户 / 规则链…），
**能源配置收在 `Platform` 里**，是这个分组的第一项：

```
Platform ▾
   能源配置 ▾        ← 第一项
       组织与场站     → /sites
       设备分组       → /device-group
       厂商与型号     → /vendor-model
       场站告警规则   → /alarm-rules
       参数报表       → /param-report
       抄表管理       → /meter-reading
       闲时能耗配置   → /idle-config
   版本控制
   任务管理
   调度器
   设置 ▾
   接口用量
```

**为什么收进 Platform**：这 7 个页面是「配一次就不常动」的后台功能，
和平台设置同一性质。放顶层会把日常要看的设备、客户挤到下面。

**为什么还要单独分一组「能源配置」**：7 个平铺进去会和「设置」里的 6 项混在一起，
分不清哪个是能源的。

---

## 菜单是自动装好的

**不用手工配。** 开客户时（`02-onboard.sh` 或平台里建客户），后端自动完成：

1. 把 22 个看板模板**复制一份**到客户名下（`customer_id` 指向客户）
2. 按客户自己的看板 ID，生成能源主题菜单
3. 清理同名旧菜单，避免重复

租户菜单来自前端默认菜单，**不需要任何配置**——重建前端产物时一起生效。

---

## 菜单不对时：一键重建

### 客户菜单

**在哪执行：【部署机 · 部署目录】**

```bash
cd ~/energy-app

bash scripts/07-init-menu.sh \
  --tenant tenant@your.com --tenant-pass 'Tenant@123' \
  --customer customer@your.com --customer-pass 'Customer@123'
```

**预计输出**：

```
1. 登录
  ✓ 客户 customer@your.com → customerId 77260860-...
2. 读客户看板
  ✓ 看板 22 个
3. 清理旧菜单（以客户身份）
  ✓ 删除 1 条
4. 创建并写入配置
  ✓ 菜单已创建 d9963a60-...
  ✓ 配置已写入
5. 以客户身份回读
  ✓ 客户看到的顶层菜单 7 项：
      · home
      · dashboards（1 项）
      · 能耗查询（7 项）
      · 能耗优化（4 项）
      · 设备运维（7 项）
      · 组织（3 项）
      · 报表与账单（5 项）

完成。客户刷新页面即可看到新菜单。
```

先看会写成什么（不落库）：

```bash
bash scripts/07-init-menu.sh ... --dry-run
```

### 租户菜单

租户菜单在前端源码里，改了必须**重新构建前端**：

```bash
cd /你的仓库路径/iot-rule-engine/ui-ngx
node --max_old_space_size=8192 ./node_modules/@angular/cli/bin/ng build --configuration production
```

产物在 `ui-ngx/target/generated-resources/public`，打进 jar 后由后端直接 serve。
完整步骤见[部署手册](/admin/deploy)的「更新到新版本」。

---

## 三个必须知道的坑

### 坑 1：菜单建好了，客户就是看不到

`CustomMenuItem.visible` 是 `@JsonView(Views.Private.class)`：

- **存库时**必须写 `visible: true`
- **返回前端时**这个字段被忽略（前端不看它）
- **后端读取时**按它过滤：`getVisibleMenuItems` 把 `visible=false` 的全丢掉

不写等于 `false` → 接口 200、库里有记录、**返回空菜单**。
这是最容易踩的一个，实测过一次，查了半小时。

### 坑 2：用租户账号建客户菜单，客户永远看不到

`POST /api/customMenu` 会把 `customerId` 强制设成**当前登录用户的 customerId**：

| 谁在调 | 建出来的菜单 `customer_id` | 客户能看到吗 |
| --- | --- | --- |
| 租户管理员 | `13814000-…`（NULL_UUID） | ❌ |
| 客户用户 | 该客户 id | ✓ |

因为客户菜单的查找条件是 `customer_id = 该客户`。
用租户账号建出来的是一条「租户级客户菜单」，客户查不到，还会因为
"已有 ALL 菜单"挡住后续重建。

`07-init-menu.sh` 全程用**客户账号**操作，就是为了避开这个。

### 坑 3：前端只 `exports` 不 `imports`，所有页面空白

`home-pages.module.ts` 曾经把 `imports` 写成了 `exports`。
`exports` 只把模块暴露给模板，**不注册任何子路由** ——
`loadChildren` 加载它之后，50 多个页面的 `RouterModule.forChild` 一条都没生效，
表现为：菜单点了有反应，右侧内容区永远空白。

正确写法是 `imports: [ ...页面模块... ]`。改完必须重新构建前端。

---

## 验收

跑全链路验收，会检查这几条：

**在哪执行：【部署机 · 部署目录】**

```bash
cd ~/energy-app
bash scripts/06-verify-e2e.sh \
  --base http://127.0.0.1:8090 \
  --tenant tenant@your.com --tenant-pass 'Tenant@123' \
  --customer customer@your.com --customer-pass 'Customer@123'
```

**期望**：

```
✓ 客户菜单已装（顶层 7 项）
✓ 菜单含「能耗查询」分组
✓ 菜单含「设备运维」分组
✓ 菜单里的看板入口均已绑定（17 个）
```

**「看板入口均已绑定」这条最关键**：它逐项检查菜单里的 DASHBOARD 项都带了
`dashboardId`。少一个就是死链，客户点进去白屏。

---

## 想改菜单怎么办

### 临时改（客户自己改）

客户管理员登录 → 菜单管理 → 拖拽调整。改的是自己那份，不影响别人。

### 永久改（平台方改）

改两处，取其一：

**改客户默认菜单** → 改 `EnergyMenuInstaller.buildItems()`
```bash
vi guard-server/src/main/java/com/guard/server/service/install/EnergyMenuInstaller.java
```
改完重打包、重装，新客户自动生效；老客户跑 `07-init-menu.sh` 补。

**改租户默认菜单** → 改 `ui-ngx/src/app/core/services/menu.models.ts`
```bash
vi ui-ngx/src/app/core/services/menu.models.ts
```
找 `Authority.TENANT_ADMIN` → `MenuId.platform_section` → `pages`，
改完重新构建前端。

> 菜单项的名字走 i18n：`energy.menu.sites` 这类 key 在
> `ui-ngx/src/assets/locale/locale.constant-zh_CN.json` 的 `energy.menu` 下。
> 改中文名要同时改这里，否则界面显示的是 key。
