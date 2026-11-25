<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# OAuth 2.0 / 域名

> 菜单位置：运维管理 / 租户 / 安全 / OAuth 2.0 / 域名

> 页面路径：`/security-settings/oauth2/domains`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `domains` |
| 路径 | `/security-settings/oauth2/domains` |
| 数据表 | `domain` |

## 核对 SQL（可直接复制运行）

### 1. OAuth2 域名

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT name AS 域名, oauth2_enabled AS 启用OAuth2
FROM domain ORDER BY name;
SQL
```

**本机实测结果：0 行**（域名、启用oauth2）

**判据**：0 行 = 没配自定义域名/OAuth2 登录。

> ⚠ 0 行的：1. OAuth2 域名 —— 先确认是不是「本来就没启用/没数据」。
