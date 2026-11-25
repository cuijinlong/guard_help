<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 设备 / 分组

> 菜单位置：运维管理 / 租户 / 实体 / 设备 / 分组

> 页面路径：`/entities/devices/groups`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `device_groups` |
| 路径 | `/entities/devices/groups` |
| 数据表 | `device_info_view`、`entity_group` |

## 核对 SQL（可直接复制运行）

### 1. 设备分组

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT g.name AS 分组,
       count(x.name) AS 成员数
FROM entity_group g
LEFT JOIN device_info_view x ON x.groups::jsonb @> to_jsonb(g.id::text)
WHERE g.type = 'DEVICE'
GROUP BY g.id, g.name ORDER BY 2 DESC;
SQL
```

**本机实测结果**（前 2 行）：

| 分组 | 成员数 |
| --- | --- |
| All | 0 |
| All | 0 |

**判据**：分组是看板批量绑定的入口；分组为空则该看板选不到设备。
