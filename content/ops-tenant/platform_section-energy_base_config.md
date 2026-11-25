<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 运营配置 / 峰谷时段

> 菜单位置：运维管理 / 租户 / 运营配置 / 峰谷时段

> 页面路径：`/base-config`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `energy_base_config` |
| 路径 | `/base-config` |
| 数据表 | `asset`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 峰谷时段方案（租户级，不按客户过滤）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT name AS 方案, label AS 说明
FROM asset
WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团') AND type = 'tou_scheme'
ORDER BY name;
SQL
```

**本机实测结果**（前 6 行）：

| 方案 | 说明 |
| --- | --- |
| 冬季周末及节假日 | 冬季周末及节假日 |
| 冬季工作日 | 冬季工作日 |
| 夏季周末及节假日 | 夏季周末及节假日 |
| 夏季工作日 | 夏季工作日 |
| 春秋季周末 | 春秋季周末 |
| 春秋季工作日 | 春秋季工作日 |

**判据**：0 行 = 没配时段方案，峰谷分析页会是空的。
