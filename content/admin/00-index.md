# 运维手册

> 六页，按顺序看就行。第一次部署只需要看前三页。
> **②b Cassandra 是可选的** —— 只有遥测上亿、写入压力大才需要，默认不用看。

## 部署上线（第一次做）

| 页 | 内容 | 什么时候看 |
| --- | --- | --- |
| [① Docker](/admin/docker) | 安装、调优、日常清理、卸载 Docker | 机器上还没有 Docker |
| [② 平台部署](/admin/deploy) | 4 条命令装完平台；卸载也在这页 | 部署平台、升级、重装 |
| [②b Cassandra](/admin/cassandra) | **可选遥测存储**：何时该用、一键启用/切回/卸载、cqlsh 查询、nodetool 运维、备份恢复、可视化客户端 | 遥测上亿或写入压力大 |
| [③ 数据初始化](/admin/init) | 用户、字典、档案、规则、菜单、演示数据；自检、清理、验和补 | 装完要确认数据齐不齐 |

## 接入现场（客户要连设备）

| 页 | 内容 |
| --- | --- |
| [④ 设备接入](/admin/device-access) | RTU/网关怎么上报；HTTP 与 MQTT；字段格式；三条铁律 |

## 出问题时

| 页 | 内容 |
| --- | --- |
| [⑤ 常见问题](/admin/troubleshoot) | 登录失败、报表空白、上报不通、磁盘满、密码重置；**系统架构图（容器 / 数据模型 / 自建表 / 费率 / 闲时链路）**；**运维 SQL 22 组** |

---

## 三条最短路径

### 全新部署（约 15 分钟）

```bash
# 1. 装 Docker（已装可跳过）
#    见 ① Docker 第一节

# 2. 部署平台
cd /你的路径/iot-rule-engine
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh
cd ~/energy-app
bash docker-01-install.sh
bash docker-02-start.sh --admin-email langmen@126.com --admin-pass 'CJLqh@163' \
  --public-url 'http://<你的IP>:8090'

# 3. 初始化数据（用户 / 字典 / 档案 / 规则 / 菜单 / 演示数据一次到位）
bash scripts/02-onboard.sh \
  --base http://127.0.0.1:8090 \
  --admin langmen@126.com --admin-pass 'CJLqh@163' \
  --tenant "环宇能源集团" \
  --tenant-email tenant@126.com --tenant-pass '12345678' \
  --customer "星河工业园" \
  --customer-email customer@126.com --customer-pass '12345678'
```

### 改了代码要更新（约 6 分钟）

```bash
cd /你的路径/iot-rule-engine
bash shiyongshouce/downloads/deploy/docker-98-rebuild.sh \
  --admin langmen@126.com --admin-pass 'CJLqh@163' \
  --tenant tenant@126.com --tenant-pass '12345678' --tenant-title '环宇能源集团' \
  --customer customer@126.com --customer-pass '12345678' --customer-title '星河工业园' \
  --yes
```

### 重装后先跑验收（最重要的一步）

```bash
cd ~/energy-app
bash scripts/08-verify-release.sh \
  --tenant tenant@126.com --tenant-pass '12345678' \
  --customer customer@126.com --customer-pass '12345678'
```

期望 `通过 72 项`。失败项会直接给出修法，多数可以点「平台自检 → 一键修复初始化」解决。

详见[③ 数据初始化](/admin/init)的「第 0 条」。

### 彻底卸载（删数据卷）

先看会删什么，再删：

```bash
cd ~/energy-app
bash docker-99-uninstall.sh --purge --dry-run    # 只列清单
bash docker-99-uninstall.sh --purge --yes        # 真删（含数据卷）
```

详见[② 平台部署](/admin/deploy)的「卸载平台」。

### 卸载后从头再来（一条命令）

上面的 `docker-98-rebuild.sh` **自己会先卸载再装**，不需要手工分两步。
想连数据卷一起清干净、从零验一遍初始化数据，直接跑：

```bash
cd /你的路径/iot-rule-engine
bash shiyongshouce/downloads/deploy/docker-98-rebuild.sh \
  --admin langmen@126.com --admin-pass 'CJLqh@163' \
  --tenant tenant@126.com   --tenant-pass '12345678' --tenant-title '环宇能源集团' \
  --customer customer@126.com --customer-pass '12345678' --customer-title '星河工业园' \
  --yes
```

