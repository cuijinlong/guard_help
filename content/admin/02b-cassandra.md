# ②b Cassandra（默认遥测存储）

> **默认后端就是 Cassandra。** 遥测写 `ts_kv_cf`，实体元数据与最新值仍在 Postgres。
>
> 只有 2GB 内存的小机器、或纯演示环境，才建议改成 Postgres —— 见下方「切回 Postgres」。

---

## 一、先决定：要不要用

| 场景 | 建议 |
| --- | --- |
| 正式部署 / 设备会持续增长 | **Cassandra（默认）** |
| 上亿点、持续高 QPS 写入 | Cassandra（唯一可行） |
| 多节点横向扩写入 | Cassandra |
| 只有 2GB 内存的机器 / 纯功能演示 | 改 Postgres，省一个容器、省 2G 内存 |

**核心区别**：只有「遥测」能换后端，实体元数据恒在 Postgres。

```
DATABASE_ENTITIES_TYPE=sql              ← 实体元数据，不可改
DATABASE_TS_TYPE=cassandra | sql        ← 遥测（默认 cassandra，本页讲的）
DATABASE_TS_LATEST_TYPE=sql | cassandra ← 最新值（建议留 sql）
```

**为什么最新值建议留 sql**：设备详情页、看板的实时数字读的是它，
查询频繁、数据量小，放 Postgres 更快，也少一次跨库往返。

**默认值写在两处，改一处就行**：

| 位置 | 作用 |
| --- | --- |
| `docker-compose.yml` 的 `${DATABASE_TS_TYPE:-cassandra}` | 兜底默认值 |
| `.env` 的 `DATABASE_TS_TYPE=cassandra` | 实际生效值（prepare 生成） |

`docker-01-install.sh` / `docker-02-start.sh` 会读 `.env`：
值是 `cassandra` 时自动带 `--profile cassandra` 拉起容器；改成 `sql` 时**不会启动**
Cassandra，所以不会白占内存。手工跑 `docker compose up` 时记得自己带这个 profile。

---

## 二、安装与启用（一条命令）

**全新部署默认就启用，你什么都不用做。** 装完 `docker-01-install.sh` 之后：

```
① up -d postgres          → 等 healthy
② up -d cassandra         → 等 healthy（首次 2~5 分钟）
③ install                 → 建 Postgres schema + Cassandra keyspace/两张表
④ up -d energy-server …   → 服务连上 9042
```

`docker-01-install.sh` 会读 `.env` 的 `DATABASE_TS_TYPE`：是 `cassandra` 就自动
带 `--profile cassandra`、并**等 Cassandra healthy 才跑 install** —— 顺序不能反，
反了会报 `InvalidKeyspaceException: Invalid keyspace thingsboard`（见第三节）。

Cassandra 用独立 profile，不在 `split` 里 —— 这样改成 `sql` 时它根本不会启动，
不会白吃 2G 内存。**用脚本，别手工一步步来**：

```bash
cd ~/energy-app

bash scripts/11-cassandra.sh status      # 看现状（容器 / keyspace / 表 / 当前后端）
bash scripts/11-cassandra.sh enable      # 启用或修复（起容器+建 schema+改配置+重启）
bash scripts/11-cassandra.sh disable     # 切回 Postgres（先自动清理验收镜像）
bash scripts/11-cassandra.sh uninstall   # 删容器+删数据卷（不可恢复）
bash scripts/11-cassandra.sh shell       # 进 cqlsh 交互
```

> ⚠ 启动耗时：Cassandra 模式比 Postgres 模式**慢得多**。
> 实测冷启动到 `energy-server` 返回 200 约 **7 分钟**（Postgres 约 2 分钟）。
> 原因是实体缓存预热 + 驱动连接池 + 分区索引都要从远端拉。
> `docker-02-start.sh` 已按后端自动放宽等待（Cassandra 600 秒 / sql 240 秒）。

`enable` 的实测输出：

