# 运维总览

> 平台方视角：系统由哪些部分组成、上线按什么顺序、日常盯什么。每条命令都标明**在哪台机器、cd 到哪个目录**。

## 一、先选部署方案

| 你的情况 | 走哪条 |
| --- | --- |
| 就在当前电脑试用 | [A · 本机 Docker](/admin/deploy-local) |
| 代码在本机，要跑到另一台服务器 | [B · 上传到服务器](/admin/deploy-remote) |
| 不能装 Docker | [C · 裸机部署](/admin/baremetal) |

完整对比见[部署：选场景](/admin/deploy)。

## 二、上线路径（以本机 Docker 为例）

| 步骤 | 在哪执行 · 目录 | 命令 | 详解 |
| --- | --- | --- | --- |
| 1 | 仓库根目录 | `bash shiyongshouce/downloads/deploy/docker-00-prepare.sh` | [A 第 0 步](/admin/deploy-local) |
| 2 | `~/energy-app` | `bash docker-01-install.sh` | [A 第 1 步](/admin/deploy-local) |
| 3 | `~/energy-app` | `bash docker-02-start.sh --admin-email ... --admin-pass ...` | [A 第 2 步](/admin/deploy-local) |
| 4 | `~/energy-app` | `bash scripts/02-onboard.sh ...` | [开租户与开客户](/admin/tenant) |
| 5 | `~/energy-app` | `bash scripts/03-verify.sh ...` | [A 第 4 步](/admin/deploy-local) |
| 6 | `~/energy-app` | 改 JWT 密钥、baseUrl、SMTP | [安全加固](/admin/security) |
| 7 | `~/energy-app` | 配备份与监控 | [数据备份](/admin/data)、[监控](/admin/monitoring) |
| 8 | — | 出问题时 | [故障排查](/admin/troubleshoot) |
| 9 | `~/energy-app` | 删除环境 | [卸载与重置](/admin/uninstall) |

> 部署到服务器时，第 1 步换成 `--pack` 打包 + scp 上传，之后在第 2 步的服务器目录里执行同样的命令。

## 三、组件清单

| 组件 | 容器名 | 作用 | 默认端口 |
| --- | --- | --- | --- |
| guard-server | `energy-server` | REST API、规则引擎、WebSocket、前端静态资源 | 8090 |
| PostgreSQL 16 | `energy-postgres` | 实体、遥测、关系、审计数据 | 仅 127.0.0.1:5432 |
| ngx-ai 后端 | 独立部署 | 负载预测、措施建议 | 18801 |
| ngx-ai 前端 | 独立部署 | 分析工作台 | 18800 |

最小可用部署只需要前两个；ngx-ai 不启动时，分析页提示服务不可用，不影响主业务。

## 四、三层初始化，各自负责什么

理解「为什么新租户不是空壳」的关键：

| 层级 | 触发时机 | 创建内容 |
| --- | --- | --- |
| 系统级 | install | 112 张表、726 个系统部件、34 个 bundle、默认菜单模板 |
| 租户级 | 建租户 | 能源参数字典（4 品种 + 指标参数）、4 个计量器具档案、默认规则链、6 个默认仪表板 |
| 客户级 | 建客户 | 4 个维度根、一套 `demo=true` 的演示数据（场站/类目/3 台表计/7 天遥测/拓扑） |

三层失败策略不同：系统级失败会让 install 中止；租户级和客户级失败只记日志、不回滚主实体。所以**开通后必须跑验收脚本**，不能只看「创建成功」。

## 五、日常巡检

**在哪执行：【部署机 · 部署目录】**

```bash
cd ~/energy-app        # 服务器部署则是 /opt/energy-app 或 /opt/energy-deploy

docker compose ps
docker compose logs --tail=200 server | grep -E "ERROR|Caused by"
curl -s --noproxy '*' http://127.0.0.1:8090/api/noauth/setup/state
```

每周：

- 备份是否成功、文件大小是否正常增长
- 磁盘余量（遥测表增长最快）
- 租户数、客户数、设备数是否符合预期

## 六、出问题先看三处

1. **容器日志**：`docker compose logs --tail=200 server`
2. **数据库**：`docker compose exec postgres psql -U postgres -c 'select 1'`
3. **接口返回码**：401 是 token 问题，403 是权限/用户组问题，423 是初始化未完成，500 才去看日志

具体现象与修法见[故障排查](/admin/troubleshoot)。

## 七、两条必须记住的约束

- **jar 是 Java 25 编译的**，运行镜像必须是 `eclipse-temurin:25-jre`，换 21 会 `UnsupportedClassVersionError`。
- **必须显式指定数据目录**（Docker 版已在 compose 里写死 `/opt/energy/data`）。让它自己猜可能选中不含 `json/` 的目录，租户仪表板会静默变成 0 个。
