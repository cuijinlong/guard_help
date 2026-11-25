<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 实体 / 网关

> 菜单位置：运维管理 / 租户 / 实体 / 网关

> 页面路径：`/entities/gateways`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `gateways` |
| 路径 | `/entities/gateways` |
| 数据表 | `customer`、`device`、`device_profile`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 网关设备（按设备配置类型识别）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT d.name AS 网关, dp.name AS 配置, dp.type AS 配置类型,
       coalesce(c.title, '—') AS 客户
FROM device d
JOIN device_profile dp ON dp.id = d.device_profile_id
LEFT JOIN customer c ON c.id = d.customer_id
WHERE d.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团') AND dp.type = 'GATEWAY'
ORDER BY d.name;
SQL
```

**本机实测结果：0 行**（网关、配置、配置类型、客户）

**判据**：0 行且页面有设备 → 那些设备的配置类型不是 GATEWAY，需要先建设备配置。

> ⚠ 0 行的：1. 网关设备（按设备配置类型识别） —— 先确认是不是「本来就没启用/没数据」。
