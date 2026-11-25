<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 报告 / 调度

> 菜单位置：运维管理 / 租户 / 监控 / 报告 / 调度

> 页面路径：`/reporting/scheduling`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `report_scheduling` |
| 路径 | `/reporting/scheduling` |
| 数据表 | `scheduler_event`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 报表调度任务

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT name AS 任务, enabled AS 启用, type AS 类型,
       schedule AS 计划, to_timestamp(created_time / 1000) AS 创建时间
FROM scheduler_event
WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团') ORDER BY enabled DESC, name;
SQL
```

**本机实测结果**（前 1 行）：

| 任务 | 启用 | 类型 | 计划 | 创建时间 |
| --- | --- | --- | --- | --- |
| 正泰单相电表·每日抄表 | t | meterReading | {"startTime":1793318400000,"timezone":"Asia/Shanghai","repeat":{"type" | 2026-10-29 17:48:52+08 |

**判据**：调度任务在跑但没产出 → 看 `enabled` 与报表模板是否存在。
