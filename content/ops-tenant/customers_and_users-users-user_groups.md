<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 用户 / 分组

> 菜单位置：运维管理 / 租户 / 客户与用户 / 用户 / 分组

> 页面路径：`/users/groups`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `user_groups` |
| 路径 | `/users/groups` |
| 数据表 | `entity_group`、`user_info_view` |

## 核对 SQL（可直接复制运行）

### 1. 用户分组

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT g.name AS 分组,
       count(x.email) AS 成员数
FROM entity_group g
LEFT JOIN user_info_view x ON x.groups::jsonb @> to_jsonb(g.id::text)
WHERE g.type = 'USER'
GROUP BY g.id, g.name ORDER BY 2 DESC;
SQL
```

**本机实测结果**（前 6 行）：

| 分组 | 成员数 |
| --- | --- |
| All | 0 |
| Tenant Users | 0 |
| Tenant Administrators | 0 |
| All | 0 |
| Customer Users | 0 |
| Customer Administrators | 0 |

**判据**：自定义菜单可按用户组下发；分组为空则该机制用不上。
