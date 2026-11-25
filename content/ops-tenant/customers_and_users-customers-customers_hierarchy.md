<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 客户 / 层级

> 菜单位置：运维管理 / 租户 / 客户与用户 / 客户 / 层级

> 页面路径：`/customers/hierarchy`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `customers_hierarchy` |
| 路径 | `/customers/hierarchy` |
| 数据表 | `customer`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 客户层级（父子关系）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT coalesce(p.title, '（顶级）') AS 上级,
       c.title AS 客户, count(*) OVER () AS 客户总数
FROM customer c
LEFT JOIN customer p ON p.id = c.parent_customer_id
WHERE c.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团')
ORDER BY 1, 2;
SQL
```

**本机实测结果**（前 1 行）：

| 上级 | 客户 | 客户总数 |
| --- | --- | --- |
| （顶级） | 平台演示中心 | 1 |

**判据**：层级影响数据可见范围（上级能看到下级）。要扁平就都留空。
