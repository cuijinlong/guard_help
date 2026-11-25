<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# OAuth 2.0 / OAuth 2.0 客户端

> 菜单位置：运维管理 / 租户 / 安全 / OAuth 2.0 / OAuth 2.0 客户端

> 页面路径：`/security-settings/oauth2/clients`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `clients` |
| 路径 | `/security-settings/oauth2/clients` |
| 数据表 | `oauth2_client` |

## 核对 SQL（可直接复制运行）

### 1. OAuth2 客户端

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT title AS 名称, type AS 类型, created_time
FROM oauth2_client ORDER BY created_time DESC;
SQL
```

**本机实测结果：0 行**（名称、类型、created_time）

**判据**：0 行 = 没配客户端。改完要重新走一次授权流程。

> ⚠ 0 行的：1. OAuth2 客户端 —— 先确认是不是「本来就没启用/没数据」。
