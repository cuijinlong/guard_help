<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 安全 / 审计日志

> 菜单位置：运维管理 / 租户 / 安全 / 审计日志

> 页面路径：`/security-settings/auditLogs`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `audit_log` |
| 路径 | `/security-settings/auditLogs` |
| 数据表 | `audit_log`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 审计日志（按动作统计）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT action_type AS 动作, action_status AS 状态, count(*) AS 条数,
       max(to_timestamp(created_time / 1000)) AS 最近
FROM audit_log
WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团')
GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 20;
SQL
```

**本机实测结果**（前 8 行）：

| 动作 | 状态 | 条数 | 最近 |
| --- | --- | --- | --- |
| LOGIN | SUCCESS | 7762 | 2026-11-25 17:44:45+08 |
| TIMESERIES_UPDATED | SUCCESS | 3971 | 2026-11-25 00:53:41+08 |
| RELATION_ADD_OR_UPDATE | SUCCESS | 2050 | 2026-11-25 02:03:07+08 |
| ATTRIBUTES_UPDATED | SUCCESS | 1002 | 2026-11-25 10:49:15+08 |
| UPDATED | SUCCESS | 774 | 2026-11-25 10:47:34+08 |
| ADDED | SUCCESS | 380 | 2026-11-25 00:51:39+08 |
| DELETED | SUCCESS | 311 | 2026-11-24 02:42:12+08 |
| RELATION_DELETED | SUCCESS | 188 | 2026-11-25 02:03:07+08 |

**判据**：「谁改了配置」全靠这张表。登录审计要确认 `action_type` 里有 LOGIN 类。
