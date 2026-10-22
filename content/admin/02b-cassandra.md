# ②b Cassandra（可选遥测存储）

> **默认部署不用它。** 遥测默认存 Postgres 的 `ts_kv`（按月分区），
> 几十万到几百万点完全够用。只有遥测上亿、写入压力大、要横向扩写入端时才需要。

---

## 一、先决定：要不要用

| 场景 | 建议 |
| --- | --- |
| 演示环境 / 中小客户（几十万~几百万点） | **用 Postgres**（默认） |
| 上亿点、持续高 QPS 写入 | 用 Cassandra |
| 多节点横向扩写入 | 用 Cassandra |
| 只有 2GB 内存的机器 | **别用**，Cassandra 自己要 2G 堆 |

**核心区别**：只有「遥测」能换后端，实体元数据恒在 Postgres。

```
DATABASE_ENTITIES_TYPE=sql              ← 实体元数据，不可改
DATABASE_TS_TYPE=sql | cassandra        ← 遥测（本页讲的）
DATABASE_TS_LATEST_TYPE=sql | cassandra ← 最新值（建议留 sql）
```

**为什么最新值建议留 sql**：设备详情页、看板的实时数字读的是它，
查询频繁、数据量小，放 Postgres 更快，也少一次跨库往返。

---

## 二、安装与启用（一条命令）

Cassandra 用独立 profile，不带就不启动。**用脚本，别手工一步步来**：

```bash
cd ~/energy-app

bash scripts/11-cassandra.sh status      # 看现状
bash scripts/11-cassandra.sh enable      # 一键启用（起容器+建 schema+改配置+重启+等健康）
bash scripts/11-cassandra.sh disable     # 切回 Postgres（Cassandra 数据保留）
bash scripts/11-cassandra.sh uninstall   # 删容器+删数据卷（不可恢复）
bash scripts/11-cassandra.sh shell       # 进 cqlsh 交互
```

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
