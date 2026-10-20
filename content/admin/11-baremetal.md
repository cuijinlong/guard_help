# 裸机部署（不用 Docker）

> 不能装 Docker，或需要直接控制 JVM 参数时用这套。流程与 Docker 版完全一致：**install → 启动 → setup**。

## 一、准备

- JDK 25（jar 编译目标就是 25，21 会报 `UnsupportedClassVersionError`）
- PostgreSQL 14+，或已有可连的数据库
- 发布包：`guard-server-4.4.0.jar` + `data/`（含 `json/` 与 `sql/`）

```bash
mkdir -p /opt/energy/{data,logs}
# data/sql 放 8 个 schema SQL，data/json 从发布包拷贝
ls /opt/energy/data/sql/schema-entities.sql
ls -d /opt/energy/data/json/system/widget_types
```

## 二、建库 + install

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

数据库在 Docker 里时用 `--db-container`；本机有 psql 时改用：

```bash
--db-host 127.0.0.1 --db-port 5432 --db-user postgres --db-pass '...'
```

**预计输出**：

```
✓ 已创建数据库 thingsboard
✓ install 完成：112 张表 / 726 个部件 / 34 个 bundle
```

## 三、启动服务

```bash
nohup java -Dinstall.data_dir=/opt/energy/data \
  -Xms512m -Xmx2g \
  -jar /opt/energy/guard-server-4.4.0.jar \
  --spring.config.name=thingsboard \
  --spring.profiles.active=dev \
  --server.port=8090 \
  > /opt/energy/logs/console.log 2>&1 &
```

**验证就绪**：

```bash
for i in $(seq 1 40); do
  sleep 5
  curl -s --noproxy '*' -m 4 http://127.0.0.1:8090/api/noauth/setup/state && break
done
```

期望：

```json
{"status":"ACCOUNT_REQUIRED"}
```

日志里应有 `Started ThingsBoard in 55 seconds`。

> `-Dinstall.data_dir` 不能省。程序按启动目录猜数据目录时，可能选中不含 `json/` 的目录，导致新租户仪表板静默变成 0 个。

## 四、创建管理员

服务起来后，重跑同一脚本只做 setup：

```bash
bash 01-install.sh \
  --db-container tb-postgres --db-name thingsboard \
  --data-dir /opt/energy/data \
  --jar /opt/energy/guard-server-4.4.0.jar \
  --admin-email admin@example.com --admin-pass 'ChangeMe123!' \
  --http-port 8090 --skip-install
```

**预计输出**：

```
✓ 系统管理员可登录
✓ 初始化完成
```

## 五、开租户与验收

与 Docker 版完全相同：

```bash
bash 02-onboard.sh --base http://127.0.0.1:8090 \
  --admin admin@example.com --admin-pass 'ChangeMe123!' \
  --tenant "某某集团" --tenant-email tenant@example.com --tenant-pass '...' \
  --customer "某某厂区" --customer-email customer@example.com --customer-pass '...'

bash 03-verify.sh --base http://127.0.0.1:8090 \
  --tenant tenant@example.com --tenant-pass '...' \
  --customer customer@example.com --customer-pass '...'
```

期望结尾 `通过 17 / 失败 0`。

## 六、跑第二个实例

同机跑第二个实例必须同时改这些，否则端口和 RocksDB 会撞：

| 配置 | 默认值 | 改法 |
| --- | --- | --- |
| HTTP | 8090 | `--server.port=8091` |
| 集成 RPC | 9090 | `INTEGRATIONS_RPC_PORT=9190` |
| 边缘 RPC | 7070 | `EDGES_RPC_PORT=7170` |
| 队列 RocksDB | `~/.rocksdb/cf_states` | `TB_QUEUE_CF_ROCKS_DB_PATH=/var/tmp/cf2` |
| EDQS RocksDB | `~/.rocksdb/edqs` | `TB_EDQS_ROCKSDB_PATH=/var/tmp/edqs2` |
| CoAP | 5683 | `COAP_ENABLED=false` |

## 七、卸载

```bash
# 停服务
pkill -f 'guard-server-4.4.0.jar'

# 删程序与数据（数据库另算）
rm -rf /opt/energy

# 删库
psql -h 127.0.0.1 -U postgres -c 'DROP DATABASE thingsboard;'

# 清 RocksDB
rm -rf ~/.rocksdb/cf_states ~/.rocksdb/edqs
```

确认没有监听：

```bash
lsof -nP -iTCP:8090 -sTCP:LISTEN
```

Docker 部署的卸载见[卸载与重置](/admin/uninstall)。
