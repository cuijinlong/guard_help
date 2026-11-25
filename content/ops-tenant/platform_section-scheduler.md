<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 运营配置 / 调度器

> 菜单位置：运维管理 / 租户 / 运营配置 / 调度器

> 页面路径：`/features/scheduler`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `scheduler` |
| 路径 | `/features/scheduler` |
| 数据表 | `scheduler_event`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 调度事件（报表/通知的计划任务）

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT name AS 任务, type AS 类型, enabled AS 启用, schedule AS 计划
FROM scheduler_event
WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) ORDER BY enabled DESC, name;
SQL
```

**本机实测结果**（前 1 行）：

| 任务 | 类型 | 启用 | 计划 |
| --- | --- | --- | --- |
| 正泰单相电表·每日抄表 | meterReading | t | {"startTime":1793318400000,"timezone":"Asia/Shanghai","repeat":{"type" |

**判据**：「到点没跑」先看 `enabled`，再看服务日志里有没有该任务的执行记录。
