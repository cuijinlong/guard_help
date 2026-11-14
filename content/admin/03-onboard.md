# ③ 开户与销户

给一家客户开账号、清账号。**两条命令**，都幂等、都自带验证。

> 这一页只讲「客户」这一层的增删。
> 平台安装见 [② 系统部署](/admin/deploy)，设备接入见 [⑦](/admin/device-access)。

---

## 一家客户的一生

```
① 开户（一条命令，约 3 分钟）
      bash scripts/09-onboard-customer.sh --email 客户邮箱 --password 密码 --name 客户名
      ↓
② 交钥匙
      账号发给客户 → 登录就见到「能耗概览」+ 15 项菜单 + 满数据
      ↓
③ 客户动手（改造成自己的）
      清演示数据 → 建场站/分项/设备 → 重算汇总（★ 容易漏）→ 接 RTU
      ↓
④ 日常运营（费率、账单、告警）
      ↓
⑤ 销户（合作结束，或建错了要重来）
      bash scripts/10-cleanup-customer.sh --name 客户名 --dry-run   # 先看
      bash scripts/10-cleanup-customer.sh --name 客户名 --yes       # 再删
```

**两条硬规矩**：

1. **开户后一定能看到数**。演示数据 + 资产汇总遥测会一起就位。
   客户登录看到空页面 = 故障，不是「还没配」—— 见 [⑤ 数据流](/admin/data-flow)。
2. **销户只动这一家**。脚本在删前删后各拍一次「其他世界」的指纹快照，
   不一致就退出码 2 报错，绝不静默通过。

---

## 一、开户：一条命令

### 1.1 命令

```bash
cd ~/energy-app
bash scripts/09-onboard-customer.sh \
  --email customer@company.com \
  --password 'Cust@123456' \
  --name '某某公司'
```

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `--email` | ✓ | 客户登录账号；也是客户名默认来源（取邮箱前缀） |
| `--password` | ✓ | 初始密码（客户登录后可改） |
| `--name` | | 客户名称；不传则取邮箱前缀 |
| `--no-demo` | | **不**铺演示数据（客户要直接用自己的数据时用） |
| `--base` | | 平台地址，默认 `http://127.0.0.1:8090` |
| `--tenant-email` / `--tenant-pass` | | 租户管理员凭据；默认从 `../DEPLOY-CREDENTIALS.txt` 读 |

### 1.2 它做了什么

| 步骤 | 动作 | 幂等性 |
| --- | --- | --- |
| 1 | 建客户 + 建客户管理员并**激活**（跳过邮件） | 同邮箱重跑：复用并重置密码 |
| 2 | 铺演示数据（2 场站 / 12 分项 / 21 设备 / 2 拓扑） | 已有则跳过 |
| 2b | **RTU 现场形态**：网关 + 正泰电表 + 温湿度 + 8路继电器 + 8 台 SIM | 自身幂等，只修不建 |
| 3 | **重算资产汇总遥测** | 按时间戳重写，不产生重复点 |
| 4 | 复制看板到客户名下 + 绑定客户菜单 | 已存在则跳过 |
| 5 | 逐项验证，缺任何一项就报错 | — |

> **第 3 步最容易漏也最致命**：看板读的是**资产**上的 `energy_total`，
> 平台不会在设备上报时自动往上汇总。不重算，客户看到的就是一片空。
> 脚本已内置，手工建数据时才需要自己调（见 [⑤ 数据流](/admin/data-flow)）。

### 1.3 期望输出

```
步骤 1/3　建客户与账号
  ✓ 客户已建成
  ✓ 客户账号可登录
  ✓ 客户菜单已绑定
步骤 2/3　确保演示数据（幂等：已有则跳过）
  ✓ 场站：2   分项：12   设备：21   拓扑：2
步骤 2b/3　RTU 网关与下挂设备（正泰电表 / 温湿度 / 8路继电器）
    === ⑥ 网关 ===
      + 网关「ED2-Gateway·某某公司」已建
      + 设备「PowerMeter-DDSU666·某某公司」已建
      + 设备「Sensor-HZ8706·某某公司」已建
      + 设备「Relay-8CH·某某公司」已建
  ✓ 资产汇总已重算
步骤 3/3　逐项验证
  ✓ 全部通过

  登录地址  http://127.0.0.1:8090
  账号      customer@company.com
  密码      Cust@123456
  客户      「某某公司」
```

