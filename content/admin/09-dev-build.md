# 开发与构建：改代码 → 生效要多久

这一页给**要在部署现场改代码的人**（运维、实施、二次开发）。
如果你只是用平台，看 ①②③ 就够，不用读这页。

---

## 一、先看真实耗时（实测，2026-10-23）

```
mvn compile   改一行代码          452 s   ← 92% 的时间在这一步
mvn package   （编译已完成）        52 s
javac 单文件                        7.5 s
jar uf 原地更新 jar                 19 s
复制 426MB 到部署目录                5 s
容器重启到 healthy                 245 s
```

**完整的「改一行 → 页面生效」**：

```
走 mvn package     452 + 57 + 5 + 245 = 759 s   ≈ 12.5 分钟
走增量构建          26       + 245 = 271 s      ≈ 4.5 分钟
```

### 452 秒是怎么来的

不是机器慢，是 Maven 的增量编译对这个模块失效：

```bash
# 只改 1 个 .java，实际重编了多少 class
touch src/main/java/com/guard/server/util/SqlTrace.java
mvn compile
# 实测：8351 / 9315 个 class 被重写（91%）
```

模块里 9315 个类、405 个依赖 jar，javac 每次全量分析，所以改一行和改一百行一样慢。

### 拆 Maven 模块能解决吗

**不能。** 拆模块不会让 javac 变快，只会拉长构建链（多模块 reactor 串行）。

我也试过「不打包，直接跑 classes 目录」（exploded 部署），结果**更慢**：

```
java -cp "classes:lib/*" 主类
实测启动 675 s，比 fat jar 的 224 s 慢 3 倍
```

原因是 Spring Boot fat jar 里有 `classpath.idx` 索引，类定位是 O(1)；
exploded 目录下 405 个 jar 要逐个扫描。**这条路已排除。**

---

## 二、增量构建：`dev-fast-build.sh`

### 2.1 用法

```bash
cd ~/energy-app

# 改完代码：自动找最近 2 小时改过的 .java，编译 + 更新 jar + 重启
bash scripts/dev-fast-build.sh --deploy

# 指定文件
bash scripts/dev-fast-build.sh CustomerUserPermissions.java --deploy
bash scripts/dev-fast-build.sh service/security/permission/CustomerUserPermissions.java

# 只编不部署（攒几处改动一起上，省掉多次 245 秒重启）
bash scripts/dev-fast-build.sh

# 改动很多（>20 个文件）：退回全量 javac，仍比 Maven 快
bash scripts/dev-fast-build.sh --all --deploy

# 主 jar 被 mvn package 覆盖后，重建编译缓存
bash scripts/dev-fast-build.sh --sync
```

### 2.2 它做了什么

```
① 首次运行：把 fat jar 解成 ~/energy-app/.build/{classes,lib}   （约 40 秒，一次性）
② javac 只编改动的 .java，classpath 指向 ① 的 classes + 405 个 jar   （约 7 秒/文件）
③ jar uf 把新 .class 原地写进 fat jar（不重打 426MB）              （约 19 秒）
④ 重启容器                                                      （约 245 秒）
```

第 ③ 步是关键：`mvn package` 每次要重新压缩 426MB，而 `jar uf` 只追加几个 entry。

### 2.3 ⚠ 什么时候必须回 `mvn package`

增量脚本有明确边界，**这些情况它会出错或失效**：

| 改了什么 | 为什么不行 | 怎么做 |
| --- | --- | --- |
| `pom.xml`（增删依赖） | 依赖 jar 变了，`.build/lib` 是旧的 | `mvn package` |
| `src/main/resources/**` | 脚本只处理 `.java` | `mvn package` |
| 方法签名 / 字段类型 | 依赖它的类没重编 → 运行期 `NoSuchMethodError` | `mvn package` |
| lombok 注解结构 | 注解处理器不在增量路径里 | `mvn package` |
| 出正式包给客户 | 增量产物未经验收 | `mvn package` + 全套验收 |

脚本里有个兜底：检测到「改动文件 > 20 个」会自动退回全量 javac。

### 2.4 实测记录

```bash
$ bash scripts/dev-fast-build.sh CustomerUserPermissions.java --deploy
[17:21:56] 同步编译缓存（jar 有更新，重新解出，约 40 秒）
  ✓ 缓存已就绪（classes 123M / lib 393M）
[17:22:32] 单文件编译 1 个
  ✓ 编译完成：15 个 class，耗时 7s
[17:22:40] 原地更新 fat jar（不重打 426MB）
  ✓ jar 已更新 15 个 entry，耗时 18s
[17:22:58] 总耗时 26s（对比 mvn package 约 509s）
[17:22:58] 重启服务（约 224 秒，Spring 启动无法省）
  ✓ 服务 healthy（210s）
```

---

## 三、客户视角权限探针

### 3.1 为什么需要它

普通 API 验收只调「我们认为重要」的接口。但**客户打开页面时是看板部件在发请求** ——
部件会去读租户级主数据（能源品种、参数字典），客户没有权限，于是 403、图表空白。

这类问题在 API 级断言里**永远看不见**。实测两次教训：

- 74 项验收全绿的同时，客户打开看板有 22 条 403（见「现象 I-2」）；
- 295 条探针全通的同时，客户打开「能耗概览」是 4 张 `0.0` 卡片
  —— 因为部件查了品种资产，接口返回 `200 + {}`，被当成通过。

所以探针有两条判据：**状态码**（4xx/5xx）和**语义**（非空、取数目标合法）。

### 3.2 用法

```bash
cd ~/energy-app
python3 scripts/27-customer-surface-probe.py \
  --base http://127.0.0.1:8090 \
  --tenant tenant@126.com --tenant-pass '12345678' \
  --customer customer@126.com --customer-pass '12345678' \
  --strict

# 期望：失败 0 条，退出码 0
```