```
  ! Postgres 里已有 131257 个遥测点 —— **不会迁移到 Cassandra**
  ✓ Cassandra 容器已在运行
  ✓ Cassandra 已就绪（10s）
  用 TB 原生 install 流程建 Cassandra schema（执行 data/cassandra/*.cql）
  ✓ 已执行 schema-keyspace.cql
  ✓ 已执行 schema-ts.cql
  ✓ keyspace thingsboard 与 2 张表已就绪（TB 原生 CQL）
  ! install 整体退出码 1（非空库上会报 tenant_profile/admin_settings 重复键）
    Cassandra schema 已建成，这个报错可以忽略。
  ✓ DATABASE_TS_TYPE=cassandra
  ✓ 服务已切到 Cassandra 并健康
```

首次启动容器约 2~5 分钟（Mac 上更慢），`starting` 阶段 cqlsh 连不上是正常的。

---

## 三、⚠ 为什么不能只改 `.env` 就重启

**这是最容易踩的坑。** 实测 2026-10-22：

把 `DATABASE_TS_TYPE` 改成 `cassandra` 直接重启，服务起不来：

```
Caused by: com.datastax.oss.driver.api.core.InvalidKeyspaceException: Invalid keyspace thingsboard
```

**原因**：建 keyspace 与 `ts_kv_cf` 的那两个服务
（`CassandraKeyspaceService` / `CassandraTsDatabaseSchemaService`）
都标了 `@Profile("install")` —— **只在 install 建库阶段跑**。
`energy-server` 启动阶段不建、也不自动补，keyspace 不存在就直接报错退出。

**正确做法：用 TB 原生的 install 流程建。**

```bash
docker compose --profile split --profile install --profile cassandra run --rm install
```

它会执行部署目录 `data/cassandra/` 下的三份 CQL，与 TB 官方完全一致：

```
schema-keyspace.cql     建 keyspace（SimpleStrategy / RF=1）
schema-ts.cql           建 ts_kv_cf + ts_kv_partitions_cf
schema-ts-latest.cql    建 ts_kv_latest_cf（仅当 DATABASE_TS_LATEST_TYPE=cassandra）
```

> **为什么不自己写 CQL**：TB 升级时这几份 CQL 会跟着更新（分区策略、压缩策略、
> 新增列）。自己抄一份，升级后就对不上。原文件在
> `dao/src/main/resources/cassandra/`。

### ⚠ install 在非空库上会报错，但 Cassandra 部分已经建完了

```
ERROR: duplicate key value violates unique constraint "tenant_profile_name_unq_key"
ERROR  AdminSettings object is invalid: [Admin settings with such name already exists!]
```

**这是正常现象**：install 走「首次安装」分支，重建系统默认数据时撞到已有记录。
它发生在 Cassandra 建表**之后**，不影响 Cassandra。

**所以判断成败看 keyspace 与两张表是否存在，不看 install 退出码。**
`11-cassandra.sh` 就是这么判断的。

### 前置条件：`data/cassandra/` 必须存在

早先 `docker-00-prepare.sh` 只拷 `data/json` 与 `data/sql`，漏了 `data/cassandra`，
导致 install 直接崩：

```
java.nio.file.NoSuchFileException: /opt/energy/data/cassandra/schema-keyspace.cql
```

**已修（2026-10-22）**。如果你的部署目录没有这个子目录：

```bash
cd <仓库根> && bash shiyongshouce/downloads/deploy/docker-00-prepare.sh --force
# 或手工补
cp dao/src/main/resources/cassandra/*.cql ~/energy-app/data/cassandra/
```

---

## 四、验证真的在工作

```bash
# 表在不在
docker compose exec cassandra cqlsh -e \
  "SELECT table_name FROM system_schema.tables WHERE keyspace_name='thingsboard';"
# 期望：ts_kv_cf / ts_kv_partitions_cf

# 数据量
docker compose exec cassandra cqlsh -e "SELECT count(*) FROM thingsboard.ts_kv_cf;"
```

**端到端**：触发一次设备上报，再查一次点数，应当增长。
实测（2026-10-22）：上报 `energy=9.99` → Cassandra 写入 26 点 →
通过 `/api/plugins/telemetry/DEVICE/<id>/values/timeseries?keys=energy` 读回 `9.99`。

---

## 四之二、验收脚本怎么查 Cassandra 数据（`ts-mirror.sh`）

