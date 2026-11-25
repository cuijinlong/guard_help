<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 客户 / 全部

> 菜单位置：运维管理 / 租户 / 客户与用户 / 客户 / 全部

> 页面路径：`/customers/all`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `customer_all` |
| 路径 | `/customers/all` |
| 数据表 | `asset`、`customer`、`device`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 客户清单

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT c.title AS 客户, count(d.id) AS 设备数,
       (SELECT count(*) FROM asset a WHERE a.customer_id = c.id) AS 资产数,
       to_timestamp(c.created_time / 1000) AS 创建时间
FROM customer c
LEFT JOIN device d ON d.customer_id = c.id
WHERE c.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1)
GROUP BY c.id, c.title, c.created_time ORDER BY c.created_time;
SQL
```

**本机实测结果**（前 1 行）：

| 客户 | 设备数 | 资产数 | 创建时间 |
| --- | --- | --- | --- |
| 平台演示中心 | 55 | 79 | 2026-10-28 18:51:11+08 |

**判据**：设备数/资产数为 0 的客户是新开的还没导数据。
