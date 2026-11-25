<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 实体视图 / 全部

> 菜单位置：运维管理 / 租户 / 实体 / 实体视图 / 全部

> 页面路径：`/entities/entityViews/all`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `entity_view_all` |
| 路径 | `/entities/entityViews/all` |
| 数据表 | `customer`、`entity_view`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 实体视图

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT ev.name AS 视图, ev.type AS 类型, ev.entity_type AS 实体类型,
       coalesce(c.title, '—') AS 客户
FROM entity_view ev
LEFT JOIN customer c ON c.id = ev.customer_id
WHERE ev.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) ORDER BY ev.name;
SQL
```

**本机实测结果：0 行**（视图、类型、实体类型、客户）

**判据**：0 行 = 还没建实体视图（它是「把设备的一部分遥测暴露给客户」的手段）。

> ⚠ 0 行的：1. 实体视图 —— 先确认是不是「本来就没启用/没数据」。
