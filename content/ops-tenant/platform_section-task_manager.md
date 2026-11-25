<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 运营配置 / 任务管理器

> 菜单位置：运维管理 / 租户 / 运营配置 / 任务管理器

> 页面路径：`/features/taskManager`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `task_manager` |
| 路径 | `/features/taskManager` |
| 数据表 | `job` |

## 核对 SQL（可直接复制运行）

### 1. 后台任务

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT count(*) AS 任务数,
       count(*) FILTER (WHERE status = 'RUNNING') AS 执行中
FROM job;
SQL
```

**本机实测结果**（前 1 行）：

| 任务数 | 执行中 |
| --- | --- |
| 0 | 0 |

**判据**：0 行 = 没有后台任务记录（多数操作是同步的）。
