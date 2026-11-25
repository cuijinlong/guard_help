<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 实体 / OTA 更新

> 菜单位置：运维管理 / 租户 / 实体 / OTA 更新

> 页面路径：`/features/otaUpdates`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `otaUpdates` |
| 路径 | `/features/otaUpdates` |
| 数据表 | `ota_package`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. OTA 包

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT title AS 包名, version AS 版本, device_profile_id, created_time
FROM ota_package WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团') ORDER BY created_time DESC;
SQL
```

**本机实测结果：0 行**（包名、版本、device_profile_id、created_time）

**判据**：0 行 = 还没上传 OTA 包。

> ⚠ 0 行的：1. OTA 包 —— 先确认是不是「本来就没启用/没数据」。
