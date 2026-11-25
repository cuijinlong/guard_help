<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 资产 / 共享

> 菜单位置：运维管理 / 租户 / 实体 / 资产 / 共享

> 页面路径：`/entities/assets/shared`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `asset_shared` |
| 路径 | `/entities/assets/shared` |
| 数据表 | `asset`、`customer`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 按客户归属统计资产

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT coalesce(c.title, '（租户级/未分配）') AS 客户, a.type AS 类型, count(*) AS 数量
FROM asset a
LEFT JOIN customer c ON c.id = a.customer_id
WHERE a.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团')
GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 30;
SQL
```

**本机实测结果**（前 8 行）：

| 客户 | 类型 | 数量 |
| --- | --- | --- |
| （租户级/未分配） | 厂商 | 21 |
| （租户级/未分配） | 设备型号 | 14 |
| 平台演示中心 | 分项 | 13 |
| 平台演示中心 | 运行模式 | 12 |
| 平台演示中心 | 楼栋 | 9 |
| 平台演示中心 | 场站分组 | 9 |
| （租户级/未分配） | default | 8 |
| 平台演示中心 | topology | 7 |

**判据**：客户看不到自己的场站 → 它的 `customer_id` 可能是空（成了租户级）。
