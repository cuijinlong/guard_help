# ⑨ 排障

页面不对、数据不出、装不上。**按症状找，不按编号找。**

> 每一节都是「症状 → 判据 → 修」。
> 数据为空先看 [⑤ 数据流](/admin/data-flow) 的八步断点表，
> 查库用 [⑧ 运维 SQL](/admin/ops-sql)。

---

## 一、登录与账号

| 症状 | 判据 | 修 |
| --- | --- | --- |
| 提示「用户名或密码错误」（401） | 账号存在但密码没设好 | 见下文「账号建了但登不进」 |
| 账号建好了，激活链接打不开 / 跳到 `:80` | 建用户时没关邮件激活 | 用 `09-onboard-customer.sh` 重建（它跳过邮件） |
| 能登录，页面白屏 / 一直转圈 | 前端资源与后端版本不匹配 | 强刷 `Cmd+Shift+R`；仍不行看下面的「白屏」 |
| 客户登录落在空白门户页 | 租户菜单没绑到客户 | `GET /api/customer/{id}` 看 `customMenuId` 是否为空 |
| 客户点按钮弹「您没有权限执行此操作」 | 客户角色权限不足 | 用租户管理员调该接口，确认是权限问题而非 bug |

### 账号建了但登不进

TB 新建用户默认**没有密码、`enabled=false`**，直接登录会返回
`User account is not active`。必须走两步：

```
GET  /api/user/{id}/activationLink            → 拿激活 token
POST /api/noauth/activate?activateToken=...   → 真正设密码并置 active
```

