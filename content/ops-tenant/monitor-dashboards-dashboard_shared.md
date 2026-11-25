<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 仪表板 / 共享

> 菜单位置：运维管理 / 租户 / 监控 / 仪表板 / 共享

> 页面路径：`/dashboards/shared`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `dashboard_shared` |
| 路径 | `/dashboards/shared` |
| 数据表 | `customer`、`dashboard`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 共享给客户的看板

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT d.title AS 看板, coalesce(c.title, '—') AS 客户
FROM dashboard d
LEFT JOIN customer c ON c.id = d.customer_id
WHERE d.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1)
  AND (d.customer_id IS NOT NULL
       OR (d.assigned_customers IS NOT NULL AND d.assigned_customers::text <> '[]'))
ORDER BY 2, 1;
SQL
```

**本机实测结果**（前 8 行）：

| 看板 | 客户 |
| --- | --- |
| 分项能耗 | — |
| 区域能耗 | — |
| 历史能耗 | — |
| 告警事件 | — |
| 基础报表 | — |
| 实时能耗 | — |
| 客户诊断报告 | — |
| 峰谷分析 | — |

**判据**：客户账号看不到某块板 → 先确认这里的共享记录；为空就是没分配。