### 1.3b 演示数据是**两层**，缺一层客户就会说「东西没了」

| 层 | 内容 | 由谁建 |
| --- | --- | --- |
| 现场接入形态 | 网关 `ED2-Gateway·客户名`，下挂 11 台：8 台 `*-SIM` + `PowerMeter-DDSU666`（正泰单相电表）+ `Sensor-HZ8706`（温湿度）+ `Relay-8CH`（8路继电器） | `scripts/30-rtu-env-init.py` |
| 分项 / 区域 / 多品种 | 单相园区 / 三相园区 / A栋锅炉…（21–31 台，带 `demo:true`），覆盖照明/插座/动力/给排水/炊事/蒸汽/空调 | `POST /api/energy/demo-data` |

两者**互补，不是二选一**。只跑 demo-data 会得到「有分项、没网关」的半套数据，
客户登录后找不到任何现场设备。脚本已把 2b 内置，手工重建时才需要单独跑。

> **设备名为什么带 `·客户名` 后缀**：TB 的设备唯一键是 `(tenant_id, name)`。
> 不带后缀会撞上主演示客户「平台演示中心」那套真实 RTU 设备，
> 而 TB 不允许改 owner，最后两个客户互相污染。
> 只有真实板子（`ED1-Gateway` 那套）用无后缀名 —— 名字在 `rtu/main.py` 里写死。

### 1.3c 清除演示数据：客户列表行内「清除演示数据」（2026-11-14 实测）

入口：**客户列表 → 行尾操作列 → 清除演示数据**（自检页也有同名按钮，同一个后端接口）。

**它只删 `additionalInfo.demo=true` 的实体**，客户自己建的资产/设备一个不动。
因此确认框里的数字会**小于**客户的总资产数 —— 这是正常的，不是漏算。

实测（本环境「平台演示中心」）：

```
确认框：将删除「平台演示中心」的演示数据：资产 63 个、设备 10 台…
库里  ：资产总数 88，其中 demo=true 63  ← 完全吻合
        设备总数 35，其中 demo=true 10  ← 完全吻合
未标记的 25 个：19 张账单 + 4 个维度根 + 1 个分项 + 1 个场站（自建，不会被删）
```

实测删除一个真实客户（zz客户B）的结果：

```
返回 {devices: 0, assets: 41, bills: 19}
资产 64 → 4（只剩四个维度根）、账单 19 → 0
```

**它删得干净 —— 不要因为怕留垃圾而不敢用**：

| 指标 | 删前 | 删后 |
| --- | --- | --- |
| 孤儿 `attribute_kv` | 98 | **98**（零增量）|
| 孤儿 `relation` | 362 | **302**（反向减少 60）|

代码里对每个实体先调 `deleteRelations` + `removeAttributes`，不靠数据库级联
（本库没有任何非内部触发器）。

#### ⚠ 它不会删什么（最重要）

| 留下的 | 为什么 | 想真清则 |
| --- | --- | --- |
| 4 个维度根 `energy_*_library` | 客户级结构，没打 demo 标记；重建演示数据要靠它 | 随客户一起删（见第二节销户）|
| 客户本身 | 这不是销户接口 | `DELETE /api/customer/{id}` 或销户脚本 |
| 用户账号 | 同上 | 单独删或随客户级联 |