手工建账号时漏任一步就永远登不进去。开户脚本已内置这两步，
三个参数坑见 [③ 开户与销户](/admin/onboard#14-三个必须知道的坑)。

### 页面白屏

| 判据 | 原因 | 修 |
| --- | --- | --- |
| 控制台看到 chunk 404 | `index.html` 引用了不存在的 chunk | 重新构建并**重打 jar**（见 [⑩](/admin/dev-build)） |
| CSS 被当成 `application/json` | 两个构建抢同一输出目录 | 检查有没有残留的 `ng build` 进程 |
| 控制台无报错，纯白 | 前端版本与后端接口不匹配 | 确认 jar 里的前端产物是最新的 |

**判据**：`curl -I http://ip/` 看 `Content-Type`。
`text/html` 才对；`application/json` 说明静态资源被 API 路由截了。

---

## 二、菜单与权限

| 症状 | 判断 | 修 |
| --- | --- | --- |
| 客户登录后左侧是 TB 原生菜单 | `customer.custom_menu_id` 为空 | `09-onboard-customer.sh` 会绑；手工绑见下 |
| 租户菜单只剩几项，原生菜单像被删了 | `custom_menu.config` 被覆盖 | 从备份恢复 `custom_menu` 表 |
| 点某菜单被「弹回」能耗概览 | 菜单指向的看板 id 不存在 | 查菜单 `config` 里的 dashboardId |
| 菜单里还是旧名字（如「设备运维」） | 菜单配置未更新 | 改 `custom_menu.config` JSON，**改完必须重启后端**（有缓存，不重启不生效） |
| 菜单名字对，但点进去是**旧界面** | 该功能同时有部件版和 Angular 站内路由，菜单指着旧的 | 把 `linkType` 从 `URL` 改成 `DASHBOARD` + 填 `dashboardId` + `hideDashboardToolbar: false`，详见下文「页面看起来还是旧版」 |
| 客户能读写别的客户的场站结构 | 接口只校验租户，没校验 customer | 后端问题，不是配置 |

### 客户菜单怎么绑

```bash
# ① 找到该客户的菜单（租户级模板）
GET /api/customMenu            # 找到 name 匹配的那个

# ② 绑到客户
POST /api/customer
{"id": {...}, "title": "客户名", "customMenuId": {"entityType":"CUSTOM_MENU","id":"<菜单id>"}}
```

**菜单是复制不是引用**：每个客户一份 `custom_menu` 记录，
改模板不影响已开户的客户。这也是销户要删菜单的原因。

---

## 三、部件与看板

| 症状 | 判据 | 修 |
| --- | --- | --- |
| 「加载部件配置时出现问题。关联的部件类型可能已被移除」 | `widget_type` 里没有该 fqn | 重新发布部件（见 [⑩](/admin/dev-build)） |
| 部件全空 + 控制台刷 `00000000-…` 的 404 | 看板配的数据源别名指向不存在的实体 | 清空该部件的 `datasources`，走账号可见范围 |
| 客户看板持续刷同一个 id 的 403/404 | 看板引用了**租户级**实体 id | 用租户级副本重建，或清 datasources |
| 部件显示「部件无数据可显示」但脚本会自己取数 | 部件仍按「有数据源」模式跑 | 设 `datasources: []` 并确认部件支持自取数 |
| 客户看板与租户模板不一致 | 开户时复制的是旧版模板 | 重新复制看板（`09` 幂等，会跳过已有的） |
| 表格没边框 / 表头像普通文字 | 部件 CSS 被 TB 全局样式覆盖 | 样式写 `templateCss` 用普通选择器，别用 `::ng-deep` |

### 部件没样式 / 整页空白：管道与 Material 指令没进作用域（2026-11-04 实测）

**症状（两种，根因相同）**

- 按钮是浏览器默认灰块，下拉框变成原生 `select`，`mat-icon` 位置上显示
  `bu` / `pow` 这样的**图标名字文本**；树里的勾选框 40px 把行撑高。
- 或者更狠：**整块看板全白**，只剩全屏图标。

**判据（F12）**

```js
// ① 样式问题：应返回 >0；返回 0 就是 Material 指令没生效
document.querySelectorAll('.mat-mdc-form-field').length
// ② 管道问题：控制台有这一句就是管道缺失
// TypeError: Cannot read properties of undefined (reading 'onDestroy')
```

**根因**：TB 部件模板是运行时 JIT 编译的。AOT 生产构建时
`linkerJitMode = options.jit = false`，Angular 不为 partial 库生成
`ɵɵsetNgModuleScope` —— **所有 NgModule 的 exports 在 bundle 里根本不存在**。
所以往动态组件的 `imports` 里放 `CommonModule` / `MatFormFieldModule`
等于什么都没放：

| 缺什么 | 后果 |
| --- | --- |
| `NgIf` / `NgForOf` 等结构指令 | `*ngIf` 全变 `<!---->`，部件空白 |
| `DecimalPipe` 等管道 | 视图创建时抛 `onDestroy` 错误，**整页空白** |
| Material 指令/组件 | 控件全没样式（不报错） |

**修（仓库里已改好，你只需要重新构建）**

```bash
cd ui-ngx
node esbuild/check-widget-deps.mjs          # 必须先过：584 个模板，缺一个就退出码 1
./node_modules/.bin/ng build --configuration production   # 约 4-5 分钟
cd ../guard-server && mvn -o package -DskipTests          # 把前端打进 jar
cp target/guard-server-4.4.0.jar ~/energy-app/
cd ~/energy-app && docker compose --profile split restart energy-server
```

> **只 build 前端不重打 jar = 白改**。容器读的是 jar 里的静态资源。
> `docker-98-rebuild.sh` 已经加了这条检查（jar 比 `index.html` 旧就中止）。

**新增部件后**：模板里用了新的 Material 控件，重跑
`node esbuild/gen-material-jit-directives.mjs` 生成清单；
清单从 Material 各模块的 `ɵɵngDeclareNgModule(exports)` 自动抽取，不要手写。

#### 还有第四层：`tb-datetime` 这类 TB 自有组件会渲染成空白框（2026-11-04 实测）

**症状**：日期区域只有分隔符 `~`，两个输入框位置是空的。
点不到、也没有报错 —— 开关报错、控制台干净、日志干净。

**判据（F12）**

```js
const d = document.querySelectorAll('tb-datetime');
d.length                                    // 元素在，比如 2
[...d].filter(x => !x.children.length).length  // 期望 0；是 2 就是全空
d[0].getBoundingClientRect().height         // 0 —— 元素在但没有高度
```

**根因**：`<tb-datetime>` 是 `standalone: false` 的组件，只能经 `SharedModule`
引入；而 `SharedModule` 的 exports 在 AOT 产物里是空的（与上一条同一个
`linkerJitMode`）。于是它被当作**未知元素**原样保留 —— 元素在、内容空、不报错。

**修法（2026-11-04 已落地）**：改用自研 standalone 组件，直接用，别再自己写一套。

| 不要用 | 改用 |
| --- | --- |
| `<tb-datetime>` | `<energy-date-picker>` |
| `<tb-details-panel>` | `<energy-details-panel>` |

`energy-date-picker` 与 `tb-datetime` 接口**逐字段一致**（毫秒时间戳、
`type` = date/month/year、`minDate`/`maxDate`、`showLabel`、`fieldClass`）。
所以换标签时 controllerScript **一行不用改**，只改两处绑定名：

```html
<!-- 改前 -->
<tb-datetime class="eqp-pick" type="date" [minDate]="minTs" [maxDate]="maxTs"
             [ngModel]="tsOf(fromDate)" (ngModelChange)="onPick($event,'from')">
</tb-datetime>

<!-- 改后：只换标签 + [ngModel] -> [value]、(ngModelChange) -> (valueChange) -->
<energy-date-picker class="eqp-pick" type="date" [minDate]="minTs" [maxDate]="maxTs"
                    [value]="tsOf(fromDate)" (valueChange)="onPick($event,'from')">
</energy-date-picker>
```

> ⚠️ **为什么不能用 `[ngModel]`**：`NgModel` 属于 `FormsModule`，
> 也是 `standalone: false` 且展不开（实测 `@angular/forms` 的 fesm：
> `ɵɵngDeclareNgModule` ×3、`setNgModuleScope` ×0）。
> 绑 `[ngModel]` 会报 `Can't bind to 'ngModel'`，比原来的空白更糟。

**为什么自研组件能工作**：它是我们自己源码里的 `standalone: true` 组件，
由 ngc 做 **AOT 编译** —— 编译器在编译期读 `@mat-datetimepicker/core` 的
`.d.ts` 拿到 exports，静态写进组件的依赖列表，不依赖运行时
`ɵɵsetNgModuleScope`。JIT 只需要 `imports: [EnergyDatePickerComponent]`。

> 反例：把 `MatDatetimepickerModule` **直接**放进 JIT 的 `imports` 仍然无效，
> 因为那是模块。一定要通过自研 standalone 组件中转一层。

**新增自研组件必须两道登记**（漏一道 = 静默空白，不报错）：

1. `standalone: true`
2. 加进 `dynamic-component-factory.service.ts` 的 `componentImports`

> ⚠️ **绝对不要**为了救它去手工补 `SharedModule.ɵmod` 的
> `declarations` / `exports`。实测后果：全站报
> `InvalidCharacterError ... DOMTokenList` +
> `Failed to load default widget types!`，
> **所有部件的默认类型都加载失败**，比原问题严重一个数量级。
> 详见 `AGENTS.md` 的 A2d3。

**自检已经覆盖这一层（现为五层）**：

```bash
cd ui-ngx && node esbuild/check-widget-deps.mjs
# 管道 / 结构指令 / Material / 非 standalone 的 tb-* / 自研组件是否注册
# 有问题退出码 1；应急构建（修完前）：加 --report-only
```

第五层（2026-11-04 加）抓的是「写了 `<energy-xxx>` 但没登记进 JIT」——
它跟 `tb-datetime` 是同一个坑：元素在、什么都不显示、不报错。
靠扫源码判断，不靠手维护名单。

**验收（必须浏览器实测，不能只看退出码）**

```js
document.querySelectorAll('tb-datetime').length                          // 0
document.querySelectorAll('energy-date-picker').length                   // > 0
document.querySelectorAll('energy-date-picker .mat-mdc-form-field').length  // 等于上一行
document.querySelectorAll('energy-details-panel').length                 // > 0（整页部件）
```

> **分量判据（最重要）**：`<energy-date-picker>` 外面有没有 `_nghost-ng-xxx` 属性。
> `_nghost` 存在 = 组件被 JIT 识别；**不存在 = 被当成未知元素**（作用域被 poison
> 或组件没登记），子元素 0 个、高度 0、控制台干净。
>
> ```js
> [...document.querySelectorAll('energy-date-picker')]
>   .filter(e => ![...e.attributes].some(a => a.name.startsWith('_nghost')))
>   .length   // 期望 0
> ```

### 日期框/抽屉又空白了？先查「装配清单里有没有非 standalone 的类」（2026-11-04 实测）

**症状**：换了 `energy-date-picker` 之后日期框仍然空白，元素在、高度 0、不报错。
如果 `_nghost` 属性也没有，就是这个原因。

**根因**：`@angular/core` 的 `computeStandaloneComponentScope` 逐项校验 `imports`：

```js
try { verifyStandaloneImport(imported, type); }
catch (e) { ans.compilation.isPoisoned = true; return ans; }   // 立即返回
```

**一个非法项 → 整个作用域作废 → 排在它后面的所有指令与组件全丢，且不报错。**

实测事故：`material-jit-directives.ts` 里混进了 `@mat-datetimepicker/core` 的
12 个符号（其 10 个组件是 `isStandalone: false`），它们排在清单末尾，
于是排在**其后**的 `energy-date-picker` / `energy-details-panel` 被整段吞掉。

**检查与修复**：

```bash
cd ui-ngx
node esbuild/check-widget-deps.mjs        # 第六层会报「装配清单含非 standalone」
node esbuild/gen-material-jit-directives.mjs   # 自动剔除并报出剔除清单
```

**为什么不用 `@mat-datetimepicker/core`**：它没有 standalone 版本。
日期控件统一用 `energy-date-picker`（基于 `@angular/material` 原生 `MatDatepicker`，
Material 20 的组件全是 standalone）。

**两道保险**（代码里已经做好，改的时候别破坏）：

1. 生成脚本自动剔除 `isStandalone: false` 的类，并在剔除时报错；
2. 自研组件在 `componentImports` 里排在 `MATERIAL_JIT_IMPORTS` **之前** ——
   将来清单再被污染，排在前面也不会被丢。

**状态**（2026-11-04）：26 处 `tb-datetime`、5 处 `tb-details-panel`
已全部替换完，自检退出码 0。8 个客户看板 + 9 个租户看板已浏览器实测：
日期框 `host`/`.mat-mdc-form-field` 全部成对，无 `tb-datetime` 残留，控制台无异常。

### 系统整体很慢 / 点开看板要等好几秒（2026-11-04 实测修复）

**症状**：数据量明明很小（几十台设备），打开看板却要等 5 秒以上，
多个部件同时加载时更慢，甚至十几秒。

**先量化，别猜**。三个数分别测：

```bash
TOKEN=$(curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' -d '{"username":"demo@126.com","password":"12345678"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")

# ① 单个接口耗时 + 返回大小
curl -s --noproxy '*' -o /dev/null -w "%{time_total}s %{size_download}B\n" \
  "http://127.0.0.1:8090/api/energy/meters" -H "X-Authorization: Bearer $TOKEN"

# ② 8 并发（模拟一屏 8 个部件）
for i in $(seq 1 8); do
  curl -s --noproxy '*' -o /dev/null -w "%{time_total}s\n" \
    "http://127.0.0.1:8090/api/energy/meters" -H "X-Authorization: Bearer $TOKEN" &
done; wait
```

**判据**：如果「返回很小（几 KB）却耗时很长」，那就是**纯往返开销**，与数据量无关。

**根因（2026-11-04 修复前）**：`/api/energy/meters` 在循环里逐台查数据库：
31 台设备 ≈ 93 次串行往返；`energyTypes()` 又对全部 122 个资产逐个查属性。
再加上每次都跑一条 `SELECT max(ts) FROM ts_kv GROUP BY entity_id`
（82 万行的分区表，261ms），而 `ts_kv_latest` 只有 905 行、8.7ms、语义完全相同。

**修复后实测**：

- 热态单次：`0.9–8.8s` → **`0.12–0.28s`**
- 8 并发：`34–85s` → **`0.26–0.41s`**
- `metric-params`（带 siteId）：`1.1s` → **`56–107ms`**

**如果你自己要给别的接口做同样的优化**，四条规则：

1. **循环里不查库**：循环前一次 `IN` 批量取，循环里只查内存 Map。
2. **缓存按租户分键**：用 `tenantId` 作 key，不要用一个全局变量。
3. **热路径加 single-flight**：一屏多部件同时请求，缓存冷时要只算一次。
4. **要「每个实体的最新值」就用 `ts_kv_latest`**，只有查历史区间才碰 `ts_kv`。

**前端也有 N+1：一个页面发出几百个请求**（2026-11-05 实测）

如果后端接口都很快（curl 测几十毫秒），但**页面还是要等十几秒**，
那就是前端在逐条查数据。

**判据**：F12 → Network，按 Name 看重复次数。

```js
// 控制台里统计（需要先刷新页面一次）
performance.getEntriesByType('resource')
  .filter(r => r.name.includes('/api/'))
  .reduce((m, r) => { const k = r.name.split('?')[0]; m[k] = (m[k]||0)+1; return m; }, {});
```

2026-11-05 的实测：分项能耗页一次刷新 **293 个 API**，
其中 **210 个 `GET /api/asset/{id}`** —— 4 个部件各自在构图时逐节点取名字。
而整站走 **HTTP/1.1，浏览器每个域名只有 6 个并发连接**，
210 个请求排队，页面 14 秒才完成（实际只有 122 个资产）。

**决定性证据**：14 个 `deviceProfileInfo` 请求的 TTFB

```
#1-6   TTFB 125~343ms   ← 真的在跑
#7-14  TTFB 397~856ms   ← 纯排队（同样的单查只要 15ms）
```

**已修复的批量接口**（部件里直接用）：

- `GET /api/energy/entity-briefs?ids=a,b,c`
  → 一次拿 name / label / 实体类型（替代逐 id 查 `/api/asset/{id}`）
- `GET /api/energy/device-profile-names?ids=a,b,c`
  → 一次拿设备档案名（替代逐 id 查 `/api/deviceProfileInfo/{id}`）

**修复后**：分项能耗 API 293 → 134，`/api/asset/` 210 → 8；
历史能耗的 `deviceProfileInfo` 14 → 0。

> ⚠️ 为什么不用 TB 自带的 `/api/deviceProfileInfos?deviceProfileIds=...`：
> 它带 `@PreAuthorize("hasAuthority('TENANT_ADMIN')")`，**客户用户直接 403**。
> 这也是当初为什么要逐个查 —— 现在改走自研接口。

**部件永久卡在「加载中…」**（2026-11-05 修复）

这不是慢，是**永不结束**。判据：部件一直显示「加载中」，控制台无任何报错。

根因是部件的完成判定写了 `finished === total`：

```js
worker(item, function () { finished++; if (finished === total) { done(); } });
```

只要有一个回调重复触发（HttpClient 同时触发 error 与 complete）
或缺失，`finished` 就越过 `total`，`===` 永远不成立 → 永不结束、不报错。

修法（已应用到 `realtime_trend` 等部件）：

```js
var settled = false;
worker(item, function () {
  if (settled) { return; }        // 幂等：重复回调丢弃
  settled = true;
  running--; finished++;
  if (finished >= total) { done(); }
});
setTimeout(done, 15000);          // 硬超时兜底
```

同批还做了两件事，让这类问题不会再出现：

1. **逐实体取数改批量**：21~89 个 `/values/timeseries` → 1~8 个
   `/api/energy/telemetry-series`；
2. **逐节点取关系改批量**：87 个 `/api/relations` →
   5 个 `/api/energy/child-relations`。

**多实体取数/取关系现在都有批量接口**（写新部件时直接用）：

| 用途 | 接口 |
| --- | --- |
| 多实体遥测序列 | `GET /api/energy/telemetry-series?ids=ASSET:a,DEVICE:b&keys=&startTs=&endTs=&interval=&agg=&limit=` |
| 一层树的 Contains 关系 | `GET /api/energy/child-relations?ids=&dir=from` |
| 实体名称/label/类型 | `GET /api/energy/entity-briefs?ids=` |
| 设备档案名 | `GET /api/energy/device-profile-names?ids=` |
| 一批设备的完整档案（要 profileId/customerId） | `GET /api/devices?deviceIds=a,b,c`（TB 原生，实测客户账号可用） |

**第三批（2026-11-05）：左侧「查询设置」与实时趋势**

如果后端和批量接口都快了，但左侧设备树仍要等 1~3 秒，
问题在部件自己发的单查：

| 位置 | 改前 | 改后 |
| --- | --- | --- |
| 查询设置：根类型 / 品种名 / 按名找品种 | 逐 id `/api/asset/{id}`（404 再试 `/api/device/{id}`） | 1 次 `entity-briefs` |
| 查询设置：补设备 | 逐 id `/api/device/{id}` | 1 次 `GET /api/devices?deviceIds=` |
| 实时趋势：`loadNames` | 逐实体单查（一屏 12 个并发） | 1 次 `entity-briefs` |

实测（实时能耗，客户账号，整页刷新）：`/api/asset/{id}` **20+ → 0**，
总请求 **131 → 85**，「部件出现 → 树成型」**908ms → 607ms**；
SPA 内切回该看板（用户真实操作）**1 秒出 25 行**。

> 冷启动那 3.6 秒里，**3.3 秒是 Angular 自己**（bootstrap + 14 个懒加载 chunk + 翻译），
> 部件的业务请求只占最后约 600ms。
> 判据：分别量「部件出现」与「树成型」两个时间点，看**差值** ——
> 差值大才是部件的问题，整体大是框架启动成本。

**合并前端查询：用「预取」，不要用「微批」**（这条踩过两次）

| 做法 | 改哪里 | 结果 |
| --- | --- | --- |
| 微批：在 `loadName` 里用 `setTimeout(0)` 收集同一 tick 的 id | 改被调函数内部 | **会卡死**：10 次切换有 2 次永久「加载中」 |
| 预取：`forEach` 之前先把整层 id 批量灌进 `nameCache` | 只改调用点 | **安全**：14 轮切换 0 卡死 |

原因：树加载是逐层异步递归，完成靠上层 `pending--; if (!pending) cb()` 计数。
在被调方里插一层宏任务（`setTimeout`）会把「同步回调」变成「异步回调」，
计数节奏乱掉。预取不改被调方，之后每条都命中缓存、仍然是同步回调。

**排查工具**：容器镜像只有 JRE（没有 `jstack` / `jcmd`），
`/actuator/loggers` 被前端路由拦成 HTML 页面（不是真端点）。
量 SQL 用 `docker exec energy-postgres psql -c "\timing on" -c "<SQL>"`，
量接口用浏览器 F12 的 Network 面板看每个请求耗时。

### 看板显示「数据源未解析到设备」/「当前 0 台计量点」（2026-11-04 实测）

**症状**：看板框架、筛选条、KPI 卡片都在，但数字全 0，
副标题写着「范围：数据源未解析到设备」。

**先确认不是数据问题**（这两条都正常就继续往下）：

```bash
docker exec energy-postgres psql -U postgres -d thingsboard -tAc \
 "select relation_type, from_type, to_type, count(*) from relation
   where relation_type_group='COMMON' group by 1,2,3 order by 4 desc;"
# 期望看到 Contains|ASSET|ASSET 与 Contains|ASSET|DEVICE 都有记录
```

**根因**：部件里 `collectDevices` 递归取子资产的设备，但
`loadRelationsBatch` **只请求传入的那几个 id** 的关系 ——
递归到第二层时 `rels[子资产]` 是 `undefined`，于是
「组织 → 场站 → 设备」在第二层就断，解析出 0 台。

**判据**：直接调接口看关系是否真的存在：

```bash
TOKEN=$(curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"<账号>","password":"<密码>"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

curl -s --noproxy '*' \
  "http://127.0.0.1:8090/api/relations?fromId=<组织id>&fromType=ASSET&relationTypeGroup=COMMON" \
  -H "X-Authorization: Bearer $TOKEN" | head -c 300
# 有数据但看板是 0 → 就是递归断了，不是数据问题
```

**修**：部件里改用 `loadRelationsDeep`（逐层 BFS，带 `visited` 防环）。

**已修的部件**（同一套模板复制出来的，改一个要全改）：

```
energy_overview  power_quality  sankey_flow  saving_records  audit_report
```

**验收**：页面副标题应显示 `范围：数据源（31 台） · 当前 17 台计量点`，
KPI 有非零数字。改完用 `31-deploy-widget.sh <名>` 推库，**不用重启后端**。

### 客户名下没有网关 / 正泰电表 / 温湿度 / 8路继电器（2026-11-04 实测）

**症状**：客户登录后只有「单相园-*」「三相园-*」那批分项设备，
设备管理里搜不到 `ED2-Gateway`、`PowerMeter-DDSU666`、`Sensor-HZ8706`、`Relay-8CH`。

**先看库里到底有没有**（把 `<CID>` 换成客户 id）：

```bash
docker exec energy-postgres psql -U postgres -d thingsboard -tAc "
select name, type from device where customer_id='<CID>'
  and (type='网关' or name ~ 'DDSU666|HZ8706|Relay-8CH') order by name;"
```

一条都没有 → 跑一次初始化（幂等，只修不建）：

```bash
cd ~/energy-app
python3 scripts/30-rtu-env-init.py --base http://127.0.0.1:8090 \
  --customer '<客户名>' --tenant tenant@126.com --tenant-pass '<密码>'
```

出来「⚠ 真实网关 ED2-Gateway·客户名 不存在」这条警告 → 你用的是旧脚本，
按本页末尾「三个已修的 bug」对一下版本。

**三个已修的 bug，症状各不相同但都表现为「设备不见了」**：

| bug | 症状 | 修 |
| --- | --- | --- |
| 非主客户「只查网关不建网关」 | 客户下 0 台网关；8 台 SIM 全部孤儿（0 条 DEVICE→DEVICE 关系） | 统一走 `ensure_gateway()` |
| `--prune` 删掉 `demo:true` 设备 | 跑一次初始化，31 台演示设备全没，只剩 8 台 SIM | `is_demo_device()` 按 `additionalInfo.demo` 豁免 |
| `21-rtu-onboard.py` 写 `DDSU777` | 真实 RTU 上报后平台**自动新建**一台 `PowerMeter-DDSU666`（无档案、无归属），数据分裂两台 | 三处统一 `PowerMeter-DDSU666`：`rtu/main.py` / `21-rtu-onboard.py` / `30-rtu-env-init.py` |

**验收判据**：

```bash
# 网关下应挂 11 台（8 SIM + DDSU666 + HZ8706 + Relay-8CH）
docker exec energy-postgres psql -U postgres -d thingsboard -tAc "
select g.name||'  └─ '||d.name from device g
 join relation r on r.from_id=g.id and r.relation_type='Contains' and r.from_type='DEVICE'
 join device d on d.id=r.to_id
 where g.customer_id='<CID>' and g.type='网关' order by d.name;"

# 没被网关挂载的设备应只剩「31 台 demo + 网关自己」
```

看板副标题应显示 `范围：数据源（43 台） · 当前 25 台计量点`。
`当前 N 台计量点`里**不含**温湿度与继电器 —— 它们不是计量器具，
`energyTypeCode` 分别是 `env` 与 `ctrl`，被计量池正确跳过。

**模拟上报要覆盖 RTU 下挂三件**：`31-rtu-simulate.py` 现在会一并上报
`PowerMeter-DDSU666·客户名`（电量）、`Sensor-HZ8706·客户名`（温湿度）、
`Relay-8CH·客户名`（8 路通道状态）。跑一轮应该有 `成功 11 / 失败 0`。
数量只有 8 台说明脚本是旧版。

**主演示客户「平台演示中心」例外**：它那四台是**真实板子**上报，
`31-rtu-simulate.py` 会按 `REAL_DEVICES` 白名单跳过，不会造假数据覆盖。

### 销户时误报「目标以外的遥测减少了 N 点」（2026-11-04 修）

**症状**：`10-cleanup-customer.sh` 删完客户，其他数据明明都在，
却报 `目标以外的遥测减少了 53097 点！需要人工介入`。

**先别慌，先核实其他客户还在不在**：

```bash
docker exec energy-postgres psql -U postgres -d thingsboard -tAc "
select c.title, count(distinct d.id) as 设备,
       count(k.entity_id) as 遥测点
  from customer c
  left join device d on d.customer_id=c.id
  left join ts_kv k on k.entity_id=d.id
 group by c.title;"
```

数字没少 → 是**校验脚本的误报**，不是真删了。

**根因**：`ts_outside()` 只排除了目标**设备** id，没排除目标**资产** id。
资产上也有遥测（`energy_total` / `power_total` / `energy_day` 等汇总），
销户时一并删除，于是被算成「别人的点在减少」。
实测销一个 33 台设备的新客户，误报减少 53097 点。

**修**：`ts_outside()` 同时排除设备与资产 id（已改，见
`downloads/scripts/10-cleanup-customer.sh` 的 `ASSET_IDS`）。
修好后同一场景输出：

```
✓ 遥测：目标以外 737761 → 737768 点（本次删了 21 点，未波及他人）
✓ 隔离校验通过：其他客户 224 个实体与租户级数据均未受影响
```

### 实时能耗看不到数据变化 / RTU 通电但不上报（2026-11-04 实测）

**先用一条命令诊断**（平台侧该查的全查一遍）：

```bash
cd ~/energy-app
bash scripts/34-rtu-diagnose.sh --customer '<客户名>'
```

它按顺序检查 ①本机 IP ②固件 TB_HOST 是否匹配 ③端口监听+局域网可达
④已建立的 MQTT 连接 ⑤局域网里的 ESP32 ⑥设备上报时间，最后给结论。

**判据分水岭：第 ④ 项「已建立的 MQTT 连接」**

```bash
netstat -an | grep -E '\.1883|\.11883' | grep ESTABLISHED | wc -l
# 0    → RTU 根本没连上来，看下面的「连不上」三条
# >0   → 连上了但没数据，跳到「连上了但没数据」
```

#### 连不上（0 条连接）—— 按这三个顺序查

| 顺序 | 查什么 | 判据 / 修 |
| --- | --- | --- |
| ① | **Thonny 是不是开着** | `pgrep -fl Thonny`。开着 = 板子上的 `main.py` 被 Ctrl-C 中断了。**完全退出**（Cmd+Q），按 RST 复位 |
| ② | 板子上的 `TB_HOST` | 改电脑上的 `rtu/main.py` 不影响板子。`bash scripts/35-rtu-flash.sh --dry-run` 并排看两边 |
| ③ | 令牌 | `34-rtu-diagnose.sh` 会直接比对固件与平台，不一致会标 ✗ |

> **Thonny 这条最坑**：串口输出看着正常、WiFi 也连上了、板子灯在闪，
> 但平台就是 0 连接 —— 因为程序根本没在跑，你看到的只是 REPL。

#### 连上了但没数据

| 查什么 | 判据 |
| --- | --- |
| 看的是哪台设备 | 界面「单相电表」= 模拟设备；「正泰单相电表 DDSU666」= 真实 RTU 那台 |
| 真实表是否在数据源范围内 | 「实时能耗」默认只看「单相园区」场站，电表没挂进去就看不到 |
| 规则链是否翻译了 key | 板子发 `U/I/P/Ep`，平台读 `voltage_a/...`。规则链「电表Key标准化」没跑通就是有连接没数据 |

#### 「单相电表」还是「正泰单相电表 DDSU666」？

一台设备有**三层名字**，界面上只显示中间那层：

| 层 | 值 | 用途 |
| --- | --- | --- |
| `name`（技术名） | `PowerMeter-DDSU666` | 网关按它匹配，**必须与固件逐字一致** |
| `label`（显示名） | 正泰单相电表 DDSU666 | **界面上看到的是这个** |
| `type`（设备档案） | 单相电能表 | 决定测点模板与计量口径 |

而界面上的「单相电表」是另一台：

| 显示名 | name | 谁在上报 |
| --- | --- | --- |
| 单相电表 | `PowerMeter-1P-SIM·<客户名>` | `31-rtu-simulate.py` 模拟 |
| 正泰单相电表 DDSU666 | `PowerMeter-DDSU666` | **真实 RTU 板子** |

所以「实时能耗有变化但看不到真实表」= 模拟在跑、板子没连上；
「两台都没变化」= 模拟脚本也没常驻（`--once` 跑完就退出了）。

```bash
# 模拟上报要常驻（后台守护，不用 nohup）
bash scripts/29-rtu-demo-up.sh --sim-only --customer '<客户名>' --interval 30
# 状态/停止
python3 scripts/31-rtu-simulate.py --status
python3 scripts/31-rtu-simulate.py --stop
```

#### 「实时能耗」页怎么选设备（2026-11-04 实测）

页面左上「查询设置」里是一棵**场站 → 设备**树，两种数据在**同一棵树**里，
用勾选框控制查哪台：

```
▼ 办公园区                                        ← 场站（右上角选的）
   ▸ 1#进线总表                                   ← 关口表（可展开看下级）
     温湿度-办公区                                ← demo 演示设备
     单相电表                                     ← 模拟（*SIM）
     正泰单相电表 DDSU666                         ← **真实 RTU 板子**
```

| 想看什么 | 勾哪台 | 判定 |
| --- | --- | --- |
| 真实 RTU 的电量 | **正泰单相电表 DDSU666** | `PowerMeter-DDSU666` |
| 模拟的多品种效果 | 单相电表 / 三相电表 / 水表 / 燃气表… | 名字带 `SIM` 的那批 |
| 两者一起看 | 勾两台，或都不勾（不勾 = 当前品种全部） | 不勾时标题是「<场站>实时能耗」 |
| 温湿度 | 先把上方品种切到**环境系统** | 温湿度属 `env` 品种，不在「电能」下 |

不勾任何设备时，KPI 显示的是**整个场站**的汇总；勾了单台，标题会变成
「电能实时能耗」并带设备名 —— 这是判断「我到底在看谁」最快的标志。

#### 真实表数据是 0，不是没上报（重点）

实测串口日志：

```text
📤 电表已上报: {'U': 226.4, 'Freq': 50.02, 'Ep': 8.83, 'PF': 1.0, 'I': 0.0, 'P': 0.0, ...}
```

`U`（电压）和 `Freq`（频率）**在动**，说明链路是通的；
`I`（电流）= 0、`P`（功率）= 0、`Ep`（表底）= 8.83 不动 ——
**电表没有接负载**。这时页面显示：

| 指标 | 真实表（空载） | 模拟表（有负载） |
| --- | --- | --- |
| 当前总有功功率 | 0.0 kW | 8.9 kW |
| 今日用电量 | `--`（表底没动，算不出增量） | 26.1 kW·h |
| 趋势曲线 | 一条 0 的平线 | 有起伏 |

要看到真实表的数字变化，二选一：

1. **给电表接个负载**（灯泡、风扇、电吹风都行，接在 DDSU666 出线侧）；
2. **演示时用模拟设备**，或勾选两台一起展示（真实表证明"现场接入通了"，
   模拟表展示"分析功能"）。

> 「今日用电量 `--`」是**正确行为**：平台按表底差分算日增量，
> 表底不动就没有用量，不编造 0。见 AGENTS.md 的「没有用量就不写用量」。

#### 换电脑后必做

```bash
# ① 查新 IP
ipconfig getifaddr en1        # macOS；Linux: hostname -I

# ② 改 rtu/main.py 的 TB_HOST 为新 IP
# ③ 上传到板子（关键：只改文件不上传 = 没改）
bash scripts/35-rtu-flash.sh --serial /dev/cu.wchusbserial1410

# ④ 验证
bash scripts/34-rtu-diagnose.sh --customer '<客户名>'
```

### 改完部件 JSON 前端没变化

| 层次 | 判据 | 修 |
| --- | --- | --- |
| 浏览器缓存 | 硬刷新后变了 | `Cmd+Shift+R` |
| 部件版本 | 库里有两条同名 fqn，看板取 version 大的 | 更新**系统级**那条（`tenant_id` 为 NULL） |
| 部署物料 | 干净库装的是旧部件 | 跑 `scripts/32-check-deploy-sync.sh` || jar | 容器挂的是 jar，不是工作目录 | 重新 `mvn package` + 重启容器 |

**判据**：`GET /api/widgetType?widgetTypeId=<id>` 看返回的
`controllerScript` 里有没有你刚加的代码。有 → 前端缓存；没有 → 没发布成功。

### 页面看起来还是旧版（2026-11-03 实测）

**症状**：功能没报错、页面能打开、数据也对，但界面是几天前的样子。
客户的原话往往是「我的代码都变成老代码了」「是不是被另一台电脑覆盖了」。

**先别查 git。** 先确认这一屏是**谁渲染的** —— 同一功能可能同时存在两套实现：

| 实现 | 特征 | 新旧 |
| --- | --- | --- |
| 部件看板 | `linkType: "DASHBOARD"` + `dashboardId` | 新 |
| Angular 站内路由 | `linkType: "URL"` + `url: "/xxx"` | 可能是旧版 |

查当前菜单指向（把 `<菜单id>` 换成本客户的 `custom_menu_id`）：

```bash
docker exec energy-postgres psql -U postgres -d thingsboard -t -A -c \
 "SELECT config FROM custom_menu WHERE id='<菜单id>';" \
 | python3 -c 'import sys,json; c=json.load(sys.stdin);\
def w(x,d=0):\
  [ (print("  "*d + i.get("name","") + "  →  " + (i.get("dashboardId") or i.get("url") or "-")), w(i.get("pages") or [], d+1)) for i in x ];\
w(c.get("items",[]))'
```

输出里 `→ /device-management` 这类站内路径就是旧实现；`→ <uuid>` 是部件看板。

**本次实测**：37 个菜单里 22 个走部件看板、8 个走站内路由。设备管理三项
（`/device-management`、`/device-group`、`/device-topology`）指着 10-26 的 Angular 版，
而对应的部件 10-31 就做好了、看板 11-02 也建好并挂给了客户 —— **只差菜单这一行**。

**修法**：改菜单 JSON，三处都要改：

```diff
- { "name": "设备运维", "linkType": "URL", "url": "/device-management",
-   "dashboardId": null, "hideDashboardToolbar": null }
+ { "name": "设备运维", "linkType": "DASHBOARD",
+   "dashboardId": "<看板id>", "url": null, "hideDashboardToolbar": false }
```

三个坑，缺一个就出毛病：

1. **`hideDashboardToolbar` 必须显式写 `false`**。`iframe-view` 里这个参数的
   缺省值是 `true`（`childHideDashboardToolbar` 不传就隐藏整个工具栏），
   而**面包屑就在工具栏里** —— 不写就是「页面正常、但顶部标题没了」。
2. **改完必须重启后端**：`docker restart energy-server`。配置有缓存，不重启不生效。
3. **确认看板真的归属该客户**。`customer_id` 直接归属才一定可访；
   只用 `assigned_customers` 分配的，实测可能报
   「这个看板没有分配给你的账号」/ `Permission Denied`。

**不要顺手把所有站内路由都改成看板。** 三个门槛缺一不可：① 有部件版
② 看板已建 ③ 客户真能打开。用能建议/用能质量是 ngx-ai 子应用、平台自检没有部件版，
它们本就该走 URL。

**验证必须点菜单**，不要直连 `/dashboards/<id>` —— 直连走的是另一条链路，
测着通、客户点进去仍是错的。

### 看板布局问题

| 症状 | 原因 |
| --- | --- |
| 改了大屏部件尺寸，页面还是原宽度 | 尺寸在 `states.<state>.layouts.<layout>.widgets` 里，不在 `widgets` 里 |
| 右侧下方有空缺（部件少一块高度） | `sizeY` 之和没铺满，gridster 会留白 |
| 部件互相挤压 / 按钮点不到 | 部件内绝对定位 + TB 操作区（右上角 56×56）冲突 |
| 看板高度超出屏幕 | 桌面端 `rowHeight` 不生效，高度只能靠 `sizeY` 调 |

**布局的两处结构必须对齐**：

```
configuration.widgets.<id>                             存部件配置
configuration.states.<state>.layouts.<layout>.widgets  存尺寸与位置
```

只改一处 → 尺寸不生效或部件消失。

---

## 四、设备有数，看板是 0

这是最常见的一类。**先分清是哪一层空的**：

| 现象 | 空在哪 | 去查 |
| --- | --- | --- |
| 设备详情「最新遥测」也空 | ① 采集 | [⑦ 设备接入](/admin/device-access) |
| 设备有数，资产 `*_total` 空 | ⑤ 汇总 | [⑧ §5](/admin/ops-sql#5-资产汇总看板为什么是空的) |
| 资产有数，页面还是 0 | ⑥ 部件取数 | 本节下文 |
| 资产有数，但数值太小/太大 | ⑦ 倍率或口径 | [⑤ 数据流](/admin/data-flow) |

### 资产汇总是空的

```bash
# 手工触发一次（最常见的原因就是没等定时任务）
curl -X POST -H "X-Authorization: Bearer $TOKEN" \
  'http://127.0.0.1:8090/api/energy/asset-totals/rebuild' \
  -H 'Content-Type: application/json' -d '{"days":2}'
```

**触发后仍为空**，按这四条查：

| 判据 | 原因 |
| --- | --- |
| 设备 `meterLevel` 是 0 或空 | 被当成非计量，不进汇总 |
| 档案没有 `energyTypeCode` | `profileEnergyCode` 返回 null → 直接跳过 |
| 设备没挂到场站（缺 `SiteContains`） | 归不到任何节点 |
| 「不参与厂站能耗计算」被勾选 | 显式排除 |

第一条 SQL 见 [⑧ §5.2](/admin/ops-sql#52-哪些设备参与了汇总)。

### 部件一直「加载中…」

| 判据 | 原因 |
| --- | --- |
| Network 里有请求 pending | 后端在跑重查询（汇总/大窗口） |
| 请求 200 但返回空数组 | 部件选错了取数实体（如选了品种资产） |
| 请求 400 `Number of intervals is to high` | 桶数超上限，应压 interval（数据层已修） |
| 完全没有请求 | 部件脚本报错，看 Console |

### 顶栏显示「数据源（10 台）」，下面全是 0

这是**取了设备池但当计量点用**的典型症状：数据源解析到 10 台设备，
但其中只有 8 台是计量器具（2 台是网关/传感器），且资产汇总没写。

判据：`/api/energy/meters` 返回的 `role` 字段是不是 `meter`。

---

## 五、场站与设备树

| 症状 | 判据 | 修 |
| --- | --- | --- |
| 切换场站后树不更新 | 部件只在 `onInit` 读了一次场站 | 部件必须订阅 `stateChanged()` 并跟 cookie |
| 顶栏没有场站选择器 | 看板 `settings.showStationSelect` 不为 `true` | 改看板 JSON |
| 树里混着别的场站的表 | 判据用了 `additionalInfo.siteId` 而不是关系 | 补 `SiteContains`（[⑧ §6.1](/admin/ops-sql#61-场站--区域--分项归属)） |
| 树「场站跑到分项下面」 | 维度树的 `siteChildType` 配错 | 改分析条件部件的 `siteChildType` |
| 切到没建分组的场站，树还是上一个 | 部件没清空旧状态 | 部件 bug |
| 设备分组「添加设备」列出别的场站 | 过滤条件缺场站 | 部件 bug |
| **场站过滤后为空，却显示了全部表** | 有「退回全量避免空树」的保护 | **删掉这个保护**：空树是诚实的，混合树是误导 |
| 树里出现 `当前场站` / `全部场站` | 占位词没换成真实场站名 | 名字取不到就显示 id 前 8 位，让客户来问 |

### 场站选择的唯一真相源

**右上角场站选择器是全局唯一真相源**，树必须持续跟随：

```
tb-station-select 写 StationContextService
  → DashboardPageComponent#applyStationToState
    → state 的 siteCtx
      → 部件订阅 stateChanged()
```

**跨看板可靠通道是 cookie**：生产构建拿不到 Angular 注入器
（`window.ng` 只有 `ɵcompilerFacade`），cookie 是唯一稳定的跨边界载体。

### 场站 Id 要校验有效性

| 判据 | 含义 |
| --- | --- |
| 在 `/api/energy/visible-sites` 里，但没表 | 真没挂表 → 提示「去设备档案挂表」 |
| **不在清单里** | Id 不成立 → 静默丢弃或换成有效场站 |

客户浏览器里可能残留已删除场站的 id。三处都要校验：启动后、场站巡检、
建树前最后一道。漏任一条，失效 id 就会漏到界面上。

---

## 六、部件开发

| 报错 / 症状 | 原因 | 修 |
| --- | --- | --- |
| `Widget Error: Cannot read properties of undefined` | 脚本顶层读了 `self.ctx`（此时还没注入） | 上下文一律在 `onInit` 里绑 |
| `Unexpected identifier 'xxx'`（xxx 是普通词） | 注释里写了裸反引号，提前结束模板字符串 | 见下 |
| 页面卡死 / 变更检测无限循环 | 模板调用了返回新数组的函数 | 改用 `scope.xxx` 缓存 |
| `mat-tab` 页签不显示 | `mat-tab` 上用了 `*ngIf` | 用 `[hidden]` 或改结构 |
| `[(ngModel)]="obj?.a"` 整块不渲染 | Angular JIT 直接失败 | 换成 `[ngModel]` + `(ngModelChange)` |
| dev 模式报 NG0100 | `mat-select` 用了 `placeholder` | 改 `mat-label` |
| 部件自绘控件与其他看板两套样式 | 没复用同类控件 | 日期用 `energy-date-picker`，下拉用 `mat-select`（**不要**用 `tb-datetime`，见上文第四层） |
| N 个 worker 轮询队列只处理前 N 条 | 并发写法错误 | 用显式分批 |

### 反引号这个坑踩过三次

部件源码的两种形态都是**反引号模板字符串**：

```js
const controllerScript = `...`;       // ① src/*.js 片段拼进去
export const DATA_LAYER = `...`;      // ② 共享数据层自身
```

在注释里写 `` `type1` ``、`` `elec` ``，那个反引号会**提前结束字符串**，
后面的中文注释被当代码 → 报 `Unexpected identifier 'type1'`。

**规矩**：

1. 模板字符串内的注释一律不用反引号，要强调用「」或裸写标识符
2. 报错是普通单词 → **先找最近的注释里的反引号**，别查那个单词的拼写
3. 错误行号是模板**结束**的位置，不是真正出问题的位置

定位脚本：

```python
s = open('nenghaobao/widgets/lib/energy-data.mjs').read()
i = s.index('export const DATA_LAYER = `') + len('export const DATA_LAYER = `')
j = i
while j < len(s) and not (s[j] == '`' and s[j-1] != '\\'):
    j += 1
print('模板长度', j-i, '结束于第', s[:j].count(chr(10))+1, '行')
```

结束行远早于预期 → 有裸反引号。

---

## 七、安装与升级

| 症状 | 判据 | 修 |
| --- | --- | --- |
| 脚本一开始就报「守护进程未运行」 | 见下「Docker 起不来」 | — |
| 脚本卡住几分钟不动、不报错 | `docker info` 无响应 | 见下「Docker 卡死」 |
| 就绪后什么都没打印就退了，没建出管理员 | 旧版 02 的 `CODE=$(curl …)` 没 `\|\|` 保护 | 换新脚本，或直接看下一条 |
| 创建管理员报 HTTP 000 / 502 | 后端刚起，gateway 还没就上 | 等 30 秒重跑同一条命令 |
| 全新库安装到「建库」就失败 | 见下 | — |
| 重装脚本崩了，`APP_HOME: unbound variable` | 脚本从错误目录调用 | 在部署目录执行 |
| **`bash: scripts/xxx.sh: No such file or directory`** | 部署目录的 scripts/ 是旧的 | `32-check-deploy-sync.sh --fix` |
| 装完自检 `missing=2`（费率 + 电表 Key 节点） | 租户级主数据未铺 | 重跑 `02-onboard.sh` |
| 跑完验收再跑初始化，报「Σ峰谷 ≠ energy」 | 演示数据被重复写入 | 清遥测后重跑 |
| 切 Cassandra 后大面积「0 台 / 没有数据」 | 遥测后端切换后数据在新库 | 重新灌数据，或切回 SQL |
| Cassandra 无限重启，平台 502 | 内存不足 / 数据目录权限 | 见 [① 安装 · Cassandra](/admin/install#cassandra) |
| 峰谷/电能质量慢，或报 `relation "ts_kv" does not exist` | 遥测后端是 cassandra | 见下「遥测后端选错」 |

### Docker 起不来：`docker 守护进程未运行`

> **命令因机器而异，别跨平台照抄。** 脚本会自己判平台（见
> `docker-01-install.sh` 第 1 节），下面是你手工介入时的对照。

| 机器 | daemon 没启动 | 权限不足 |
| --- | --- | --- |
| Ubuntu / Debian | `sudo systemctl start docker` | `sudo usermod -aG docker $USER && newgrp docker` |
| CentOS 7 / RHEL | 同上（7 没有 dnf，但 systemctl 一样有） | 同上 |
| macOS | `open -a Docker`，等鲸鱼图标停转 | 不该出现；先看 `docker context ls` 是否是 `desktop-linux` |

> Linux 上先确认真的是「没启动」而不是「没权限」：
>
> ```bash
> docker info >/dev/null 2>&1 && echo OK || echo 失败
> sudo systemctl status docker --no-pager | head -5
> ```
>
> `Active: active (running)` 但 `docker info` 报 `permission denied` → 是权限，不是启动。

### Docker 卡死：脚本挂住不返回（本次实测坑）

**症状**：`docker info` / `docker ps` / `docker version` 跑下去**不报错也不退出**，
几十秒到几分钟一直挂着；而 `docker compose` 相关脚本看起来像「卡在检查环境」。

**为什么容易误判**：daemon 进程在、socket 文件也在，你以为是没启动，于是
去 `open -a Docker` 或 `systemctl start` —— 都没用，因为它本来就在。

**判据**（两行分清楚）：

```bash
ls -l ~/.docker/run/docker.sock        # macOS；Linux 是 /var/run/docker.sock
curl -s -m 5 --unix-socket ~/.docker/run/docker.sock http://localhost/_ping
# 有输出 {"OK":...} = 正常；超时无输出 = 卡死
```

**实测形态（macOS）**：宿主侧 `com.docker.backend` 握着 socket 但不应答，
VM 里面的 dockerd 其实是健康的（`~/Library/Containers/com.docker.docker/
Data/log/vm/dockerd.log` 里有 `Daemon has completed initialization`），
连 `osascript quit` 都退不掉 backend —— 那本身就是它卡住的证据。

```bash
# macOS
osascript -e 'quit app "Docker"'
# 等 30 秒；还在就强杀
pkill -f com.docker.backend
open -a Docker

# Linux
sudo systemctl restart docker
sudo journalctl -u docker -n 50 --no-pager
```

验证 `docker info` 能在 1-2 秒内返回即好。仍不行：菜单栏鲸鱼 → Troubleshoot → Restart。

> 卡死时**不要**重跑安装脚本、不要 `docker compose down` —— 它们会一起挂住。
> 先把 daemon 救活。

### 看板整片空白，但菜单和页面框架正常（2026-11-03 实测）

**症状**：登录后左侧菜单完整、看板标题也在，但**所有部件区域全是空白**，
只剩右上角的全屏/下载图标。看起来像「数据没初始化」，但换哪个账号都一样。

**先查一条，不要先查数据**：F12 选中任一部件的容器，看它的 DOM。

```
<div class="eqtc-head">…</div><!----><!----><!----><!----><!----><!---->
       ↑ 静态内容正常                        ↑ *ngIf/*ngFor 全变成空注释
```

**判据**：`{{ 插值 }}` 和静态 HTML 正常渲染，但所有 `*ngIf` / `*ngFor`
控制的内容变成 `<!---->`，**控制台零报错、后端日志也没有**。

**根因**：TB 部件模板是运行时 JIT 编译的（`createDynamicComponent`）。
Angular 20 下**只传 `imports: [CommonModule]` 时，它的 exports 没有展开
进动态组件作用域** ——

| 写法 | 结果 |
| --- | --- |
| `{{ x }}` / 静态 HTML | ✅ 正常（不需要指令） |
| `@if` / `@for`（新 control flow） | ✅ 正常（编译器内建） |
| `*ngIf` / `*ngFor` / `[ngIf]` | ❌ `<!---->`，**静默失败** |

**影响面**：看板引用的 **42 个部件 100% 都用了 `*ngIf`** —— 所以是
「所有功能都不好使」，不是个别页面。数据、账号、权限全部没问题。

**修复**：已在 `ui-ngx/src/app/core/services/dynamic-component-factory.service.ts`
里显式列出指令：

```ts
let componentImports: Type<any>[] = [
  CommonModule,
  NgIf, NgForOf, NgSwitch, NgSwitchCase, NgSwitchDefault,
  NgClass, NgStyle, NgTemplateOutlet, AsyncPipe
];
```

这是 `ui-ngx/src/**` 的改动，**改 JSON 救不了**，必须重新构建：

```bash
cd ui-ngx && ./node_modules/.bin/ng build --configuration production   # 约 5-6 分钟
cd ../guard-server && mvn -o package -DskipTests
cp target/guard-server-4.4.0.jar ~/energy-app/
cd ~/energy-app && docker compose --profile split restart energy-server
```

> **为什么会误判成「数据没初始化」**：
> ① `WidgetComponent.detectChanges()` 里有个 `catch (e) { /* 静默 */ }`，
> 模板异常被完全吞掉 —— 浏览器控制台、后端日志、网关日志三处都没有错误。
> ② 插值 `{{ }}` 正常，很容易让人以为模板没问题，其实它根本不需要指令。
> ③ 部件接口（`/api/tenant/assets`、`.../attributes/SERVER_SCOPE`）全部 200，
> 数据一条不缺，查数据方向全是死胡同。
>
> 新增部件若用到其它指令（如 `NgComponentOutlet`），也要去
> `dynamic-component-factory.service.ts` 补进 imports。
> 写新模板建议直接用 `@if`/`@for`，不受 imports 影响。

### 部件能看到，但按钮 / 下拉框样式不对（2026-11-04 客户报）

**症状**：部件内容都在（文字、图标、布局都是对的），但**按钮没有背景色、没有圆角**，
下拉框与输入框高度怪异。客户描述往往是「TB 的公共样式丢了」。

**先跑脚本，不要先看代码**。在部署目录：

```bash
cd ~/energy-app
bash scripts/33-check-widget-style.sh
```

它分四层查，直接告诉你哪一层坏了：

| 层 | 查什么 | 坏了会怎样 |
| --- | --- | --- |
| L1 | jar 里的前端产物（production / development / 缺失） | 没前端 → 整页空白；development → 能用但不是发布版 |
| L2 | 全局 CSS 可访问性 + **Content-Type** | 404 或 MIME 错成 `application/json` → 整页无样式 |
| L3 | 库里部件的 `templateCss` 与 HTML 内 `<style>` 块 | 两者都为 0 → 这个部件装出来必然无样式 |
| L4 | 部署物料 JSON 完整性 | 新装机最常见：物料不全 |

**四层都正常** → 脚本会打印一段浏览器 Console 代码，去**出问题的那个页面**跑：

```js
// 正常的样子（在本机实测的基线）
{
  bodyClass:      "tb-default",                                    ← 必须有
  hasTbDefault:   true,
  formFieldVar:   "56px",                                          ← TB 表单标准高度
  widgetClass:    "widget-type-system-energy_management-query_panel",
  ngcontentRules: 212,                                             ← 至少一百以上
  styleTags:      62
}
```

**判读**：

| 现象 | 含义 | 怎么办 |
| --- | --- | --- |
| `bodyClass` 里没有 `tb-default` | 白标配置把主题类去掉了 | 检查租户白标设置，恢复默认 |
| `formFieldVar` 为空 | 全局主题变量没加载 | L2 的 CSS 没进来，回看 L2 |
| `ngcontentRules` 是个位数 | **部件私有样式没进 DOM** | 前端产物不对，重打 jar（见下） |
| 都正常，但客户就是看着不对 | 浏览器缓存 | 硬刷新 `Cmd+Shift+R` / `Ctrl+F5` |

**两个容易搞错的点**：

1. **部件里 `<style>` 元素数 = 0 是正常的**。Angular 会把模板里的 `<style>` 提取成
   组件样式，运行时看不到 `<style>` 标签，但规则在（带 `_ngcontent-xxx` 属性）。
   要看规则数，不是看标签数。
2. **`templateCss` 很短不等于丢样式**。像 `query_panel` 的 `templateCss` 只有 391 字符
   （排布用），真正的控件样式在 HTML 的 3 个 `<style>` 块里（共 30614 字符）。

**为什么优先怀疑前端产物**：部件模板是**运行时 JIT 编译**的，
它把 `<style>` 块降级成 `_ngcontent` 规则。如果前端是旧的 development 产物
或根本没有前端，这条链就断了 —— 而**后端物料、数据库、接口全部正常**，
所以查后端永远是死胡同。

重打 jar（不加 `--skip-ui`）：

```bash
cd <仓库目录>
bash guard-server/pack.sh
```

### 遥测后端选错：功能慢、或报 `relation "ts_kv" does not exist`

**症状**（三种，同一个根因）：

- 峰谷分析 / 电能质量要等很久才出数，或干脆报 500
- 后端日志刷 `PreparedStatementCallback; bad SQL grammar [...] FROM ts_kv`
- 手册⑩的运维 SQL 复制到 psql，一条都跑不了

**判据（一条命令）**：

```bash
docker exec energy-server env | grep DATABASE_TS_TYPE
```

- `sql` → 正常（遥测在 Postgres 的 `ts_kv` 表）
- `cassandra` → 遥测在 Cassandra，**Postgres 里没有 `ts_kv` 表**

**为什么会这样**：平台有两套遥测后端。业务代码（峰谷小时桶、电能质量圈选）
与手册里的运维 SQL 都是围绕 `ts_kv` 写的；Cassandra 部署下这些路径要么降级
（慢一个数量级），要么报错。

> 2026-11-03 之前，安装脚本按**物理内存**自动选：≥10GB 就上 Cassandra。
> 结果是 16GB 的机器选了 Cassandra，现场表现成「看板空白 / 功能不好使」，
> 排查很久才定位。**现在默认已是 `sql`**（`docker-00-prepare.sh`）。

**平台已做的适配**：查历史前先探测后端类型（`TelemetryBackend`），
走不通就自动降级走 `timeseriesService` —— 不会再砸 500，但**降级就是慢**。

**要换回 sql**（推荐，除非数据量真到千万行以上）：

```bash
# 1. 改 .env
DATABASE_TS_TYPE=sql

# 2. 清库重建（遥测不会自动迁移，旧数据留在 Cassandra 卷里）
cd ~/energy-app && bash docker-99-uninstall.sh --purge --yes

# 3. 重走三步
bash docker-00-prepare.sh && bash docker-01-install.sh
bash docker-02-start.sh --admin-email ... --admin-pass '...'
```

> **注意**：换后端只是换读取端，`ts_kv` 与 Cassandra 是两套存储。
> 不重建库只会看到「设备在、数据全空」。

**真要 Cassandra 时**：显式指定
`DATABASE_TS_TYPE=cassandra bash docker-00-prepare.sh`，
并接受上表的性能差异。

### `bash: scripts/xxx.sh: No such file or directory`

**这是部署目录里的脚本过期了，不是手册写错。**

`docker-00-prepare.sh` 只在组装时拷一次脚本；之后仓库新增的
（比如 `29-rtu-demo-up.sh`）不会自己跑进已部署的目录。

```bash
# 判据：两个目录对比，差集就是缺的
ls ~/energy-app/scripts/ | wc -l
ls shiyongshouce/downloads/scripts/ | wc -l

# 修（在仓库里跑，不能 cd 到部署目录）
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --fix
```

> 在 `~/energy-app/scripts` 里跑 `32` 会被拒绝 —— 那样是拿自己比自己，
> 永远报「一致」。同理 `31-deploy-widget.sh` 也只能从仓库跑。
>
> 注意区分另一种报错：`bash: scripts/xxx.sh: Permission denied` → 补 `chmod +x`。
> 完全没这个文件 —— 先看是不是自己 cd 到了别的目录（`pwd`）。

### 安装到「建库」就失败

**先分清是哪个失败**：

| 日志 | 原因 |
| --- | --- |
| `No qualifying bean of type ...` | Spring 装配范围问题（install 的 `@ComponentScan` 缺包） |
| `NoSuchFileException: .../sql/schema-entities.sql` | 部署物料 `data/sql` 缺文件 |
| `relation "..." does not exist` | 库非空且版本不匹配 |
| `Connection refused` | 数据库没起 / 密码错 |

**装配问题的判据**：报的是 bean 找不到，而库操作还没开始 →
`ThingsboardInstallApplication` 的扫描范围要包含那个包。

**缺 sql 的判据**：

```bash
ls ~/energy-app/data/sql/*.sql | wc -l    # 必须 8
```

不满 8 个就从源码拷（**不要用 `rsync --delete` 同步整个 `data/`**）：

```bash
cp -R guard-server/src/main/data/sql ~/energy-app/data/sql
```

### 升级后

| 现象 | 原因 |
| --- | --- |
| 报 `resource sql/schema-views.sql not found` | jar 里的 sql 与 data 目录版本不一致 |
| 页面还是旧文案 | 只 `ng build` 没重打 jar（容器挂 jar，不是工作目录） |
| 新脚本报 `No such file or directory` | 部署目录 scripts/ 未同步（见上条） |
| 新部件在库里查不到 | 只同步了文件，没推库 —— 跑 `31-deploy-widget.sh` |

**判据**：`ls -l ~/energy-app/guard-server-4.4.0.jar` 时间戳变了吗？
没变 = 没打进去。

---

## 八、数据口径对不上

| 症状 | 原因 | 修 |
| --- | --- | --- |
| 峰谷分析的数和台账对不上 | 峰谷按「时段切片」，台账按「抄表周期」 | 口径不同，不是 bug |
| 分项图例显示设备名，不是分项名 | 部件取了 `name` 而非维度节点名 | 部件 bug |
| 分项与区域总量对不上 | 同一台表挂到两个区域，双算 | 清多余关系（[⑧ §6.1](/admin/ops-sql#61-场站--区域--分项归属)） |
| 历史能耗只有 A 相和总有功 | 单相表本来没有 B/C 相 | 正常 |
| 分项显示 kWh 但装的是水表 | 品种判定错（档案缺 `energyTypeCode`） | 补档案品种 |
| 数字是天文数字（如 31272 kW·h） | 开关次数被写进 `energy` 键 | 改测点映射 |
| 某天数据莫名偏低 | 汇总窗口没对齐整天 | 见 [⑤](/admin/data-flow) |

### 单位混算（最容易忽略）

资产汇总按品种分键写：电→`energy_total`，水→`water_total`，
气→`gas_total`，汽→`steam_total`，热→`heat_total`。

**热力（GJ）绝不能写进 `energy_total`（kWh）** —— 曾经漏了 `heat` 分支，
于是「锅炉 312 kW·h」看着像电量，实际是 312 GJ 热量。

---

## 九、诊断三步法

不要一上来就翻代码。**按这个顺序，90% 的问题在三步内定位**：

```
① 看现象属于哪一层
     采集 → 存储 → 汇总 → 部件 → 前端
     （表见 [⑤ 数据流] 的八步断点表）

② 拿一条 SQL 验证那一层
     有数据 = 这层没问题，往下游查
     没数据 = 停在这层，别往下查

③ 只有确认是代码问题时才看代码
```

**为什么强调顺序**：页面空白这一个现象，可能是八层里任何一层。
直接从最上游（设备上报）查起，永远比从页面往下猜快。

### 三个「看起来像 bug 其实不是」

| 现象 | 真相 |
| --- | --- |
| 分项能耗选电能是空的 | 水/气/汽/热分项不写 `energy_total`，切品种才出数 |
| 告警中心切场站是一条都没有 | 告警挂在设备上，场站筛选走关系链 |
| 单相表没有 B/C 相数据 | 1P2W 物理上就没有，不是丢数 |

---

## 十、收集现场信息

上报问题时带上这五项，能省一半来回：

```bash
# ① 版本
curl -s http://127.0.0.1:8090/api/noauth/energy/health

# ② 容器状态
docker ps --format '{{.Names}}\t{{.Status}}'

# ③ 后端最近错误
docker logs --tail 100 energy-server 2>&1 | grep -iE "error|exception" | tail -20

# ④ 数据是否在动（换成一个真实设备 id）
docker exec energy-postgres psql -U postgres -d thingsboard -c "
SELECT kd.key, count(*), max(to_timestamp(ts/1000)) AS 最新
FROM ts_kv t JOIN ts_kv_dictionary kd ON kd.key_id=t.key
WHERE t.entity_id='<设备id>' GROUP BY 1 LIMIT 10;"

# ⑤ 浏览器控制台截图（Network 里失败的请求 + Console 报错）
```
