# 运维总览

> 平台方视角：这套系统由哪些部分组成、上线按什么顺序、日常盯什么。

## 一、上线就一条路：5 步

不需要选方案，先照着[部署：照着做](/admin/deploy)走一遍。

| # | 在哪执行 | 命令 | 产出 |
| --- | --- | --- | --- |
| 1 | 仓库根目录 | `bash shiyongshouce/downloads/deploy/docker-00-prepare.sh` | `~/energy-app/` + `.env` |
| 2 | `~/energy-app` | `bash docker-01-install.sh` | 112 张表、726 个部件 |
| 3 | `~/energy-app` | `bash docker-02-start.sh --admin-email ... --admin-pass ...` | 服务启动、管理员可登录 |
| 4 | `~/energy-app` | `bash scripts/02-onboard.sh ...` | 租户 + 客户 + 演示数据 |
| 5 | `~/energy-app` | `bash scripts/03-verify.sh ...` | `通过 22 / 失败 0` |

第 3 步之后就能用浏览器访问 `http://localhost:8090/`。

## 二、什么时候看别的页

| 情况 | 看哪 |
| --- | --- |
| 要部署到另一台服务器 | [部署到服务器](/admin/deploy-remote) |
| 想全部进程跑在一个容器里 | [单容器 or 分容器](/admin/deploy-modes) |
| 不能装 Docker | [裸机部署](/admin/baremetal) |
| 部署过程中报错 | [故障排查](/admin/troubleshoot) |
| 要删掉重来 | [卸载与重置](/admin/uninstall) |

## 三、组件清单

| 组件 | 容器名 | 作用 | 对外端口 |
| --- | --- | --- | --- |
| Nginx 网关 | `energy-gateway` | 统一入口，路由 `/`、`/ngxai/`、`/ngxapi/` | 8090 |
| Java 主服务 | `energy-server` | REST API、规则引擎、WebSocket、前端静态资源 | 仅内网 |
| ngx-ai 后端 | `energy-ngxai-backend` | 负载预测、措施建议 | 仅内网 |
| PostgreSQL 16 | `energy-postgres` | 实体、遥测、关系、审计数据 | 仅内网 |

浏览器只接触网关一个端口。

## 四、三层初始化，各自负责什么

理解「为什么新租户不是空壳」的关键：

| 层级 | 触发时机 | 创建内容 |
| --- | --- | --- |
| 系统级 | 第 2 步 install | 112 张表、726 个系统部件、34 个 bundle、默认菜单模板 |
| 租户级 | 第 4 步建租户 | 能源参数字典（4 品种 + 指标参数）、4 个计量器具档案、默认规则链、6 个默认仪表板 |
| 客户级 | 第 4 步建客户 | 4 个维度根、一套 `demo=true` 的演示数据（场站/类目/3 台表计/7 天遥测/拓扑） |

三层失败策略不同：系统级失败会让 install 中止；租户级和客户级失败只记日志、不回滚主实体。所以**第 5 步的验收必须跑**，不能只看「创建成功」。

## 五、日常巡检

**在哪执行：【`~/energy-app`】**

```bash
cd ~/energy-app

docker compose ps
docker compose logs --tail=200 gateway | grep -E "ERROR|Caused by"
curl -s --noproxy '*' http://127.0.0.1:8090/api/noauth/setup/state
```

每周：

- 备份是否成功、文件大小是否正常增长
- 磁盘余量（遥测表增长最快）
- 租户数、客户数、设备数是否符合预期

## 六、出问题先看三处

1. **网关日志**：`docker compose logs --tail=200 gateway`
2. **应用日志**：`docker compose logs --tail=200 energy-server`
3. **接口返回码**：401 是 token 问题，403 是权限/用户组问题，423 是初始化未完成，500 才去看日志

具体现象与修法见[故障排查](/admin/troubleshoot)。

## 七、两条必须记住的约束

- **jar 是 Java 25 编译的**，运行镜像必须是 `eclipse-temurin:25-jre`，换 21 会 `UnsupportedClassVersionError`。
- **必须显式指定数据目录**（compose 里已写死 `/opt/energy/data`）。让它自己猜可能选中不含 `json/` 的目录，租户仪表板会静默变成 0 个。
