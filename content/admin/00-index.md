# 运维总览

> 平台方视角：这套系统由哪些部分组成、上线要按什么顺序做、日常盯什么。

## 一、上线路径（按顺序）

| 步骤 | 做什么 | 看哪一页 |
| --- | --- | --- |
| 1 | 建库、跑 install、启动服务、建系统管理员 | [部署](/admin/deploy) |
| 2 | 开第一个租户，交付租户管理员账号 | [开租户与开客户](/admin/tenant) |
| 3 | 租户管理员建客户，交付客户账号 | [开租户与开客户](/admin/tenant) |
| 4 | 跑验收脚本，确认 17 项全通过 | [部署](/admin/deploy) 最后一节 |
| 5 | 改 JWT 密钥、站点地址、邮件配置 | [安全加固](/admin/security) |
| 6 | 配备份、监控 | [数据备份](/admin/data)、[监控](/admin/monitoring) |

## 二、组件清单

| 组件 | 作用 | 默认端口 |
| --- | --- | --- |
| guard-server | 主服务：REST API、规则引擎、WebSocket、前端静态资源 | 8090 |
| PostgreSQL | 实体、遥测、关系、审计数据 | 5432 |
| ngx-ai 后端 | 负载预测、措施建议 | 18801 |
| ngx-ai 前端 | 分析工作台 | 18800 |
| MQTT 传输（可选） | 设备接入 | 1883 |

最小可用部署只需要 guard-server + PostgreSQL；ngx-ai 不启动时，分析页会提示服务不可用，不影响主业务。

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
# 服务活着、状态正常
curl -s --noproxy '*' http://127.0.0.1:8090/api/noauth/setup/state

# 最近错误
tail -200 /opt/energy/logs/guard-server.log | grep -E "ERROR|Caused by" | tail -20

# 数据库连接数
docker exec tb-postgres psql -U postgres -d thingsboard -tAc \
  "select count(*) from pg_stat_activity;"
```

每周：

- 备份是否成功、文件大小是否正常增长
- 磁盘余量（遥测表增长最快）
- 租户数、客户数、设备数是否符合预期

## 五、出问题先看三处

1. **服务日志**：`ERROR` 和 `Caused by`，多数问题第一行就写清楚了；
2. **数据库连接**：`docker exec tb-postgres psql -U postgres -c 'select 1'`；
3. **接口返回码**：401 是 token 问题，403 是权限/用户组问题，423 是初始化未完成，500 才去看日志。

具体现象与修法见[故障排查](/admin/troubleshoot)。
