<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 部件 / 部件包

> 菜单位置：运维管理 / 租户 / 资源 / 部件 / 部件包

> 页面路径：`/resources/widgets-library/widgets-bundles`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `widgets_bundles` |
| 路径 | `/resources/widgets-library/widgets-bundles` |
| 数据表 | `widgets_bundle` |

## 核对 SQL（可直接复制运行）

### 1. 部件包

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT count(*) AS 包数,
       count(*) FILTER (WHERE alias LIKE 'energy%' OR alias LIKE 'idle%') AS 自研
FROM widgets_bundle;
SQL
```

**本机实测结果**（前 1 行）：

| 包数 | 自研 |
| --- | --- |
| 56 | 24 |

**判据**：部件包只影响「资源 → 部件」的展示分组，不影响部件本身能否用。