> **「清除演示数据」≠「销户」。** 客户不合作/建错了要整个拿掉，用
> [二、销户](#二销户连数据一起清) 的脚本；只是把演示数据换成真实数据，用本功能。

#### ⚠ 手工调接口必须带 customerId

```bash
# 预览（不删）
curl -s --noproxy '*' -H "X-Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8090/api/energy/demo-data?customerId=<客户id>"

# 执行
curl -s --noproxy '*' -X DELETE -H "X-Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8090/api/energy/demo-data?customerId=<客户id>"
```

**`customerId` 不传 = 全租户范围**（后端 `resolveCustomer` 返回 `null`，
而 `ownedBy(owner, null)` 恒为 true）。不传会把**所有客户**的演示数据一起清掉。
界面上走菜单不会踩到（它总是带 id），手敲 curl 时必须检查。

### 1.4 三个必须知道的坑

**① 账号建完是「未激活」的**

TB 新建用户默认没有密码、`enabled=false`，登录会返回
`User account is not active`。脚本用两步绕过：

```
GET  /api/user/{id}/activationLink   → 拿激活 token
POST /api/noauth/activate?activateToken=...   → 真正设密码并置 active
```

手工建账号时漏掉任一步，账号就永远登不进去。

**② `sendActivationMail=false` 必须带**

平台没配 SMTP 时，默认 `true` 会让建用户直接 500
（`Couldn't send user activation email`）。

**③ 客户名在租户内要唯一**

脚本用邮箱前缀做默认客户名，**不同客户必须不同邮箱前缀**。
两台客户同名会互相覆盖演示数据。

---

## 二、销户：连数据一起清

### 2.1 先看会删什么（不删）

```bash
cd ~/energy-app
bash scripts/10-cleanup-customer.sh --name '某某公司' --dry-run \
  --tenant-email tenant@example.com --tenant-pass '租户密码'
```

**输出示例**：

```
✓ 预检：13 台设备全部属于「某某公司」
✓ 预检：客户名下实体租户归属一致

============================================================
  即将删除：「某某公司」
============================================================
 客户 ID    e0384770-d692-11f1-9295-1bafc3e17d70
 场站 2   分项 12   拓扑图 2   资产合计 45
 设备       13
 看板副本   27
 用户       2
 遥测数据   167575 个数据点（一并删除）
------------------------------------------------------------
 影响面     仅此客户。其他客户 290 个实体（含租户级）已拍快照，
            删后逐项校验，不一致会报错退出。
------------------------------------------------------------
  此操作不可恢复。平台没有客户级回收站。
✓ 只盘点不删除（--dry-run）
```

**对着这一段核对一遍**：设备数、用户数、遥测点数对不对。
对不上就是定位错了客户，别往下走。

### 2.2 确认后执行

```bash
bash scripts/10-cleanup-customer.sh --name '某某公司' --yes \
  --tenant-email tenant@example.com --tenant-pass '租户密码'
```

### 2.3 定位客户的三种方式

| 参数 | 何时用 | 说明 |
| --- | --- | --- |
| `--id <uuid>` | 最可靠 | 客户 uuid，从库或 URL 里拿 |
| `--name '<客户名>'` | 常见 | 客户名完全匹配 |
| `--email <邮箱>` | 知道账号不知道客户名 | 用用户表反推 customer_id |

优先级：`--id` > `--name` > `--email`。

### 2.4 它删什么，不删什么

**删（不可恢复）**：

| 表 | 内容 |
| --- | --- |
| `customer` | 客户本身 |
| `tb_user` / `user_credentials` | 账号与密码 |
| `asset` / `device` | 资产与设备 |
| `relation` / `attribute_kv` | 关系与属性 |
| `dashboard` | 复制给该客户的看板副本 |
| `ts_kv` | 遥测（默认删，`--keep-telemetry` 保留） |
| `custom_menu` | 该客户的菜单（确认无其他客户引用才删） |

**不删**：租户、租户管理员、其他客户、租户级主数据（字典 / 档案 / 费率模板 / 分时方案）。

> **还有一个容易漏的空分组**：TB 会为每个客户的看板建一个
> `<客户名> Dashboards` 的 `entity_group`，它的 `owner_type` 是 **TENANT**
> 而不是客户，所以 `deleteCustomer` 的 `deleteAllEntityGroups(tenantId, customerId)`
> **碰不到它**，会留一个空壳分组在那里（2026-11-14 实测）。
>
> 它不是脏数据也不是故障 —— 只是个空分组。想去掉就单独删：
>
> ```bash
> curl -s --noproxy '*' -X DELETE -H "X-Authorization: Bearer $TOKEN" \
>   "http://127.0.0.1:8090/api/entityGroup/<分组id>"
> ```
>
> 不要直接写 SQL 删 `entity_group` —— 应用层有缓存，绕过 API 会读到旧值。

> **共享看板的客户分配会自动清理（2026-11-14 已修）**
>
> 租户级共享看板有一列 `assigned_customers`，记录「哪些客户能看到这块看板」。
> 删客户时**它原先不会被清理** —— 每删一个客户就在每块共享看板里留一条
> 指向已删客户 id 的死引用（实测删一个客户 → 29 块看板各留 1 条）。
>
> 而且删完就再也解绑不掉：`unassignDashboardFromCustomer` 开头校验客户存在，
> 客户没了直接抛异常。所以只能在删客户时一并清。
>
> 已修（`CustomerServiceImpl.deleteCustomer` 里加了一行 native query），
> 现在删客户后 `assigned_customers` 自动摘干净。**用旧版本删过客户的，
> 库里可能已有残留**，检查方法：
>
> ```sql
> -- 列出 assigned_customers 里指向不存在客户的看板
> SELECT d.title,
>        elem ->> 'title' AS stale_customer
> FROM dashboard d,
>      jsonb_array_elements(CAST(d.assigned_customers AS jsonb)) elem
> WHERE elem -> 'customerId' ->> 'id' NOT IN (SELECT id::text FROM customer);
> ```
>
> 有结果就说明是历史残留（不影响功能，只是脏数据），按同样逻辑清一遍即可。

> **为什么必须单独清 `ts_kv`**：TB 删设备**不会**删遥测 ——
> 数据按 `entity_id` 存在分区表里，设备没了数据还在，会一直占盘。

### 2.5 安全性：它怎么保证不误删

脚本在删除前后各做一次「目标以外世界」的指纹快照（实体数 + 全库 id 的 md5），
删完必须逐位相同。任何一项不符 → **退出码 2** 并打印差异。

另有三个预检，不通过直接中止：

| 预检 | 防什么 |
| --- | --- |
| 待删设备必须真属于该客户 | 拿错 id 去删了别人的遥测 |
| 目标不能是 null uuid | 误删租户/系统实体 |
| 删除前后确认客户存在性 | 删了不存在的东西 / 没删掉 |

**退出码**：`0` 成功 / `1` 参数或前置失败 / `2` 隔离校验不通过（需人工介入）。

### 2.6 保留遥测（重开户复用数据）

```bash
bash scripts/10-cleanup-customer.sh --name '某某公司' --keep-telemetry --yes
```

客户和设备删了、遥测留着。**注意**：设备删了遥测就成孤儿，
只有在「马上要用同一个设备 id 重建」时才有意义。一般不要用。

---

## 三、常见误解

| 以为 | 实际 |
| --- | --- |
| 删了客户，遥测自动清 | ❌ TB 不删遥测，必须脚本清（已内置） |
| 建了账号就能直接登录 | ❌ 要激活（脚本已处理） |
| 客户名可以重复 | ❌ 租户内唯一，不同客户必须不同名 |
| 销户会连带删租户 | ❌ 只删客户；租户要单独处理 |
| 演示数据清掉就够了 | ❌ 还要**重算汇总**，否则看板仍是旧值 |
| 客户之间会串数据 | ❌ 靠 customer_id 隔离；租户级主数据才是共用的 |

---

## 四、速查

```bash
# 开户（带演示数据）
bash scripts/09-onboard-customer.sh --email x@y.com --password 'X@1' --name '某公司'

# 开户（不带演示数据，客户马上建自己的）
bash scripts/09-onboard-customer.sh --email x@y.com --password 'X@1' --no-demo

# 销户——先看
bash scripts/10-cleanup-customer.sh --name '某公司' --dry-run

# 销户——执行
bash scripts/10-cleanup-customer.sh --name '某公司' --yes

# 销户——按 uuid（最可靠）
bash scripts/10-cleanup-customer.sh --id e0384770-d692-11f1-... --yes

# 销户——保留遥测
bash scripts/10-cleanup-customer.sh --name '某公司' --keep-telemetry --yes
```

**两个脚本都要租户管理员凭据**。默认从 `../DEPLOY-CREDENTIALS.txt` 读
（`docker-00-prepare.sh` 生成的）。没有这个文件就显式传
`--tenant-email` / `--tenant-pass`。
