<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 用户 / 全部

> 菜单位置：运维管理 / 租户 / 客户与用户 / 用户 / 全部

> 页面路径：`/users/all`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `user_all` |
| 路径 | `/users/all` |
| 数据表 | `customer`、`tb_user`、`tenant`、`user_credentials` |

## 核对 SQL（可直接复制运行）

### 1. 用户清单（含权限与所属客户）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT u.email AS 邮箱, u.authority AS 权限,
       coalesce(c.title, '（租户级）') AS 所属客户,
       uc.enabled AS 已启用,
       to_timestamp(uc.last_login_ts / 1000) AS 最近登录
FROM tb_user u
LEFT JOIN customer c ON c.id = u.customer_id
LEFT JOIN user_credentials uc ON uc.user_id = u.id
WHERE u.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团')
ORDER BY u.authority, u.email;
SQL
```

**本机实测结果**（前 2 行）：

| 邮箱 | 权限 | 所属客户 | 已启用 | 最近登录 |
| --- | --- | --- | --- | --- |
| demo@126.com | CUSTOMER_USER | 平台演示中心 | t | 2026-11-25 12:42:34+08 |
| tenant@126.com | TENANT_ADMIN | （租户级） | t | 2026-11-25 17:44:45+08 |

**判据**：「最近登录」为空 = 从没登录过。`authority` 决定能进租户端还是客户端。
