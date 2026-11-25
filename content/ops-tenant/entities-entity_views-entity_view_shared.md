<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 实体视图 / 共享

> 菜单位置：运维管理 / 租户 / 实体 / 实体视图 / 共享

> 页面路径：`/entities/entityViews/shared`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `entity_view_shared` |
| 路径 | `/entities/entityViews/shared` |
| 数据表 | `customer`、`entity_view`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 分配给客户的实体视图

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT coalesce(c.title, '（未分配）') AS 客户, count(*) AS 视图数
FROM entity_view ev
LEFT JOIN customer c ON c.id = ev.customer_id
WHERE ev.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) GROUP BY 1 ORDER BY 2 DESC;
SQL
```

**本机实测结果：0 行**（客户、视图数）

**判据**：客户看不到某视图 → 它的 `customer_id` 为空。

> ⚠ 0 行的：1. 分配给客户的实体视图 —— 先确认是不是「本来就没启用/没数据」。
