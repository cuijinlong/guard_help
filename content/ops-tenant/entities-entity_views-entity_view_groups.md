<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 实体视图 / 分组

> 菜单位置：运维管理 / 租户 / 实体 / 实体视图 / 分组

> 页面路径：`/entities/entityViews/groups`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `entity_view_groups` |
| 路径 | `/entities/entityViews/groups` |
| 数据表 | `entity_group`、`entity_view_info_view` |

## 核对 SQL（可直接复制运行）

### 1. 实体视图分组

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT g.name AS 分组,
       count(x.name) AS 成员数
FROM entity_group g
LEFT JOIN entity_view_info_view x ON x.groups::jsonb @> to_jsonb(g.id::text)
WHERE g.type = 'ENTITY_VIEW'
GROUP BY g.id, g.name ORDER BY 2 DESC;
SQL
```

**本机实测结果**（前 2 行）：

| 分组 | 成员数 |
| --- | --- |
| All | 0 |
| All | 0 |

**判据**：0 行且页面有视图 → 视图没被分组管理，属于「全部」而非「分组」。
