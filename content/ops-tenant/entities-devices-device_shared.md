<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 设备 / 共享

> 菜单位置：运维管理 / 租户 / 实体 / 设备 / 共享

> 页面路径：`/entities/devices/shared`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `device_shared` |
| 路径 | `/entities/devices/shared` |
| 数据表 | `customer`、`device`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 分配给客户的设备

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT coalesce(c.title, '（未分配）') AS 客户, count(*) AS 设备数
FROM device d
LEFT JOIN customer c ON c.id = d.customer_id
WHERE d.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1)
GROUP BY 1 ORDER BY 2 DESC;
SQL
```

**本机实测结果**（前 1 行）：

| 客户 | 设备数 |
| --- | --- |
| 平台演示中心 | 55 |

**判据**：「（未分配）」这一行的数量 = 客户看不到的设备数。
