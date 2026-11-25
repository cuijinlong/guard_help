<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 客户与用户 / 角色

> 菜单位置：运维管理 / 租户 / 客户与用户 / 角色

> 页面路径：`/roles`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `roles` |
| 路径 | `/roles` |
| 数据表 | `role`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 角色与权限条目数

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
-- permissions 是 JSON **文本**列（不是 jsonb），所以按长度看规模；
-- 要看具体权限就把该列完整取出来。
SELECT name AS 角色, type AS 类型,
       length(coalesce(permissions, '')) AS 权限串长度,
       length(coalesce(excluded_permissions, '')) AS 排除串长度
FROM role WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团') ORDER BY 2, 1;
SQL
```

**本机实测结果**（前 3 行）：

| 角色 | 类型 | 权限串长度 | 排除串长度 |
| --- | --- | --- | --- |
| Customer Administrator | GENERIC | 15 | 0 |
| Customer User | GENERIC | 266 | 0 |
| Entity Group Read-only User | GROUP | 73 | 0 |

**判据**：权限数 0 的角色等于什么都看不到。改角色后要重新登录才生效。
