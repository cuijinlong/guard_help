# 运维总览

> 平台方视角：这套系统由哪些部分组成、上线要按什么顺序做、日常盯什么。

## 一、上线路径（按顺序照做）

| 步骤 | 命令 / 动作 | 看哪一页 |
| --- | --- | --- |
| 1 | 解压发布包，配 `.env` | [部署（Docker）](/admin/deploy) 第 0–1 步 |
| 2 | `bash docker-01-install.sh` | 同上，第 2 步 |
| 3 | `bash docker-02-start.sh --admin-email ... --admin-pass ...` | 同上，第 3 步 |
| 4 | `bash ../scripts/02-onboard.sh ...` 开租户与客户 | [开租户与开客户](/admin/tenant) |
| 5 | `bash ../scripts/03-verify.sh ...` 验收 | [部署](/admin/deploy) 第 5 步 |
| 6 | 改 JWT 密钥、站点地址、邮件配置 | [安全加固](/admin/security) |
| 7 | 配备份与监控 | [数据备份](/admin/data)、[监控](/admin/monitoring) |
| 8 | 出问题时 | [故障排查](/admin/troubleshoot) |
| 9 | 不用了要删除 | [卸载与重置](/admin/uninstall) |

## 二、组件清单

| 组件 | 容器名 | 作用 | 默认端口 |
| --- | --- | --- | --- |
| guard-server | `energy-server` | REST API、规则引擎、WebSocket、前端静态资源 | 8090 |
| PostgreSQL 16 | `energy-postgres` | 实体、遥测、关系、审计数据 | 仅 127.0.0.1:5432 |
| ngx-ai 后端 | 独立部署 | 负载预测、措施建议 | 18801 |
| ngx-ai 前端 | 独立部署 | 分析工作台 | 18800 |

最小可用部署只需要前两个；ngx-ai 不启动时，分析页会提示服务不可用，不影响主业务。

## 三、三层初始化，各自负责什么

这是理解「为什么新租户不是空壳」的关键：

| 层级 | 触发时机 | 创建内容 |
| --- | --- | --- |
| 系统级 | install | 112 张表、726 个系统部件、34 个 bundle、默认菜单模板 |
| 租户级 | 建租户 | 能源参数字典（4 品种 + 指标参数）、4 个计量器具档案、默认规则链、6 个默认仪表板 |
| 客户级 | 建客户 | 4 个维度根、一套 `demo=true` 的演示数据（场站/类目/3 台表计/7 天遥测/拓扑） |

三层的失败策略不同：系统级失败会让 install 中止；租户级和客户级失败只记日志、不回滚主实体。所以**开通后一定要验证**，不能只看「创建成功」。

## 四、日常巡检

每天：

```bash
cd /opt/energy-app
docker compose ps
docker compose logs --tail=200 server | grep -E "ERROR|Caused by"
curl -s --noproxy '*' http://127.0.0.1:8090/api/noauth/setup/state
```

每周：

- 备份是否成功、文件大小是否正常增长
- 磁盘余量（遥测表增长最快）
- 租户数、客户数、设备数是否符合预期

## 五、出问题先看三处

1. **容器日志**：`docker compose logs --tail=200 server`，多数问题第一行就写清楚了；
2. **数据库**：`docker compose exec postgres psql -U postgres -c 'select 1'`；
3. **接口返回码**：401 是 token 问题，403 是权限/用户组问题，423 是初始化未完成，500 才去看日志。

具体现象与修法见[故障排查](/admin/troubleshoot)。

## 六、两条必须记住的约束

- **jar 是 Java 25 编译的**，运行镜像必须是 `eclipse-temurin:25-jre`，换 21 会 `UnsupportedClassVersionError`。
- **必须显式指定数据目录**（Docker 版已在 compose 里写死 `/opt/energy/data`）。让它自己猜可能选中不含 `json/` 的目录，租户仪表板会静默变成 0 个。
