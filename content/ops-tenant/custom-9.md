<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 租户 / Trend 分析

> 菜单位置：运维管理 / 租户 / Trend 分析

> 页面路径：`/spsspro/guardian`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `custom-9` |
| 路径 | `/spsspro/guardian` |
| 数据表 | `pq_dataset`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. Trend 分析的数据集（spsspro 侧，存在同一个库）

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT name AS 数据集, source_type AS 来源, status AS 状态,
       point_count AS 点数, completeness AS 完整率
FROM pq_dataset
WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1)
ORDER BY created_time DESC LIMIT 20;
SQL
```

**本机实测结果**（前 1 行）：

| 数据集 | 来源 | 状态 | 点数 | 完整率 |
| --- | --- | --- | --- | --- |
| CAPTURE-搬运器验证 | CAPTURE | COMPLETE | 0 | 0.0000 |

**判据**：页面打不开先确认子应用在跑（`/spsspro/guardian` 是独立前端）；数据为空 = 还没建数据集。
