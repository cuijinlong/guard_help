<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 报告 / 报告

> 菜单位置：运维管理 / 租户 / 监控 / 报告 / 报告

> 页面路径：`/reporting/reports`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `reports` |
| 路径 | `/reporting/reports` |
| 数据表 | `report`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 已生成的报表

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT name AS 报表, format AS 格式,
       to_timestamp(created_time / 1000) AS 生成时间
FROM report
WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团') ORDER BY created_time DESC LIMIT 20;
SQL
```

**本机实测结果：0 行**（报表、格式、生成时间）

**判据**：0 行 = 还没生成过报表（需要先有模板与调度）。

> ⚠ 0 行的：1. 已生成的报表 —— 先确认是不是「本来就没启用/没数据」。
