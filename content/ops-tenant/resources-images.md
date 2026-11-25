<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 资源 / 图片

> 菜单位置：运维管理 / 租户 / 资源 / 图片

> 页面路径：`/resources/images`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `images` |
| 路径 | `/resources/images` |
| 数据表 | `resource` |

## 核对 SQL（可直接复制运行）

### 1. 图片资源

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT count(*) AS 数量, pg_size_pretty(sum(length(data))::bigint) AS 占用
FROM resource WHERE resource_type = 'IMAGE';
SQL
```

**本机实测结果**（前 1 行）：

| 数量 | 占用 |
| --- | --- |
| 916 | 16 MB |

**判据**：库里 900+ 张图片是正常的（部件图标、白标 logo）。
