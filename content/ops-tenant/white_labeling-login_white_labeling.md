<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 白标 / 登录

> 菜单位置：运维管理 / 租户 / 白标 / 登录

> 页面路径：`/white-labeling/loginWhiteLabel`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `login_white_labeling` |
| 路径 | `/white-labeling/loginWhiteLabel` |
| 数据表 | `tenant`、`white_labeling` |

## 核对 SQL（可直接复制运行）

### 1. 登录页白标

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT coalesce(type::text, '(默认)') AS 类型, left(settings::text, 160) AS 配置
FROM white_labeling
WHERE type::text LIKE '%LOGIN%' AND (tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团') OR tenant_id IS NULL);
SQL
```

**本机实测结果：0 行**（类型、配置）

**判据**：0 行 = 登录页用平台默认样式。

> ⚠ 0 行的：1. 登录页白标 —— 先确认是不是「本来就没启用/没数据」。
