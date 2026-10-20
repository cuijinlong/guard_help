# 方案 C：裸机部署（不用 Docker）

> 服务器不能装 Docker，或需要直接控制 JVM 参数时用这套。流程与 Docker 版一致：**install → 启动 → setup**。

**适用**：已有 PostgreSQL、需要与既有系统共存、或要接 JVM 监控的场景。

## 前提

**在哪执行：【服务器 · 任意目录】**

- JDK **25**（jar 编译目标就是 25，用 21 会 `UnsupportedClassVersionError`）
- PostgreSQL 14+，或已有可连的数据库
- 发布包里的 `guard-server-4.4.0.jar` 和 `data/`（含 `json/` 与 `sql/`）

```bash
java -version      # 必须显示 25
psql --version     # 或能连到已有 PostgreSQL
```

## 第 0 步：准备目录

**在哪执行：【服务器 · 任意目录】**

```bash
mkdir -p /opt/energy/{data/sql,data/json,logs}
```

把发布包里的内容放进去：

- `guard-server-4.4.0.jar` → `/opt/energy/`
- `data/json/` 整个目录 → `/opt/energy/data/json/`
- 8 个 SQL → `/opt/energy/data/sql/`

**验证**：

```bash
cd /opt/energy
ls guard-server-4.4.0.jar
ls data/sql/schema-entities.sql
ls -d data/json/system/widget_types
ls data/sql/*.sql | wc -l      # 应该是 8
```

三条都成功、最后输出 `8`，才能继续。

## 第 1 步：建库 + install

**在哪执行：【服务器 · 发布包 scripts 目录】**

数据库在 Docker 里时：

```bash
cd /opt/energy-deploy/scripts      # 或发布包里 scripts 所在目录
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

本机有 psql、数据库不走容器时，把 `--db-container tb-postgres` 换成：

```bash
--db-host 127.0.0.1 --db-port 5432 --db-user postgres --db-pass '你的密码'
```

**预计输出**：

```
✓ 已创建数据库 thingsboard
✓ install 完成：112 张表 / 726 个部件 / 34 个 bundle
```

## 第 2 步：启动服务

**在哪执行：【服务器 · 任意目录】**

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

日志里应有 `Started ThingsBoard in 55 seconds`：

```bash
grep "Started ThingsBoard" /opt/energy/logs/console.log
```

> `-Dinstall.data_dir` 不能省。程序按启动目录猜数据目录时，可能选中不含 `json/` 的目录，导致新租户仪表板静默变成 0 个。

## 第 3 步：创建管理员

**在哪执行：【服务器 · 发布包 scripts 目录】**

```bash
cd /opt/energy-deploy/scripts
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

浏览器打开 `http://服务器IP:8090/` 即可登录。

## 第 4 步：开租户与验收

**在哪执行：【服务器 · 发布包 scripts 目录】**

```bash
cd /opt/energy-deploy/scripts

bash 02-onboard.sh --base http://127.0.0.1:8090 \
  --admin admin@example.com --admin-pass 'ChangeMe123!' \
  --tenant "环宇能源集团" \
  --tenant-email tenant@example.com --tenant-pass 'Tenant@12345' \
  --customer "星河工业园" \
  --customer-email customer@example.com --customer-pass 'Customer@123'

bash 03-verify.sh --base http://127.0.0.1:8090 \
  --tenant tenant@example.com --tenant-pass 'Tenant@12345' \
  --customer customer@example.com --customer-pass 'Customer@123'
```

期望结尾 `通过 17 / 失败 0`。

## 第 5 步：做成系统服务（可选）

上面的 `nohup` 方式重启机器就没了，长期运行建议用 systemd。

**在哪执行：【服务器 · 任意目录】**

```bash
cat > /etc/systemd/system/energy.service <<'EOF'
[Unit]
Description=Energy Management Server
After=network.target postgresql.service

[Service]
Type=simple
WorkingDirectory=/opt/energy
ExecStart=/usr/bin/java -Dinstall.data_dir=/opt/energy/data \
  -Xms512m -Xmx2g -jar /opt/energy/guard-server-4.4.0.jar \
  --spring.config.name=thingsboard --spring.profiles.active=dev --server.port=8090
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now energy
systemctl status energy
```

日志：

```bash
journalctl -u energy -f
```

## 第 6 步：跑第二个实例

同机跑第二个实例必须同时改这些，否则端口和 RocksDB 会撞：

| 配置 | 默认值 | 改法 |
| --- | --- | --- |
| HTTP | 8090 | `--server.port=8091` |
| 集成 RPC | 9090 | `INTEGRATIONS_RPC_PORT=9190` |
| 边缘 RPC | 7070 | `EDGES_RPC_PORT=7170` |
| 队列 RocksDB | `~/.rocksdb/cf_states` | `TB_QUEUE_CF_ROCKS_DB_PATH=/var/tmp/cf2` |
| EDQS RocksDB | `~/.rocksdb/edqs` | `TB_EDQS_ROCKSDB_PATH=/var/tmp/edqs2` |
| CoAP | 5683 | `COAP_ENABLED=false` |

## 卸载

**在哪执行：【服务器 · 任意目录】**

```bash
# 1. 停服务
systemctl stop energy && systemctl disable energy   # 用 systemd 时
pkill -f 'guard-server-4.4.0.jar'                   # 用 nohup 时

# 2. 删程序与数据
rm -rf /opt/energy
rm -f /etc/systemd/system/energy.service
systemctl daemon-reload

# 3. 删库
psql -h 127.0.0.1 -U postgres -c 'DROP DATABASE thingsboard;'

# 4. 清 RocksDB 状态
rm -rf ~/.rocksdb/cf_states ~/.rocksdb/edqs
```

**确认干净**：

```bash
lsof -nP -iTCP:8090 -sTCP:LISTEN     # 应无输出
ls /opt/energy                        # 应提示不存在
```

Docker 部署的卸载见[卸载与重置](/admin/uninstall)。
