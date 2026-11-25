<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 移动应用 / 应用程序

> 菜单位置：运维管理 / 租户 / 移动应用 / 应用程序

> 页面路径：`/mobile-center/applications`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `mobile_apps` |
| 路径 | `/mobile-center/applications` |
| 数据表 | `mobile_app`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 移动应用

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT title AS 应用, pkg_name AS 包名, platform_type AS 平台, status AS 状态
FROM mobile_app WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) ORDER BY title;
SQL
```

**本机实测结果：0 行**（应用、包名、平台、状态）

**判据**：0 行 = 没发布移动应用。

> ⚠ 0 行的：1. 移动应用 —— 先确认是不是「本来就没启用/没数据」。
