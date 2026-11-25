<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 资源 / 资源库

> 菜单位置：运维管理 / 租户 / 资源 / 资源库

> 页面路径：`/resources/resources-library`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `resources_library` |
| 路径 | `/resources/resources-library` |
| 数据表 | `resource` |

## 核对 SQL（可直接复制运行）

### 1. 资源按类型统计

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT resource_type AS 类型, count(*) AS 数量,
       pg_size_pretty(sum(length(coalesce(data, '')))::bigint) AS 占用
FROM resource GROUP BY 1 ORDER BY 2 DESC;
SQL
```

**本机实测结果**（前 3 行）：

| 类型 | 数量 | 占用 |
| --- | --- | --- |
| IMAGE | 916 | 16 MB |
| JS_MODULE | 3 | 2493 kB |
| DASHBOARD | 2 | 550 kB |

**判据**：占用最大的通常是图片；要清理时按 `resource_type` 逐类确认。
