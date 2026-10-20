# 部署

> 从一台空机器到「能登录、能开租户」。本文每一步都给出验证命令和期望输出，照着做不会卡在半路。

## 一、先记住三条铁律

1. **顺序不能变：install → 启动服务 → setup 建管理员。**
   `install` 只建表结构和系统资源，**不创建任何用户**；系统管理员只能由 `POST /api/noauth/setup/complete` 创建，而这个接口只在库里没有 `SYS_ADMIN` 时接受请求 —— 这是防止匿名调用者接管已开通实例的保护。

2. **必须显式指定 `install.data_dir`。**
   不指定时程序会按启动目录猜数据目录。仓库里同时存在 `application/src/main/data`（不完整）和 `guard-server/src/main/data`（完整），猜错会让「租户默认仪表板」静默变成 0 个，不报错、不回滚。

3. **`curl` 一律加 `--noproxy '*'`。**
   本机开了代理时，`127.0.0.1` 也会被代理接管，表现为 `HTTP 000`。脚本里不要写成变量 `CURL="curl --noproxy *"`，`*` 会被 shell 展开成当前目录的文件名。

## 二、准备环境

- JDK 21 或更高（已验证 JDK 25 可运行）
- PostgreSQL 14+（本文以 Docker 容器 `tb-postgres` 为例）
- 发布包 `guard-server-4.4.0.jar`
- 数据目录 `/opt/energy/data`，结构必须是：

```
/opt/energy/data/
├── sql/     ← 8 个 schema SQL，见下方下载
└── json/    ← 随发布包提供：system/（部件、bundle）、tenant/（仪表板、规则链）、demo/
```

**下载 SQL**（逐个保存到 `/opt/energy/data/sql/`）：

- [schema-entities.sql](/downloads/sql/schema-entities.sql)
- [schema-entities-idx.sql](/downloads/sql/schema-entities-idx.sql)
- [schema-entities-idx-psql-addon.sql](/downloads/sql/schema-entities-idx-psql-addon.sql)
- [schema-functions.sql](/downloads/sql/schema-functions.sql)
- [schema-views.sql](/downloads/sql/schema-views.sql)
- [schema-ts-psql.sql](/downloads/sql/schema-ts-psql.sql)
- [schema-ts-latest-psql.sql](/downloads/sql/schema-ts-latest-psql.sql)
- [schema-timescale.sql](/downloads/sql/schema-timescale.sql)（不用 TimescaleDB 可不放）

**下载脚本**：

- [01-install.sh](/downloads/scripts/01-install.sh)
- [02-onboard.sh](/downloads/scripts/02-onboard.sh)
- [03-verify.sh](/downloads/scripts/03-verify.sh)

## 三、第一步：建库 + install

```bash
bash 01-install.sh \
  --db-container tb-postgres \
  --db-name thingsboard \
  --data-dir /opt/energy/data \
  --jar /opt/energy/guard-server-4.4.0.jar \
  --admin-email admin@example.com \
  --admin-pass 'ChangeMe123!' \
  --http-port 8090 \
  --skip-setup
```

说明：

- `--db-container` 表示在 Docker 容器里执行 `psql`。本机装了 psql 时改用 `--db-host 127.0.0.1 --db-port 5432 --db-user postgres --db-pass postgres`，去掉 `--db-container`。
- `--skip-setup` 是因为此刻服务还没启动，先只做 install。
- 这个脚本会拒绝在非空库上重复 install，避免误伤已有数据。

**期望输出**：

```
✓ 已创建数据库 thingsboard
✓ install 完成：112 张表 / 726 个部件 / 34 个 bundle
```

**自己再验一遍**：

```bash
docker exec tb-postgres psql -U postgres -d thingsboard -tAc \
  "select (select count(*) from widget_type),
          (select count(*) from widgets_bundle),
          (select count(*) from tenant);"
```

期望 `726|34|0` —— 最后一项必须是 0，说明还没建任何租户。

## 四、第二步：启动服务

```bash
java -Dinstall.data_dir=/opt/energy/data \
     -Xms512m -Xmx2g \
     -jar /opt/energy/guard-server-4.4.0.jar \
     --spring.config.name=thingsboard \
     --spring.profiles.active=prod \
     --server.port=8090
```

日志出现下面这行即启动完成（首次约 55–75 秒）：

```
Started ThingsBoard in 55 seconds
```

**验证**：

```bash
curl -s --noproxy '*' http://127.0.0.1:8090/api/noauth/setup/state
```

期望：

```json
{"status":"ACCOUNT_REQUIRED"}
```

如果返回 `423` 且带 `setupState`，说明这个版本的 setup 接口被安全过滤器挡了（见[故障排查](/admin/troubleshoot)第一条）。

## 五、第三步：创建系统管理员

服务已在 8090 监听后，重跑同一个脚本，只做 setup：

```bash
bash 01-install.sh \
  --db-container tb-postgres \
  --db-name thingsboard \
  --data-dir /opt/energy/data \
  --jar /opt/energy/guard-server-4.4.0.jar \
  --admin-email admin@example.com \
  --admin-pass 'ChangeMe123!' \
  --http-port 8090 \
  --skip-install
```

**期望输出**：

```
✓ 系统管理员可登录
✓ 初始化完成
```

**验证登录**：

```bash
curl -s --noproxy '*' -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin@example.com","password":"ChangeMe123!"}'
```

返回里应含 `"token":"..."`，且 `/api/auth/user` 的 `authority` 为 `SYS_ADMIN`。

再查一次状态，应变成：

```json
{"status":"READY"}
```

## 六、上线前必改的三项

| 项 | 位置 | 说明 |
| --- | --- | --- |
| JWT 签名密钥 | `thingsboard.yml` → `security.jwt.tokenSigningKey` | 默认值必须换掉，否则任何人可伪造 token |
| 站点地址 | 系统管理员 → 常规设置 → `baseUrl` | 影响激活邮件链接和前端跳转 |
| 邮件服务器 | `spring.mail.*` | 不发激活邮件时可以后置，但客户自助注册会用到 |

## 七、验收：一条命令跑完 17 项

```bash
bash 03-verify.sh \
  --base http://127.0.0.1:8090 \
  --tenant tenant@example.com --tenant-pass 'Tenant@12345' \
  --customer customer@example.com --customer-pass 'Customer@123'
```

期望结尾：

```
通过 17 / 失败 0
```

覆盖：首页、setup 状态、租户侧资产/设备/仪表板/部件/字典/报告版本、客户侧登录与自有数据、两处越权 403。

## 八、本次部署实测记录（2026-10-20）

在全新库 `thingsboard_verify` 上完整跑通：

| 步骤 | 结果 |
| --- | --- |
| install | 112 张表 / 726 个部件 / 34 个 bundle |
| 启动 | 60 秒，`ACCOUNT_REQUIRED` |
| setup | HTTP 200，状态转 `READY`，`SYS_ADMIN` 登录成功 |
| 开租户 | 能源参数字典 1 个、4 个品种 |
| 开客户 | 4 个维度根 + 3 台演示设备 + 1 张拓扑 |
| 租户内容 | 资产 12 个、设备 3 台、仪表板 6 个、能耗部件 32 个 |
| 验收脚本 | 17 通过 / 0 失败 |

后续步骤见[开租户与开客户](/admin/tenant)。
