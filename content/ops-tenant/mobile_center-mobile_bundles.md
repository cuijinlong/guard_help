<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 移动应用 / 包

> 菜单位置：运维管理 / 租户 / 移动应用 / 包

> 页面路径：`/mobile-center/bundles`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `mobile_bundles` |
| 路径 | `/mobile-center/bundles` |
| 数据表 | `mobile_app_bundle`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 移动应用包

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT title AS 包名, oauth2_enabled AS 启用OAuth2
FROM mobile_app_bundle WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团') ORDER BY title;
SQL
```

**本机实测结果：0 行**（包名、启用oauth2）

**判据**：0 行 = 没配移动端（移动应用是平台预留能力）。

> ⚠ 0 行的：1. 移动应用包 —— 先确认是不是「本来就没启用/没数据」。
