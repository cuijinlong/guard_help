# 运维总览

这是平台运维手册的入口。**每页只讲一件事**，需要什么直接翻对应页。

---

## 我是谁，该看哪页

| 你的场景 | 看这页 |
| --- | --- |
| 第一次装平台，或改完代码要发布 | [② 系统部署](/admin/deploy) |
| 发给客户一个账号，让他直接用 | [③ 开户与销户](/admin/onboard) |
| 客户不合作了，连数据一起清掉 | [③ 开户与销户](/admin/onboard) |
| 想知道库里到底有什么表、什么字段 | [④ 数据模型](/admin/data-model) |
| 数据从表计到看板中间经历了什么 | [⑤ 数据流](/admin/data-flow) |
| 告警怎么配、指标怎么算 | [⑥ 规则](/admin/rules) |
| 现场 RTU 连不上 / 要让设备上报 | [⑦ 设备接入](/admin/device-access) |
| 数据看着不对，想查库核实 | [⑧ 运维 SQL](/admin/ops-sql) |
| 报错了、页面空了 | [⑨ 排障](/admin/troubleshoot) |
| 改了代码要生效 | [⑩ 开发与构建](/admin/dev-build) |
| 客户怎么用（不是运维看的） | [客户使用手册](/user/index) |

---

## 三条最短路径

### 一、装平台 / 发新版本（共一页）

**只有一页：[② 系统部署](/admin/deploy)。** 进去先选场景：

| 你的处境 | 那段 | 一句话 |
| --- | --- | --- |
| 全新机器，或刚跑过 `uninstall --purge` | 场景 A | 打 jar → 打发布包 → 传过去 → 装 |
| 已装好，只想换版本 | 场景 B | 同步物料 → 换 jar → 重启 |
| 只改了部件 JSON / 脚本 | 场景 C | 推库，不用打 jar |

全流程的命令、判据、失败处理都在那一页。这里只列最常见的两条入口：

```bash
cd <仓库>

# ── 发到新机器 ──────────────────
bash guard-server/pack.sh                                        # 打 jar（约 12 分钟）
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh --pack   # 打发布包
# 验包 → scp → 解压 → docker-01 → docker-02 → 02-onboard → 09-onboard

# ── 就地升级 ────────────────────
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app --fix
bash guard-server/pack.sh --skip-ui
# 停容器 → 换 jar → 启容器 → 验证
```

> **唯一一个「一切正常」的信号**（部署目录已存在时）：
> `bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app`
> 输出 `✓ 部署物料与源码一致`。
> 部署目录不存在时它会提示「跳过本步」并以 0 退出 —— **那是正常的**，
> 直接去装就行。

```bash
# ① 准备部署目录（组装 jar / 数据 / sql）
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh

# ② 建库 + 装系统资源
cd ~/energy-app && bash docker-01-install.sh

# ③ 启动 + 建系统管理员
bash docker-02-start.sh --admin-email you@example.com --admin-pass '你的密码'

# ④ 建租户（一次就够）
bash scripts/02-onboard.sh --admin you@example.com --admin-pass '你的密码' \
  --tenant '某某集团' --tenant-email tenant@example.com --tenant-pass '租户密码'

# ⑤ 一键到「有数据、有账号、能演示」
bash scripts/29-rtu-demo-up.sh
```

完整说明见 [② 系统部署](/admin/deploy)。

### 二、给一个新客户开账号

```bash
bash scripts/09-onboard-customer.sh \
  --email customer@company.com \
  --password 'Cust@123456' \
  --name '某某公司'
```

它建客户、建账号并激活、铺演示数据、装菜单、复制看板，最后逐项验证。
详见 [③ 开户与销户](/admin/onboard)。

### 三、清掉一个客户

```bash
# 先看会删什么（不删）
bash scripts/10-cleanup-customer.sh --name '某某公司' --dry-run

# 确认后执行
bash scripts/10-cleanup-customer.sh --name '某某公司' --yes
```

删客户 + 账号 + 资产 + 设备 + 看板 + 遥测 + 菜单，删完做隔离校验。
详见 [③ 开户与销户](/admin/onboard)。

---

## 数据从哪来：模拟 / 真实，可任选可并存

平台有两种数据源，**写的是不同设备，互不覆盖**，场站总量是两者之和：

| | 谁控制 | 怎么开 | 怎么关 |
| --- | --- | --- | --- |
| **真实 RTU** | 硬件自己 | 上电、连 WiFi 就开始报 | 断电 / 断网 |
| **模拟上报** | 脚本 | `--sim-only` 常驻 | `Ctrl-C` |

