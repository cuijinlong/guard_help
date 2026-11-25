<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 客户 / 分组

> 菜单位置：运维管理 / 租户 / 客户与用户 / 客户 / 分组

> 页面路径：`/customers/groups`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `customer_groups` |
| 路径 | `/customers/groups` |
| 数据表 | `customer_info_view`、`entity_group` |

## 核对 SQL（可直接复制运行）

### 1. 客户分组

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT g.name AS 分组,
       count(x.title) AS 成员数
FROM entity_group g
LEFT JOIN customer_info_view x ON x.groups::jsonb @> to_jsonb(g.id::text)
WHERE g.type = 'CUSTOMER'
GROUP BY g.id, g.name ORDER BY 2 DESC;
SQL
```

**本机实测结果**（前 2 行）：

| 分组 | 成员数 |
| --- | --- |
| All | 0 |
| All | 0 |

**判据**：0 行 = 客户没分组；分组只影响列表筛选，不影响权限。