**这是切到 Cassandra 之后最容易误判的一件事。**

验收脚本（`03/04/06/08`）里写了大量直查 SQL：

```sql
SELECT d.name, k.key, t.ts, t.dbl_v
  FROM ts_kv t
  JOIN key_dictionary k ON k.key_id = t.key
  JOIN device d ON d.id = t.entity_id
```

这些 SQL 是按「遥测存 Postgres」写的。切到 Cassandra 之后，**Postgres 里没有
`ts_kv` 表**，于是验收会出现一片假失败：

| 现象 | 真实原因 |
| --- | --- |
| `单相电表 ≥ 1 台 — 0 台`（设备明明有 21 台） | 04 的 `devs` 从遥测列表派生，列表为空 |
| `资产上没有 energy_total` | 汇总点在 Cassandra，SQL 查 PG 查不到 |
| `峰谷分析无法核对（设备无整点表底）` | `energy_reading` 在 Cassandra |
| `idle_exceed 时序点：实际 0` | 同上 |

产品没坏，是**验收工具看错了库**。

### 解决办法：镜像一份到 Postgres

```bash
bash scripts/ts-mirror.sh          # 导出 + 导入 + 建 ts_kv 视图（约 40 秒 / 14 万行）
bash scripts/ts-mirror.sh --force  # 强制重新导出
bash scripts/ts-mirror.sh --clean  # 删镜像（切回 sql 之前必须跑）
```

它做三件事：

```
① cqlsh COPY thingsboard.ts_kv_cf TO '/tmp/ts_kv_cf.csv'
② 导入 PG 的 ts_kv_mirror，并把 key 名映射回 key_dictionary.key_id
③ 建视图 ts_kv（key 列就是 key_id，与原 SQL 完全兼容）
```

> **`json_v` 为什么是 text 而不是 jsonb**
>
> Cassandra 的 `COPY TO` 用 `\"` 转义双引号，PostgreSQL 的 `COPY FROM CSV`
> 只认 `""` —— 两套转义不同。含引号的 JSON（规则链调试输出
> `{"ruleNodeId":"..."}`）会被读成字面 `\"`，jsonb 直接拒收；而 COPY 是原子的，
> **一行失败整批 0 行**，镜像静默变成空表，后面所有数据类验收全部失效。
>
> 镜像表只用于「按 TB 原生结构写验收 SQL」，`json_v` 不需要 jsonb 操作符，存 text 足够。
> 实测 2026-10-24：14 万行里有 1 行这种数据，整批导入失败。

`04/06/08` 开头会自动调用它，**验收 SQL 一行都不用改**。
后端是 `sql` 时它什么也不做（PG 本来就有真表）。

> ⚠ 镜像只读、只用于验收与排查。TB 本身只读写 Cassandra，不碰这两张镜像表。
> 切回 `sql` 前必须 `ts-mirror.sh --clean`，否则 install 建真表 `ts_kv` 会撞名
> （`11-cassandra.sh disable` 已自动清理）。

### 为什么不能用 `count(*)` 查 Cassandra

```bash
docker exec energy-cassandra cqlsh -e "SELECT count(*) FROM thingsboard.ts_kv_cf;"
# ReadFailure: Operation failed - received 0 responses and 1 failures
```

全表 `count(*)` 在 Cassandra 上要扫所有分区，默认 10 秒读超时。**不是数据坏了**。
要看行数用 `nodetool tablestats`，或按分区查、或走 `ts-mirror.sh`。

---

## 五、表结构：为什么 GUI 不好用

`ts_kv_cf` 的主键：

```
PRIMARY KEY (( entity_type, entity_id, key, partition ), ts)
                └──────────── 分区键 ────────────┘
```

`partition` **不是**时间戳，而是**月初的毫秒值**
（`TS_KV_PARTITIONING` 默认 `MONTHS`）。

少任何一个分区键字段，查询就是全表扫 —— 会超时，甚至把节点打满。
所以真实运维靠 **cqlsh + 预写好的 CQL**，不是 GUI 点开表看。

### 分区值怎么算

