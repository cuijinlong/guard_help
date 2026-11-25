<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 仪表板 / 分组

> 菜单位置：运维管理 / 租户 / 监控 / 仪表板 / 分组

> 页面路径：`/dashboards/groups`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `dashboard_groups` |
| 路径 | `/dashboards/groups` |
| 数据表 | `dashboard_info_view`、`entity_group` |

## 核对 SQL（可直接复制运行）

### 1. 看板分组

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT g.name AS 分组,
       count(x.title) AS 成员数
FROM entity_group g
LEFT JOIN dashboard_info_view x ON x.groups::jsonb @> to_jsonb(g.id::text)
WHERE g.type = 'DASHBOARD'
GROUP BY g.id, g.name ORDER BY 2 DESC;
SQL
```

**本机实测结果**（前 8 行）：

| 分组 | 成员数 |
| --- | --- |
| 能耗分析 | 0 |
| 能耗查询 | 0 |
| 租户运营台 | 0 |
| All | 0 |
| 综合报表 | 0 |
| All | 0 |
| 能耗优化 | 0 |
| 平台演示中心 Dashboards | 0 |

**判据**：分组里的看板数合计应等于「全部」里被分组管理的数量。
