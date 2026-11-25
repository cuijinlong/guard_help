<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 运营配置 / 设备类型

> 菜单位置：运维管理 / 租户 / 运营配置 / 设备类型

> 页面路径：`/device-type`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `energy_device_type` |
| 路径 | `/device-type` |
| 数据表 | `admin_settings` |

## 核对 SQL（可直接复制运行）

### 1. 设备类型字典

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT jsonb_array_length(
         (json_value::jsonb -> 'deviceType1' -> 'items')
       ) AS 设备类型数
FROM admin_settings WHERE key = 'energyDictionaries';
SQL
```

**本机实测结果**（前 1 行）：

| 设备类型数 |
| --- |
| 8 |

**判据**：设备档案的「设备类型」下拉就来自这里；新增后要刷新页面。