跑完会打印一行「验收：全部通过」。然后登录 → **平台自检**，
确认初始化项全绿（见[③ 数据初始化](/admin/init)「一之三」）。

卸完 Disk 没释放多少？构建缓存不会被 `down -v` 碰到：

```bash
docker system df
docker builder prune -f
docker image prune -f
```

> 注意两个脚本的参数名不一样，别混：
> `docker-98-rebuild.sh` 的 `--tenant` / `--customer` 是**登录邮箱**，名称用 `--tenant-title` / `--customer-title`；
> `scripts/02-onboard.sh` 的 `--tenant` / `--customer` 是**名称**，邮箱用 `--tenant-email` / `--customer-email`。

**一键开通一个客户**（最简单，带演示数据）：

```bash
cd ~/energy-app
bash scripts/09-onboard-customer.sh --email customer2@company.com --password 'Cust@123456'
```

只给邮箱和密码，客户名自动从邮箱前缀推导。租户凭据自动读取。

**再入驻一个客户**（租户已有，不重装，需要自己控制租户参数）：去掉 `--tenant`，但**必须带 `--tenant-email` / `--tenant-pass`**。
系统管理员不能直接建客户（TB 会 403），脚本会用它切换成租户管理员再继续：

```bash
cd ~/energy-app
bash scripts/02-onboard.sh \
  --base http://127.0.0.1:8090 \
  --admin langmen@126.com --admin-pass 'CJLqh@163' \
  --tenant-email tenant@126.com --tenant-pass '12345678' \
  --customer "第二客户" \
  --customer-email customer2@126.com --customer-pass '12345678'
```

重跑安全：已存在的租户 / 客户 / 账号会跳过并复用，不影响已有客户。
详见[② 部署 → 再入驻一个客户](/admin/deploy)。

**清理一个客户**（不合作了 / 建错了）：

```bash
cd ~/energy-app
bash scripts/10-cleanup-customer.sh --email customer2@company.com --dry-run   # 先看要删什么
bash scripts/10-cleanup-customer.sh --email customer2@company.com             # 确认后执行
```

连带客户名下的资产 / 设备 / 看板 / 账号 / **遥测数据**一并清掉。
删前会拍快照，删后校验**其他客户与租户级数据一字节没动**，不通过就退出码 2 报错。
删了不可恢复，没有客户级回收站。详见[② 部署 → 清理一个客户](/admin/deploy)。

---

## 手册怎么维护（改代码的人看）

手册里的数字（菜单几项、档案几个、指标几条）是**手写**的，代码在持续改。
改了代码忘了改手册，下次照手册部署就会「看不到文档承诺的东西」——
不报错，但验收时对不上，比功能 bug 更难查。

所以有一个自动检查：

```bash
cd shiyongshouce
./check-docs.py          # 代码事实 vs 手册数字，不一致退出码 1
./check-docs.py -v       # 额外打印每项在手册里的原文
```

它检查 13 项：资产档案、设备档案、告警+派生指标、能源品种、电能一级指标、
电能二级 key、分时方案、费率模板、组织页签、看板模板、租户菜单、客户菜单、
发布验收项数。

**同一个数字在手册里出现多处**（初始化清单 / 部署完成状态表 / 章节标题），
脚本要求全部一致 —— 只改一处会被抓出来。

已接入三个环节，不需要你记着跑：

| 环节 | 行为 |
| --- | --- |
| `./sync.sh` | 不一致直接中止同步（**强制**） |
| `docker-00-prepare.sh` | 不一致只警告，继续安装 |
| `docker-98-rebuild.sh` | 不一致只警告，继续重装 |

为什么后两个不强制：重装是奔着修系统去的，不该被文档问题挡住。
但警告会明确告诉你「别照手册的数字验收」。

---

## 账号

装完后有三个账号，权限从高到低：

| 账号 | 密码 | 能做什么 |
| --- | --- | --- |
| `langmen@126.com` | `CJLqh@163` | 系统管理员：建租户、改平台设置 |
| `tenant@126.com` | `12345678` | 租户管理员：能源服务商，管全部客户 |
| `customer@126.com` | `12345678` | 客户用户：只看自己场站的设备与报表 |

> 正式上线前换成自己的邮箱和强密码。改密码后要同步改脚本参数。

---

## 客户怎么用

面向客户的说明在[客户使用手册](/user/index)：怎么登录、怎么看报表、
怎么换成自己的数据。给客户交付时发那个，不用发这一份。