加进验收脚本时用 `--strict`：有任何 4xx 退出码 2。

### 3.3 它探什么

```
① 客户自有资源
     每台设备的 timeseries / 属性
     每个资产的 timeseries / 属性 / Contains 关系
     每个看板的 config

② 看板里引用的非自有实体
     解析每份看板 JSON，抽出全部 uuid，排除客户自有的
     逐个探属性与关系 —— 这类 id 是「配置泄漏」的典型

③ 部件运行时才拿到的 id（最容易漏的一类）
     调 /api/energy/metric-params，拿 kinds[].id 和 libraryId
     逐个探 paramDict / 全属性 / Contains 关系 / 资产详情
```

第 ③ 组是这次漏检的根源：那些 id 不在看板 config 里，
只有部件跑起来才知道 —— 必须显式探。

```
④ 语义断言（200 不等于有数据）
   S1 设备有遥测 → 所属场站的 energy_total 必须非空
      否则设备页有数、场站页和概览页是 0
   S2 看板 alias 不能把品种/字典资产当取数实体
      它们只有属性没有遥测，查出来必然空；子树还跨同租户全部客户
```

S1 的窗口取 3 天（容忍定时汇总间隔与 RTU 上报周期），
S2 的品种 id 来自 `/api/energy/metric-params`（`kinds[].id` + `libraryId`）。

### 3.4 ⚠ 不要往探针里加这两条

```python
# ✗ 不要加
/api/deviceProfiles?pageSize=100&page=0
/api/assetProfiles?pageSize=100&page=0
```

它们写死了 `@PreAuthorize("hasAuthority('TENANT_ADMIN')")`，客户**永远** 403 ——
但客户页面并不会调用它们：

- `query_panel` 只在 `if (!cid)`（租户分支）里取档案列表，客户走 `metric-params` 分支
- `assetProfiles` 前端没有任何部件调用
- `energy_source_select` / `meter_type_config` 用 `deviceProfiles`，但它们是租户配置页部件

2026-10-23 首次跑探针时把这 2 条加进去了，报了 2 个「缺陷」，排查半天才发现是探针自己编的。
**判定客户真实会触发什么，依据只能是部件源码（`controllerScript`），不是「看起来像主数据就该能读」。**

---

## 四、改完代码的标准动作

```bash
# ── 1. 改代码（仓库里）
cd ~/Documents/workspace/iot-rule-engine

# ── 2a. 只是方法体小改 → 增量
bash ~/energy-app/scripts/dev-fast-build.sh --deploy

# ── 2b. 改了 pom / 资源 / 签名 → 全量
cd guard-server && mvn package -DskipTests -o
cp target/guard-server-4.4.0.jar ~/energy-app/
cd ~/energy-app && docker compose --profile split --profile cassandra \
  restart energy-server      # ⚠ 默认后端是 Cassandra，漏了 profile 会起不来

# ── 3. 验证（至少这四条）
bash scripts/ts-mirror.sh                                    # Cassandra 后端必跑：镜像遥测到 PG
python3 scripts/27-customer-surface-probe.py ... --strict    # 客户视角无 4xx + 语义断言通过
bash scripts/08-verify-release.sh ...                        # 75 项
bash scripts/06-verify-e2e.sh ...                            # 53 项

# ── 3b. 改了看板/部件 → 浏览器实测（探针只打接口，看不到渲染）
#        用客户账号打开「能耗概览」，确认四张卡有数字、日历有热力

# ── 4. 改的是功能点 → 同步手册
cd shiyongshouce && python3 check-docs.py && ./sync.sh

# ── 5. 发布（Cloudflare Pages 部署这个仓库）
cd ../guard_help && git add -A && git commit -m 'update manual' && git push
```

### 前端改动（ui-ngx）额外一步

```bash
cd ui-ngx
node --max_old_space_size=8192 ./node_modules/@angular/cli/bin/ng build --configuration production
cd target/generated-resources && jar cf /tmp/ui-ngx-4.4.0.jar public
cp /tmp/ui-ngx-4.4.0.jar ~/Documents/dev_tools/maven_repository/rule-engine/org/thingsboard/ui-ngx/4.4.0/
# 然后必须重新 mvn package —— 前端产物是作为 jar 依赖打进去的
cd ../../guard-server && mvn package -DskipTests -o
```

> 前端改动**不能用增量脚本**：`ui-ngx` 是独立的 jar 依赖，
> `jar uf` 改不了嵌套 jar 里的资源。

---

## 五、还能再快吗

| 手段 | 效果 | 代价 | 值不值 |
| --- | --- | --- | --- |
| 增量构建（已做） | 改一行 452→26 s | 有边界，见 2.3 | ✓ 已落地 |
| 减少重启次数（攒改动） | 每次省 245 s | 验证粒度变粗 | ✓ 推荐 |
| Spring DevTools 热重载 | 省掉大部分重启 | 只对方法体有效；字段/上下文改动仍要重启 | 一般 |
| `-XX:TieredStopAtLevel=1` + `-Xverify:none` | 启动快 ~15% | 只适合开发，性能下降 | 现场调试可试 |
| 拆分 Maven 模块 | **无效** | 构建链变长 | ✗ 不建议 |
| exploded 部署 | **更慢**（675 s） | — | ✗ 已实测排除 |
| JVM CDS / AppCDS | 启动快 20–30% | 要生成归档，jar 一改就失效 | 反复重启时值得 |

**当前的瓶颈是 Spring 启动的 245 秒**，编译已经压到 26 秒。
要继续压缩只能动启动路径（CDS 归档、懒加载、精简自动配置），那是另一件事，
且会影响生产环境行为 —— 不建议在没有压测的情况下动。
