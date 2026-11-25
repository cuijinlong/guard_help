<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 客户 / 共享

> 菜单位置：运维管理 / 租户 / 客户与用户 / 客户 / 共享

> 页面路径：`/customers/shared`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `customer_shared` |
| 路径 | `/customers/shared` |
| 数据表 | `customer`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 公开（is_public）客户

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT title AS 客户, is_public AS 是否公开
FROM customer WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) ORDER BY is_public DESC, title;
SQL
```

**本机实测结果**（前 1 行）：

| 客户 | 是否公开 |
| --- | --- |
| 平台演示中心 | f |

**判据**：`is_public` 与「共享」页的判定一致；公开客户对其他租户可见。