```bash
PART=$(python3 -c "
import datetime
n=datetime.datetime.now(datetime.timezone.utc)
s=n.replace(day=1,hour=0,minute=0,second=0,microsecond=0)
print(int(s.timestamp()*1000))")
echo $PART        # 例：1790812800000
```

### 常用查询

```bash
# 某设备某指标本月的数据
docker compose exec cassandra cqlsh -e "
SELECT ts, dbl_v, long_v, bool_v, str_v
FROM thingsboard.ts_kv_cf
WHERE entity_type='DEVICE'
  AND entity_id=<设备uuid>
  AND key='energy'
  AND partition=$PART
ORDER BY ts DESC
LIMIT 20;"

# 某设备写了哪些指标、各在哪些分区（不知道 partition 时靠它反查）
docker compose exec cassandra cqlsh -e "
SELECT key, partition, count(*) AS n
FROM thingsboard.ts_kv_partitions_cf
WHERE entity_type='DEVICE' AND entity_id=<设备uuid>
GROUP BY key, partition;"
```

> `ts_kv_partitions_cf` 是索引表，记录每个 (实体, 指标) 有哪些分区。
> 这是 TB 的设计，用来避免全表扫。

---

## 六、可视化客户端

**先说结论：这个场景 GUI 价值有限**，原因见上一节。

| 工具 | 类型 | 评价 |
| --- | --- | --- |
| **cqlsh** | CLI（容器自带） | **主力**。零安装、版本匹配、最可靠 |
| **DBeaver Community** | 桌面 GUI，免费 | 能连，可看表结构。对 Cassandra 支持比关系库弱很多 |
| **IntelliJ IDEA Ultimate** | 桌面 GUI，付费 | Database 窗口支持，体验略好。Community 版没有 |
| **Cassandra Reaper** | Web UI | **运维该用这个**：repair 调度、compaction 监控、快照管理 |

**不能用的（省得白折腾）**

- **Navicat** —— 不支持 Cassandra
- **DataStax Studio** —— 已停止维护（EOL）
- **TablePlus / Beekeeper Studio** —— 不支持

**安全：9042 不要开到公网**

compose 里 `cassandra` **没有**映射 9042（只有 `energy-server` 需要连）。
要用桌面 GUI 就走 SSH 隧道，或直接在服务器上用 cqlsh。

---

## 七、集群运维（nodetool）

容器内自带，不用额外装。

```bash
docker compose exec cassandra nodetool status          # UN = Up/Normal 才健康
docker compose exec cassandra nodetool info            # 负载、token
docker compose exec cassandra nodetool tablestats thingsboard.ts_kv_cf
docker compose exec cassandra nodetool compactionstats # 写入变慢先看这个
docker compose exec cassandra nodetool tpstats         # Pending 持续增长 = 写不动
docker compose exec cassandra nodetool snapshot -t bkp-$(date +%F) thingsboard
```

| 指标 | 健康 | 异常含义 |
| --- | --- | --- |
| `status` 全部 `UN` | ✓ | `DN` 节点挂了；`UJ` 正在加入 |
| `tpstats` 的 `Pending` | 接近 0 | 持续增长 → 写入过载 |
| `tablestats` 每分区平均行数 | 平稳 | 超大分区（上报太密） |
| `compactionstats` pending | 0~个位数 | 长期堆积 → 磁盘 IO 跟不上 |

---

## 八、备份与恢复

```bash
# 快照
docker compose exec cassandra nodetool snapshot -t bkp-$(date +%F) thingsboard

# 导出（快照在容器内 data 目录下，直接打包整个 keyspace）
docker compose exec cassandra sh -c \
  'tar czf - -C /var/lib/cassandra/data thingsboard' > cassandra-$(date +%F).tar.gz

# 只备份结构
docker compose exec cassandra cqlsh -e "DESCRIBE KEYSPACE thingsboard;" \
  > cassandra-schema-$(date +%F).cql

# 快照会占空间，确认备份完清掉
docker compose exec cassandra nodetool listsnapshots
docker compose exec cassandra nodetool clearsnapshot -t bkp-2026-10-22
```

恢复要停服务 → 清数据目录 → 解包 → `nodetool refresh` → 起服务。
**生产上请先跑通恢复演练**再依赖它。

---

