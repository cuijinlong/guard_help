<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 设备 / 全部

> 菜单位置：运维管理 / 租户 / 实体 / 设备 / 全部

> 页面路径：`/entities/devices/all`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `device_all` |
| 路径 | `/entities/devices/all` |
| 数据表 | `customer`、`device`、`device_profile`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 设备清单（含所属客户与配置）

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT d.name AS 设备, d.type AS 类型,
       coalesce(c.title, '（未分配客户）') AS 客户,
       dp.name AS 设备配置,
       to_timestamp(d.created_time / 1000) AS 创建时间
FROM device d
LEFT JOIN customer c ON c.id = d.customer_id
LEFT JOIN device_profile dp ON dp.id = d.device_profile_id
WHERE d.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1)
ORDER BY d.name;
SQL
```

**本机实测结果**（前 8 行）：

| 设备 | 类型 | 客户 | 设备配置 | 创建时间 |
| --- | --- | --- | --- | --- |
| AHU-SIM·平台演示中心 | 新风机组 | 平台演示中心 | 新风机组 | 2026-11-02 15:58:17+08 |
| A栋 1#锅炉·平台演示中心 | 锅炉 | 平台演示中心 | 锅炉 | 2026-11-03 10:55:00+08 |
| A栋 2#锅炉·平台演示中心 | 锅炉 | 平台演示中心 | 锅炉 | 2026-11-03 10:55:01+08 |
| A栋 室内环境·平台演示中心 | 室内环境变送器 | 平台演示中心 | 室内环境变送器 | 2026-11-03 10:55:02+08 |
| A栋 新风机组·平台演示中心 | 新风机组 | 平台演示中心 | 新风机组 | 2026-11-03 10:54:58+08 |
| A栋 热水泵(大)·平台演示中心 | 热水泵 | 平台演示中心 | 热水泵 | 2026-11-03 10:55:01+08 |
| A栋 热水泵(小)·平台演示中心 | 热水泵 | 平台演示中心 | 热水泵 | 2026-11-03 10:55:01+08 |
| Breaker-SIM·平台演示中心 | 智能空开 | 平台演示中心 | 智能空开 | 2026-11-02 15:58:17+08 |

**判据**：客户账号看不到某台设备 → 看「客户」列是否为空（未分配给任何客户）。