```bash
bash scripts/29-rtu-demo-up.sh --status      # 谁在报、谁停了（最常用）
bash scripts/29-rtu-demo-up.sh --sim-only    # 只开模拟（纯演示）
bash scripts/29-rtu-demo-up.sh --no-sim      # 只靠真实表（纯现场）
bash scripts/29-rtu-demo-up.sh               # 两者并存
```

详见 [⑦ 设备接入](/admin/device-access#-两路数据可以并存也可以只开一路)。

---

## 平台长什么样

```
浏览器
  │
  ├─ energy-gateway      反向代理（80 → 平台 8090）
  │
  └─ energy-server       单体后端（Spring Boot + 内嵌前端）
        ├─ 能源业务接口    /api/energy/**
        ├─ 部件运行时      自定义部件（模板 + 控制器脚本）
        └─ 内置前端        Angular 产物打进 jar
              │
              ├─ energy-postgres     实体 + 遥测（ts_kv）
              ├─ energy-spsspro-backend  数据分析（数据探索 / 用能质量）
              └─ energy-waveform-store   波形文件（S3 兼容）
```

五个容器，都是 Docker 管理：

| 容器 | 作用 | 端口 |
| --- | --- | --- |
| `energy-gateway` | 反向代理 / 静态资源 | 80 |
| `energy-server` | 后端 + 前端 | 8090（默认直连） |
| `energy-postgres` | 数据库（实体 + 遥测 `ts_kv`） | 5432 |
| `energy-spsspro-backend` | 数据分析（数据探索 / 用能质量归因） | 内部 |
| `energy-waveform-store` | 波形文件 + 数据集物化（S3 兼容） | `127.0.0.1:19333`（不对外） |

> **波形存储为什么是 SeaweedFS 不是 MinIO**：MinIO 官方镜像 2025-10 起已从
> Docker Hub 下架、quay.io 也拒绝匿名拉取（2026-11-07 实测三种源全部失败）。
> SeaweedFS 提供**同一套 S3 API**，Java 侧走标准 SigV4，
> 将来 MinIO 镜像恢复只换 `image`，代码不动。
> 数据在 `~/energy-app/seaweedfs-data`，随部署目录备份。

> **遥测存储**：固定 `DATABASE_TS_TYPE=sql`，遥测与实体同库（`ts_kv` 分区表）。
> **Cassandra 是预留能力、当前不启用** —— 峰谷分析、抄表、账单、电能质量都直查
> `ts_kv`，切过去会成片 500。等系统稳定、数据量上千万行后再评估，
> 见 [① 安装 · Cassandra](/admin/install#cassandra)。

---

## 账号体系

平台有三级权限，**建数据前先搞清楚这段落在哪一级**：

| 级别 | 谁能建 | 典型内容 |
| --- | --- | --- |
| **系统级** | 系统管理员 | 租户、系统部件、平台参数 |
| **租户级** | 租户管理员 | 客户、能源参数字典、设备档案、费率模板、分时方案、租户菜单、看板模板 |
| **客户级** | 租户管理员 / 客户自己 | 组织、场站、设备、看板副本、客户菜单 |

判据很简单：**这份数据是「所有客户共用」还是「属于某个客户」**。
字典、档案、费率是共用的（租户级）；场站、设备是某家的（客户级）。

详细的三层属性与字典结构见 [④ 数据模型](/admin/data-model)。

---

## 装完先自检

任何一步做完，先打开 **平台自检**（左侧菜单）跑一遍：

```
管理台 → 平台自检 → 一键体检
```

它检查：字典齐不齐、设备属性自洽不、资产汇总有没有、菜单和看板在不在。
**比看日志快**，而且会把「缺什么、去哪补」直接打出来。

自检项与判据见 [⑧ 运维 SQL](/admin/ops-sql#一键体检)。

---

## 手册怎么维护

这份手册是**跟着代码一起改**的，不是事后补的。规则写在 `AGENTS.md` 的 E33：

| 你改了什么 | 必须同步改的手册页 |
| --- | --- |
| 新增 / 改名 / 删除脚本 | 本页「三条最短路径」+ 对应功能页 |
| 改脚本参数或默认值 | 同上 |
| 改数据模型（属性键、字典 key） | [④ 数据模型](/admin/data-model) + [⑧ 运维 SQL](/admin/ops-sql) |
| 改部署链路 | [② 系统部署](/admin/deploy) |
| 改看板 / 部件的行为口径 | 对应功能页 + [客户使用手册](/user/index) |
| 修了客户能感知的 bug | [⑨ 排障](/admin/troubleshoot) |

改完必须跑：

```bash
cd shiyongshouce
./check-docs.py            # 14 项数字与代码一致性
./sync.sh && ./sync.sh --check   # 双目录同步
```

`check-docs.py` 会拦住三类错误：手册数字与代码不一致、引用了不存在的脚本、
手册里的 SQL 跑不通。**全绿才算改完**。