## 九、卸载

```bash
bash scripts/11-cassandra.sh uninstall          # 会要求输入 yes
```

脚本会删容器与 `energy-cassandra-data` 卷。**当前正在用 Cassandra 时脚本会拒绝**
（必须先 `disable`），这是防误删。

**平台级卸载/重装会自动带上 Cassandra**：

```bash
bash docker-99-uninstall.sh --purge --yes
```

它会检测 `energy-cassandra-data` 卷或 `energy-cassandra` 容器是否存在，
存在就把 `--profile cassandra` 加进 compose 参数，一并停掉并删卷。
`--dry-run` 会列出来：

```
· 数据卷 energy-cassandra-data（检测到用过 Cassandra）
```

`docker-98-rebuild.sh` 委托给 `99`，所以重装同样自动覆盖。
**注意：重装后遥测后端回到默认 Postgres**，要再用 Cassandra 得重跑
`bash scripts/11-cassandra.sh enable`（数据卷已被删，是全新的）。

---

## 十、常见故障

### A. 启动报 `InvalidKeyspaceException: Invalid keyspace thingsboard`

keyspace 没建。见第三节 —— 跑 `bash scripts/11-cassandra.sh init`
（它内部用 TB 原生 install 建）。

### B. 容器一直 `starting` / `unhealthy`

```bash
docker compose logs --tail=100 cassandra | grep -iE "error|exception|killed"
```

常见原因：内存不足（`MAX_HEAP_SIZE` 默认 2G，宿主至少留 4G）、
上次非正常退出导致数据文件损坏（找 `CorruptSSTableException`）、磁盘满。

### C. 写入变慢 / 查询超时

```bash
docker compose exec cassandra nodetool tpstats
docker compose exec cassandra nodetool compactionstats
```

最可能是超大分区：某台设备某指标上报太密。本平台演示数据按整点上报，
改成秒级就会撞。

### D. 单节点副本数

`schema-keyspace.cql` 默认 `SimpleStrategy` + `replication_factor: 1`。

**单节点没问题**。但**多节点生产必须改**成 `NetworkTopologyStrategy` 且 RF ≥ 3，
否则节点一挂就丢数据：

```bash
docker compose exec cassandra cqlsh -e "
ALTER KEYSPACE thingsboard WITH replication = {
  'class': 'NetworkTopologyStrategy', 'datacenter1': 3};"
```

### E. 切换后历史数据查不到

**这是预期行为，不是故障。** 改 `DATABASE_TS_TYPE` 不迁移存量数据。
Postgres 里原有的 `ts_kv` 留在原地（数据没删，仍可用 SQL 查），
只是新后端看不到它们。

要让历史也可见，只能自己迁移（TB 自带的 `migrator` 在本项目未验证过）。
**建议：接受「历史留在 Postgres」**，需要时用 SQL 导出报表。

---

## 十一、参数速查

`.env` 里的相关项：

```bash
DATABASE_TS_TYPE=sql              # sql（默认）| cassandra
DATABASE_TS_LATEST_TYPE=sql       # 建议留 sql
CASSANDRA_URL=cassandra:9042      # 容器内用服务名
CASSANDRA_CLUSTER_NAME=Thingsboard Cluster
CASSANDRA_KEYSPACE_NAME=thingsboard
CASSANDRA_LOCAL_DATACENTER=datacenter1
CASSANDRA_HEAP=2G                 # 堆大小，太小会 GC 抖动
CASSANDRA_NEWGEN=512M             # 新生代
CASSANDRA_REPLICATION_FACTOR=1    # 多节点改成 3
```

其它可调项在 `thingsboard.yml` 的 `cassandra:` 段（用环境变量覆盖）：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `TS_KV_PARTITIONING` | `MONTHS` | 分区粒度（MINUTES/HOURS/DAYS/MONTHS/INDEFINITE） |
| `TS_KV_TTL` | `0` | 遥测保留秒数，0 = 永不过期 |
| `CASSANDRA_QUERY_BUFFER_SIZE` | `200000` | 查询缓冲上限 |
| `CASSANDRA_DEFAULT_FETCH_SIZE` | `2000` | 每次取多少行 |
