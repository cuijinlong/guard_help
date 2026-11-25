<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 资产 / 组

> 菜单位置：运维管理 / 租户 / 实体 / 资产 / 组

> 页面路径：`/entities/assets/groups`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `asset_groups` |
| 路径 | `/entities/assets/groups` |
| 数据表 | `asset_info_view`、`entity_group` |

## 核对 SQL（可直接复制运行）

### 1. 资产分组

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT g.name AS 分组,
       count(x.name) AS 成员数
FROM entity_group g
LEFT JOIN asset_info_view x ON x.groups::jsonb @> to_jsonb(g.id::text)
WHERE g.type = 'ASSET'
GROUP BY g.id, g.name ORDER BY 2 DESC;
SQL
```

**本机实测结果**（前 3 行）：

| 分组 | 成员数 |
| --- | --- |
| All | 0 |
| All | 0 |
| RELEASE-上线资产 | 0 |

**判据**：分项/区域能耗页的树来自这些分组；分组为空则该页选不到东西。
