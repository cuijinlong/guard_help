# 方案 A：本机 Docker 部署

> 全程在当前这台电脑上完成。**不需要 scp、不需要服务器 IP、不需要 ssh。**

**适用**：Docker 已装好的电脑，想立刻看到系统跑起来。

> 本文默认 **分容器（split）** 模式。想用单容器，把 `.env` 里的 `DEPLOY_MODE` 改成 `allinone` 即可，其余步骤完全一样。两种模式的区别见[单容器 or 分容器](/admin/deploy-modes)。

## 第 0 步：准备部署目录

**在哪执行：【你的电脑 · 仓库根目录】**

先确认位置 —— 这个目录下应该能看到 `guard-server` 和 `shiyongshouce`：

```bash
cd /path/to/iot-rule-engine     # 换成你的仓库实际路径
ls                              # 应看到 guard-server、dao、shiyongshouce 等
```

然后执行：

```bash
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh
```

它会把 jar、json 资源、8 个 SQL、compose 和全部脚本放到 `~/energy-app`，并自动生成 `.env`。

**你会看到**：

```
[16:56:00] 检查源文件
  ✓ jar：425M
  ✓ json： 28M
  ✓ sql：8 个文件
[16:56:00] 组装部署目录：/Users/你/energy-app
  ✓ 已生成 .env（APP_HOME 已填好，端口检测后取 8090/5433，密码随机生成）

  ✓ 部署目录已就绪：/Users/你/energy-app
   数据库密码（已写入 .env）：7f948db0959105589ba8d115
   ⚠ 请把这行密码记到你的密码管理器，卸载重装时需要。

   下一步（复制这一条就行）：
      cd /Users/你/energy-app && bash docker-01-install.sh
```

**做两件事**：

1. 把打印出来的数据库密码存进密码管理器；
2. 复制最后那行命令，下一步直接用。

> 提示「找不到 jar」说明还没构建：先 `cd guard-server && mvn package -DskipTests`，再回到仓库根目录重跑第 0 步。

> 小提示：后面几个脚本内部都会自己切到所在目录，**即使你在别处执行也不会出错**。文档仍写明 cd 步骤，是为了让 `pwd` 随时可核对。

## 第 1 步：建库并初始化

**在哪执行：【你的电脑 · ~/energy-app】**

```bash
cd ~/energy-app
bash docker-01-install.sh
```

**预计输出**（首次拉镜像会多 1 分钟）：

```
[16:01:03] 检查环境
  ✓ docker / compose / 文件 / 端口 检查通过
[16:01:05] 启动 PostgreSQL（首次会拉取镜像，约 1 分钟）
  ✓ 数据库健康（6s）
[16:01:13] 执行 install（建表 + 装载系统资源，约 1-3 分钟）
  ✓ install 完成：112 张表 / 726 个部件 / 34 个 bundle / 0 个用户

  ✓ 第 1 步完成
```

**这一步之后**：数据库有表、有系统部件，但**没有任何用户**，服务还没启动。正常。

## 第 2 步：启动服务并创建管理员

**在哪执行：【你的电脑 · ~/energy-app】**

```bash
cd ~/energy-app
bash docker-02-start.sh \
  --admin-email admin@example.com \
  --admin-pass 'ChangeMe123!'
```

邮箱密码换成你想要的（密码至少 8 位）。

**预计输出**：

```
[16:03:53] 启动服务
  ✓ 服务已就绪（100s）：{"status":"ACCOUNT_REQUIRED"}
[16:05:40] 创建系统管理员 admin@example.com
  ✓ 管理员已创建
  ✓ 系统管理员可登录，权限 SYS_ADMIN

  ✓ 第 2 步完成
```

**访问**：浏览器打开 `http://localhost:8090/`（若第 0 步提示不是 8090，用那个数字），用刚才的邮箱密码登录。

## 第 3 步：开租户与开客户

**在哪执行：【你的电脑 · ~/energy-app】**

```bash
cd ~/energy-app
bash scripts/02-onboard.sh \
  --base http://127.0.0.1:8090 \
  --admin admin@example.com --admin-pass 'ChangeMe123!' \
  --tenant "环宇能源集团" \
  --tenant-email tenant@example.com --tenant-pass 'Tenant@12345' \
  --customer "星河工业园" \
  --customer-email customer@example.com --customer-pass 'Customer@123'
```

**预计输出**：

```
  ✓ 租户已创建
  ✓ 租户管理员已创建（待激活）
  ✓ 租户管理员已激活并取得会话
  ✓ 客户已创建
  ✓ 客户管理员已创建并激活（可用该邮箱登录）
  ✓ 能源参数字典：1 个
  ✓ 四个维度根齐全
  ✓ 系统部件：726 个
  ✓ 能耗管理部件：32 个
  ✓ 全部验证通过
```

幂等，重复执行只提示「已存在」。

## 第 4 步：验收

**在哪执行：【你的电脑 · ~/energy-app】**

```bash
cd ~/energy-app
bash scripts/03-verify.sh \
  --base http://127.0.0.1:8090 \
  --tenant tenant@example.com --tenant-pass 'Tenant@12345' \
  --customer customer@example.com --customer-pass 'Customer@123'
```

**预计输出**：

```
  通过 17 / 失败 0
```

看到这一行才算完成。

## 日常运维

**在哪执行：【你的电脑 · ~/energy-app】**

```bash
cd ~/energy-app

docker compose ps                          # 状态
docker compose logs -f --tail=100 server   # 跟踪日志
docker compose restart server              # 重启应用
docker compose stop                        # 全部停止（数据保留）
docker compose up -d                       # 再启动

# 备份
docker compose exec -T postgres pg_dump -U postgres thingsboard \
  | gzip > ~/thingsboard-$(date +%F).sql.gz
```

## 常见失败

- **`port is already allocated`** → 改 `~/energy-app/.env` 里的 `HTTP_PORT`，重跑当前步骤
- **`Mounts denied`（macOS）** → 只在目录指到 `/opt` 时出现；默认 `~/energy-app` 不会
- **`UnsupportedClassVersionError 69.0`** → 镜像必须是 `eclipse-temurin:25-jre`，别改成 21
- **install 退出码非 0** → 看 `/tmp/energy-install.log` 末尾
- **服务 240 秒未就绪** → `docker compose logs --tail=80 server | grep -E "ERROR|Caused by"`

更多见[故障排查](/admin/troubleshoot)。卸载见[卸载与重置](/admin/uninstall)。
