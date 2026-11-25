<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 实体 / 设备配置

> 菜单位置：运维管理 / 租户 / 实体 / 设备配置

> 页面路径：`/profiles/deviceProfiles`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `device_profiles` |
| 路径 | `/profiles/deviceProfiles` |
| 数据表 | `device`、`device_profile`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 设备配置

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT dp.name AS 配置, dp.type AS 类型, dp.transport_type AS 传输,
       count(d.id) AS 设备数
FROM device_profile dp
LEFT JOIN device d ON d.device_profile_id = dp.id
WHERE dp.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团')
GROUP BY dp.id, dp.name, dp.type, dp.transport_type ORDER BY 4 DESC;
SQL
```

**本机实测结果**（前 8 行）：

| 配置 | 类型 | 传输 | 设备数 |
| --- | --- | --- | --- |
| 电能表 | DEFAULT | DEFAULT | 15 |
| 风冷冷水机 | DEFAULT | DEFAULT | 9 |
| 网关 | DEFAULT | DEFAULT | 4 |
| 新风机组 | DEFAULT | DEFAULT | 4 |
| 单相电能表 | DEFAULT | DEFAULT | 4 |
| 室内环境变送器 | DEFAULT | DEFAULT | 3 |
| 立式管道离心泵 | DEFAULT | DEFAULT | 2 |
| 热水泵 | DEFAULT | DEFAULT | 2 |

**判据**：设备数为 0 的配置是残留。改了配置里的规则链，只影响之后创建的设备。
